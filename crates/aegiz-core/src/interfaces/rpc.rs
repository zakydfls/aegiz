use crate::{
    application::{adapters::AdapterRuntime, databases::DatabaseRuntime, tunnels::TunnelManager},
    infrastructure::ssh_config,
    proto::{
        self, AuditEvent as ProtoAuditEvent, Dashboard as ProtoDashboard,
        DatabaseProfile as ProtoDatabaseProfile, HandshakeResponse, Host as ProtoHost,
        ImportSshConfigResponse, ListAuditEventsResponse, ListCapabilitiesResponse,
        ListDatabaseProfilesResponse, ListHostsResponse, ListTunnelsResponse, OperationEvent,
        Tunnel as ProtoTunnel, aegiz_core_server::AegizCore,
    },
};
use aegiz_domain::{DatabaseEngine, DatabaseProfile, Tunnel, TunnelKind, TunnelStatus};
use aegiz_storage::Store;
use chrono::Utc;
use futures_core::Stream;
use std::{path::PathBuf, pin::Pin};
use tokio::sync::mpsc;
use tokio_stream::wrappers::ReceiverStream;
use tonic::{Request, Response, Status, service::Interceptor};
use uuid::Uuid;

#[derive(Clone)]
pub struct CoreService {
    store: Store,
    tunnels: TunnelManager,
    adapters: AdapterRuntime,
    databases: DatabaseRuntime,
}

impl CoreService {
    pub fn new(
        store: Store,
        tunnels: TunnelManager,
        adapters: AdapterRuntime,
        databases: DatabaseRuntime,
    ) -> Self {
        Self {
            store,
            tunnels,
            adapters,
            databases,
        }
    }
}

#[tonic::async_trait]
impl AegizCore for CoreService {
    async fn handshake(
        &self,
        _request: Request<proto::HandshakeRequest>,
    ) -> Result<Response<HandshakeResponse>, Status> {
        Ok(Response::new(HandshakeResponse {
            core_version: env!("CARGO_PKG_VERSION").into(),
            protocol_version: 7,
        }))
    }

    async fn get_dashboard(
        &self,
        _request: Request<proto::GetDashboardRequest>,
    ) -> Result<Response<ProtoDashboard>, Status> {
        self.tunnels.reconcile().await.map_err(internal)?;
        let value = self.store.dashboard().await.map_err(internal)?;
        Ok(Response::new(ProtoDashboard {
            host_count: value.host_count,
            tunnel_count: value.tunnel_count,
            active_tunnel_count: value.active_tunnel_count,
            attention_count: value.attention_count,
        }))
    }

    async fn list_hosts(
        &self,
        request: Request<proto::ListHostsRequest>,
    ) -> Result<Response<ListHostsResponse>, Status> {
        let hosts = self
            .store
            .list_hosts(&request.into_inner().query)
            .await
            .map_err(internal)?;
        Ok(Response::new(ListHostsResponse {
            hosts: hosts.into_iter().map(host_to_proto).collect(),
        }))
    }

    async fn import_ssh_config(
        &self,
        request: Request<proto::ImportSshConfigRequest>,
    ) -> Result<Response<ImportSshConfigResponse>, Status> {
        let requested = request.into_inner().path;
        let path = if requested.trim().is_empty() {
            home_ssh_config().ok_or_else(|| Status::failed_precondition("HOME is unavailable"))?
        } else {
            PathBuf::from(requested)
        };
        let (hosts, mut warnings, skipped) =
            ssh_config::parse_file(&path).await.map_err(|error| {
                Status::invalid_argument(format!("SSH config import failed: {error}"))
            })?;
        let mut report = self.store.upsert_hosts(&hosts).await.map_err(internal)?;
        report.skipped = skipped;
        report.warnings.append(&mut warnings);
        self.store
            .audit(
                "ssh_config.import",
                None,
                "success",
                &format!(
                    "{} imported, {} updated, {} skipped",
                    report.imported, report.updated, report.skipped
                ),
            )
            .await
            .map_err(internal)?;
        Ok(Response::new(ImportSshConfigResponse {
            imported: report.imported,
            updated: report.updated,
            skipped: report.skipped,
            warnings: report.warnings,
        }))
    }

    async fn list_tunnels(
        &self,
        _request: Request<proto::ListTunnelsRequest>,
    ) -> Result<Response<ListTunnelsResponse>, Status> {
        self.tunnels.reconcile().await.map_err(internal)?;
        let tunnels = self.store.list_tunnels().await.map_err(internal)?;
        Ok(Response::new(ListTunnelsResponse {
            tunnels: tunnels.into_iter().map(tunnel_to_proto).collect(),
        }))
    }

    async fn save_tunnel(
        &self,
        request: Request<proto::SaveTunnelRequest>,
    ) -> Result<Response<ProtoTunnel>, Status> {
        let tunnel = request
            .into_inner()
            .tunnel
            .ok_or_else(|| Status::invalid_argument("tunnel is required"))?;
        let domain = proto_to_tunnel(tunnel)?;
        self.store.save_tunnel(&domain).await.map_err(internal)?;
        self.store
            .audit("tunnel.save", Some(domain.id), "success", "")
            .await
            .map_err(internal)?;
        Ok(Response::new(tunnel_to_proto(domain)))
    }

    type SetTunnelStateStream =
        Pin<Box<dyn Stream<Item = Result<OperationEvent, Status>> + Send + 'static>>;

    async fn set_tunnel_state(
        &self,
        request: Request<proto::SetTunnelStateRequest>,
    ) -> Result<Response<Self::SetTunnelStateStream>, Status> {
        let input = request.into_inner();
        let id = Uuid::parse_str(&input.tunnel_id)
            .map_err(|_| Status::invalid_argument("invalid tunnel id"))?;
        let operation_id = Uuid::new_v4().to_string();
        let manager = self.tunnels.clone();
        let (sender, receiver) = mpsc::channel(8);

        tokio::spawn(async move {
            let verb = if input.running {
                "Starting"
            } else {
                "Stopping"
            };
            let _ = sender
                .send(Ok(OperationEvent {
                    operation_id: operation_id.clone(),
                    phase: "running".into(),
                    message: format!("{verb} tunnel"),
                    progress: 20,
                    terminal: false,
                    success: false,
                    stream: "system".into(),
                    sequence: 1,
                    exit_code: 0,
                }))
                .await;
            let result = if input.running {
                manager.start_with_auth(id, input.ssh_auth_secret).await
            } else {
                manager.stop(id).await
            };
            let (message, success) = match result {
                Ok(()) => (
                    if input.running {
                        "Tunnel is active".to_owned()
                    } else {
                        "Tunnel stopped".to_owned()
                    },
                    true,
                ),
                Err(error) => (error.to_string(), false),
            };
            let _ = sender
                .send(Ok(OperationEvent {
                    operation_id,
                    phase: if success { "completed" } else { "failed" }.into(),
                    message,
                    progress: 100,
                    terminal: true,
                    success,
                    stream: "system".into(),
                    sequence: 2,
                    exit_code: if success { 0 } else { -1 },
                }))
                .await;
        });

        Ok(Response::new(
            Box::pin(ReceiverStream::new(receiver)) as Self::SetTunnelStateStream
        ))
    }

    async fn list_capabilities(
        &self,
        _request: Request<proto::ListCapabilitiesRequest>,
    ) -> Result<Response<ListCapabilitiesResponse>, Status> {
        Ok(Response::new(ListCapabilitiesResponse {
            capabilities: self.adapters.capabilities().await,
        }))
    }

    type RunToolStream =
        Pin<Box<dyn Stream<Item = Result<OperationEvent, Status>> + Send + 'static>>;

    async fn run_tool(
        &self,
        request: Request<proto::RunToolRequest>,
    ) -> Result<Response<Self::RunToolStream>, Status> {
        let input = request.into_inner();
        let operation_id = Uuid::new_v4();
        let adapters = self.adapters.clone();
        let (sender, receiver) = mpsc::channel(64);
        tokio::spawn(async move {
            adapters
                .execute(
                    operation_id,
                    input.adapter_id,
                    input.arguments,
                    input.working_directory,
                    input.confirmed_mutation,
                    input.ssh_auth_secret,
                    sender,
                )
                .await;
        });
        Ok(Response::new(
            Box::pin(ReceiverStream::new(receiver)) as Self::RunToolStream
        ))
    }

    async fn cancel_operation(
        &self,
        request: Request<proto::CancelOperationRequest>,
    ) -> Result<Response<proto::CancelOperationResponse>, Status> {
        let operation_id = Uuid::parse_str(&request.into_inner().operation_id)
            .map_err(|_| Status::invalid_argument("invalid operation id"))?;
        let accepted =
            self.adapters.cancel(operation_id).await || self.databases.cancel(operation_id).await;
        Ok(Response::new(proto::CancelOperationResponse { accepted }))
    }

    async fn list_audit_events(
        &self,
        request: Request<proto::ListAuditEventsRequest>,
    ) -> Result<Response<ListAuditEventsResponse>, Status> {
        let requested = request.into_inner().limit;
        let events = self
            .store
            .list_audit_events(if requested == 0 { 200 } else { requested })
            .await
            .map_err(internal)?
            .into_iter()
            .map(|event| ProtoAuditEvent {
                id: event.id,
                occurred_at: event.occurred_at.to_rfc3339(),
                action: event.action,
                resource_id: event.resource_id.unwrap_or_default(),
                outcome: event.outcome,
                detail: event.detail,
            })
            .collect();
        Ok(Response::new(ListAuditEventsResponse { events }))
    }

    async fn list_database_profiles(
        &self,
        _request: Request<proto::ListDatabaseProfilesRequest>,
    ) -> Result<Response<ListDatabaseProfilesResponse>, Status> {
        let profiles = self
            .store
            .list_database_profiles()
            .await
            .map_err(internal)?
            .into_iter()
            .map(database_profile_to_proto)
            .collect();
        Ok(Response::new(ListDatabaseProfilesResponse { profiles }))
    }

    async fn save_database_profile(
        &self,
        request: Request<proto::SaveDatabaseProfileRequest>,
    ) -> Result<Response<ProtoDatabaseProfile>, Status> {
        let value = request
            .into_inner()
            .profile
            .ok_or_else(|| Status::invalid_argument("database profile is required"))?;
        let profile = proto_to_database_profile(value)?;
        self.store
            .save_database_profile(&profile)
            .await
            .map_err(internal)?;
        self.store
            .audit("database.profile.save", Some(profile.id), "success", "")
            .await
            .map_err(internal)?;
        Ok(Response::new(database_profile_to_proto(profile)))
    }

    async fn delete_database_profile(
        &self,
        request: Request<proto::DeleteDatabaseProfileRequest>,
    ) -> Result<Response<proto::DeleteDatabaseProfileResponse>, Status> {
        let id = Uuid::parse_str(&request.into_inner().profile_id)
            .map_err(|_| Status::invalid_argument("invalid database profile id"))?;
        self.store
            .delete_database_profile(id)
            .await
            .map_err(internal)?;
        self.store
            .audit("database.profile.delete", Some(id), "success", "")
            .await
            .map_err(internal)?;
        Ok(Response::new(proto::DeleteDatabaseProfileResponse {
            deleted: true,
        }))
    }

    type RunDatabaseQueryStream =
        Pin<Box<dyn Stream<Item = Result<OperationEvent, Status>> + Send + 'static>>;

    async fn run_database_query(
        &self,
        request: Request<proto::RunDatabaseQueryRequest>,
    ) -> Result<Response<Self::RunDatabaseQueryStream>, Status> {
        let input = request.into_inner();
        let databases = self.databases.clone();
        let (sender, receiver) = mpsc::channel(64);
        tokio::spawn(async move {
            databases.execute(input, sender).await;
        });
        Ok(Response::new(
            Box::pin(ReceiverStream::new(receiver)) as Self::RunDatabaseQueryStream
        ))
    }

    async fn export_backup(
        &self,
        _request: Request<proto::ExportBackupRequest>,
    ) -> Result<Response<proto::ExportBackupResponse>, Status> {
        let payload = self.store.export_backup().await.map_err(internal)?;
        self.store
            .audit(
                "backup.export",
                None,
                "success",
                "Logical metadata snapshot exported; credential values excluded",
            )
            .await
            .map_err(internal)?;
        Ok(Response::new(proto::ExportBackupResponse { payload }))
    }

    async fn restore_backup(
        &self,
        request: Request<proto::RestoreBackupRequest>,
    ) -> Result<Response<proto::RestoreBackupResponse>, Status> {
        let input = request.into_inner();
        if !input.confirmed_replace {
            return Err(Status::failed_precondition(
                "backup restore requires explicit replacement confirmation",
            ));
        }
        if input.payload.is_empty() {
            return Err(Status::invalid_argument("backup payload is empty"));
        }
        self.tunnels.stop_all().await;
        let report = self
            .store
            .restore_backup(&input.payload)
            .await
            .map_err(|error| Status::invalid_argument(format!("backup restore failed: {error}")))?;
        Ok(Response::new(proto::RestoreBackupResponse {
            host_count: report.hosts,
            tunnel_count: report.tunnels,
            database_profile_count: report.database_profiles,
            audit_event_count: report.audit_events,
        }))
    }
}

#[derive(Clone)]
pub struct SessionAuth {
    expected: String,
}

impl SessionAuth {
    pub fn new(expected: String) -> Self {
        Self { expected }
    }
}

impl Interceptor for SessionAuth {
    fn call(&mut self, request: Request<()>) -> Result<Request<()>, Status> {
        let supplied = request
            .metadata()
            .get("x-aegiz-session")
            .and_then(|value| value.to_str().ok());
        if supplied == Some(self.expected.as_str()) {
            Ok(request)
        } else {
            Err(Status::unauthenticated("invalid Aegiz session"))
        }
    }
}

fn home_ssh_config() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".ssh/config"))
}

fn internal(error: impl std::fmt::Display) -> Status {
    tracing::error!(%error, "core operation failed");
    Status::internal("Aegiz could not complete the local operation")
}

fn host_to_proto(host: aegiz_domain::Host) -> ProtoHost {
    ProtoHost {
        id: host.id.to_string(),
        alias: host.alias,
        hostname: host.hostname,
        user: host.user.unwrap_or_default(),
        port: host.port.into(),
        proxy_jump: host.proxy_jump.unwrap_or_default(),
        source: host.source,
        tags: host.tags,
    }
}

fn tunnel_to_proto(tunnel: Tunnel) -> ProtoTunnel {
    ProtoTunnel {
        id: tunnel.id.to_string(),
        host_id: tunnel.host_id.to_string(),
        label: tunnel.label,
        kind: match tunnel.kind {
            TunnelKind::Local => proto::TunnelKind::Local as i32,
            TunnelKind::Remote => proto::TunnelKind::Remote as i32,
            TunnelKind::Dynamic => proto::TunnelKind::Dynamic as i32,
        },
        bind_address: tunnel.bind_address,
        local_port: tunnel.local_port.into(),
        remote_host: tunnel.remote_host,
        remote_port: tunnel.remote_port.into(),
        status: match tunnel.status {
            TunnelStatus::Stopped => proto::TunnelStatus::Stopped as i32,
            TunnelStatus::Starting => proto::TunnelStatus::Starting as i32,
            TunnelStatus::Running => proto::TunnelStatus::Running as i32,
            TunnelStatus::Stopping => proto::TunnelStatus::Stopping as i32,
            TunnelStatus::Failed => proto::TunnelStatus::Failed as i32,
        },
        last_error: tunnel.last_error.unwrap_or_default(),
    }
}

fn database_profile_to_proto(profile: DatabaseProfile) -> ProtoDatabaseProfile {
    ProtoDatabaseProfile {
        id: profile.id.to_string(),
        label: profile.label,
        engine: match profile.engine {
            DatabaseEngine::Postgres => proto::DatabaseEngine::Postgres as i32,
            DatabaseEngine::MySql => proto::DatabaseEngine::Mysql as i32,
            DatabaseEngine::Redis => proto::DatabaseEngine::Redis as i32,
        },
        hostname: profile.hostname,
        port: profile.port.into(),
        database_name: profile.database_name,
        username: profile.username,
        secret_reference: profile.secret_reference.unwrap_or_default(),
        tunnel_id: profile
            .tunnel_id
            .map(|id| id.to_string())
            .unwrap_or_default(),
        auto_start_tunnel: profile.auto_start_tunnel,
        read_only: profile.read_only,
    }
}

fn proto_to_database_profile(value: ProtoDatabaseProfile) -> Result<DatabaseProfile, Status> {
    let label = value.label.trim();
    let hostname = value.hostname.trim();
    let database_name = value.database_name.trim();
    let username = value.username.trim();
    let engine = match value.engine() {
        proto::DatabaseEngine::Mysql => DatabaseEngine::MySql,
        proto::DatabaseEngine::Postgres => DatabaseEngine::Postgres,
        proto::DatabaseEngine::Redis => DatabaseEngine::Redis,
        _ => return Err(Status::invalid_argument("database engine is required")),
    };
    if label.is_empty()
        || hostname.is_empty()
        || database_name.is_empty()
        || (username.is_empty() && engine != DatabaseEngine::Redis)
        || value.port == 0
        || value.port > u16::MAX.into()
        || [label, hostname, database_name, username]
            .iter()
            .any(|field| field.contains(['\n', '\r', '\0']) || field.len() > 1024)
    {
        return Err(Status::invalid_argument(
            "database profile fields are invalid",
        ));
    }
    let now = Utc::now();
    Ok(DatabaseProfile {
        id: if value.id.is_empty() {
            Uuid::new_v4()
        } else {
            Uuid::parse_str(&value.id)
                .map_err(|_| Status::invalid_argument("invalid database profile id"))?
        },
        label: label.into(),
        engine,
        hostname: hostname.into(),
        port: value.port as u16,
        database_name: database_name.into(),
        username: username.into(),
        secret_reference: (!value.secret_reference.is_empty()).then_some(value.secret_reference),
        tunnel_id: (!value.tunnel_id.is_empty())
            .then(|| Uuid::parse_str(&value.tunnel_id))
            .transpose()
            .map_err(|_| Status::invalid_argument("invalid tunnel route"))?,
        auto_start_tunnel: value.auto_start_tunnel && !value.tunnel_id.is_empty(),
        read_only: value.read_only,
        created_at: now,
        updated_at: now,
    })
}

fn proto_to_tunnel(input: ProtoTunnel) -> Result<Tunnel, Status> {
    let id = if input.id.is_empty() {
        Uuid::new_v4()
    } else {
        Uuid::parse_str(&input.id).map_err(|_| Status::invalid_argument("invalid tunnel id"))?
    };
    let host_id =
        Uuid::parse_str(&input.host_id).map_err(|_| Status::invalid_argument("invalid host id"))?;
    let kind = match proto::TunnelKind::try_from(input.kind) {
        Ok(proto::TunnelKind::Local) => TunnelKind::Local,
        Ok(proto::TunnelKind::Remote) => TunnelKind::Remote,
        Ok(proto::TunnelKind::Dynamic) => TunnelKind::Dynamic,
        _ => return Err(Status::invalid_argument("tunnel kind is required")),
    };
    let local_port = u16::try_from(input.local_port)
        .map_err(|_| Status::invalid_argument("local port is out of range"))?;
    let remote_port = u16::try_from(input.remote_port)
        .map_err(|_| Status::invalid_argument("remote port is out of range"))?;
    if input.label.trim().is_empty() {
        return Err(Status::invalid_argument("tunnel label is required"));
    }
    let now = Utc::now();
    Ok(Tunnel {
        id,
        host_id,
        label: input.label.trim().to_owned(),
        kind,
        bind_address: if input.bind_address.is_empty() {
            "127.0.0.1".into()
        } else {
            input.bind_address
        },
        local_port,
        remote_host: input.remote_host,
        remote_port,
        status: TunnelStatus::Stopped,
        last_error: None,
        created_at: now,
        updated_at: now,
    })
}
