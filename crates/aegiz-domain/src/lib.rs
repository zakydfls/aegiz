use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Host {
    pub id: Uuid,
    pub alias: String,
    pub hostname: String,
    pub user: Option<String>,
    pub port: u16,
    pub proxy_jump: Option<String>,
    pub identity_hint: Option<String>,
    pub source: String,
    pub tags: Vec<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum TunnelKind {
    #[default]
    Local,
    Remote,
    Dynamic,
}

impl TunnelKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Local => "local",
            Self::Remote => "remote",
            Self::Dynamic => "dynamic",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "local" => Some(Self::Local),
            "remote" => Some(Self::Remote),
            "dynamic" => Some(Self::Dynamic),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum TunnelStatus {
    #[default]
    Stopped,
    Starting,
    Running,
    Stopping,
    Failed,
}

impl TunnelStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Stopped => "stopped",
            Self::Starting => "starting",
            Self::Running => "running",
            Self::Stopping => "stopping",
            Self::Failed => "failed",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Tunnel {
    pub id: Uuid,
    pub host_id: Uuid,
    pub label: String,
    pub kind: TunnelKind,
    pub bind_address: String,
    pub local_port: u16,
    pub remote_host: String,
    pub remote_port: u16,
    pub status: TunnelStatus,
    pub last_error: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum DatabaseEngine {
    Postgres,
    MySql,
    Redis,
}

impl DatabaseEngine {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Postgres => "postgres",
            Self::MySql => "mysql",
            Self::Redis => "redis",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "postgres" => Some(Self::Postgres),
            "mysql" => Some(Self::MySql),
            "redis" => Some(Self::Redis),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DatabaseProfile {
    pub id: Uuid,
    pub label: String,
    pub engine: DatabaseEngine,
    pub hostname: String,
    pub port: u16,
    pub database_name: String,
    pub username: String,
    pub secret_reference: Option<String>,
    pub tunnel_id: Option<Uuid>,
    pub auto_start_tunnel: bool,
    pub read_only: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ImportReport {
    pub imported: u32,
    pub updated: u32,
    pub skipped: u32,
    pub warnings: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Dashboard {
    pub host_count: u32,
    pub tunnel_count: u32,
    pub active_tunnel_count: u32,
    pub attention_count: u32,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuditEvent {
    pub id: i64,
    pub occurred_at: DateTime<Utc>,
    pub action: String,
    pub resource_id: Option<String>,
    pub outcome: String,
    pub detail: String,
}
