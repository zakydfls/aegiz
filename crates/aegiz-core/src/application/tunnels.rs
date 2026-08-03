use aegiz_domain::{Tunnel, TunnelKind, TunnelStatus};
use aegiz_platform::CredentialLease;
use aegiz_storage::Store;
use anyhow::{Context, Result, anyhow, bail};
use std::{
    collections::HashMap,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::{ExitStatus, Stdio},
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpStream, UnixListener},
    process::{Child, ChildStderr, ChildStdin},
    sync::{Mutex, oneshot},
    task::JoinHandle,
    time::timeout,
};
use uuid::Uuid;
use zeroize::Zeroize;

const AUTHENTICATION_TIMEOUT: Duration = Duration::from_secs(12);
const STARTUP_TIMEOUT: Duration = Duration::from_secs(12);
const MAX_CAPTURED_STDERR_BYTES: usize = 16 * 1024;
const WATCHDOG_STOP_TIMEOUT: Duration = Duration::from_secs(3);

struct ManagedTunnel {
    // Drop the control pipe before the watchdog handle. This gives the helper
    // an EOF signal even if a future unwinds unexpectedly.
    stop_pipe: Option<ChildStdin>,
    child: Child,
    stderr: CapturedStderr,
}

impl ManagedTunnel {
    async fn shutdown(mut self) -> Result<(ExitStatus, String)> {
        self.stop_pipe.take();
        let status = match timeout(WATCHDOG_STOP_TIMEOUT, self.child.wait()).await {
            Ok(result) => result.context("could not wait for the tunnel watchdog")?,
            Err(_) => {
                self.child
                    .kill()
                    .await
                    .context("could not stop the tunnel watchdog")?;
                self.child
                    .wait()
                    .await
                    .context("could not reap the tunnel watchdog")?
            }
        };
        Ok((status, self.stderr.finish().await))
    }

    async fn finish(mut self) -> Result<(ExitStatus, String)> {
        self.stop_pipe.take();
        let status = self
            .child
            .wait()
            .await
            .context("could not reap the tunnel watchdog")?;
        Ok((status, self.stderr.finish().await))
    }
}

struct CapturedStderr {
    buffer: Arc<Mutex<Vec<u8>>>,
    task: JoinHandle<()>,
}

impl CapturedStderr {
    fn spawn(mut pipe: ChildStderr) -> Self {
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let task_buffer = buffer.clone();
        let task = tokio::spawn(async move {
            let mut chunk = [0_u8; 1024];
            loop {
                let read = match pipe.read(&mut chunk).await {
                    Ok(0) | Err(_) => break,
                    Ok(read) => read,
                };
                let mut captured = task_buffer.lock().await;
                let overflow = captured
                    .len()
                    .saturating_add(read)
                    .saturating_sub(MAX_CAPTURED_STDERR_BYTES);
                if overflow > 0 {
                    let remove = overflow.min(captured.len());
                    captured.drain(..remove);
                }
                captured.extend_from_slice(&chunk[..read]);
            }
        });
        Self { buffer, task }
    }

    async fn finish(self) -> String {
        let _ = self.task.await;
        let captured = self.buffer.lock().await;
        String::from_utf8_lossy(&captured).into_owned()
    }
}

#[derive(Clone)]
pub struct TunnelManager {
    store: Store,
    children: Arc<Mutex<HashMap<Uuid, ManagedTunnel>>>,
    runtime_directory: Arc<PathBuf>,
    askpass_executable: Arc<PathBuf>,
    watchdog_executable: Arc<PathBuf>,
}

impl TunnelManager {
    pub fn new(store: Store, runtime_directory: PathBuf) -> Self {
        let askpass_executable = std::env::current_exe()
            .ok()
            .and_then(|path| path.parent().map(|parent| parent.join("aegiz-askpass")))
            .unwrap_or_else(|| PathBuf::from("aegiz-askpass"));
        let watchdog_executable = std::env::current_exe()
            .ok()
            .and_then(|path| {
                path.parent()
                    .map(|parent| parent.join("aegiz-tunnel-watchdog"))
            })
            .unwrap_or_else(|| PathBuf::from("aegiz-tunnel-watchdog"));
        Self {
            store,
            children: Arc::new(Mutex::new(HashMap::new())),
            runtime_directory: Arc::new(runtime_directory),
            askpass_executable: Arc::new(askpass_executable),
            watchdog_executable: Arc::new(watchdog_executable),
        }
    }

    pub async fn start_with_auth(&self, id: Uuid, authentication_secret: Vec<u8>) -> Result<()> {
        let authentication_secret = CredentialLease::new(authentication_secret)?;
        self.start_with_credential(id, authentication_secret).await
    }

    pub(crate) async fn start_with_credential(
        &self,
        id: Uuid,
        authentication_secret: CredentialLease,
    ) -> Result<()> {
        if self.children.lock().await.contains_key(&id) {
            return Ok(());
        }
        if !self.watchdog_executable.is_file() {
            bail!("Aegiz tunnel watchdog is missing from the app bundle");
        }

        let tunnel = self.store.get_tunnel(id).await?;
        let host = self.store.get_host(tunnel.host_id).await?;
        validate(&tunnel, &host.alias)?;
        ensure_local_port_available(&tunnel).await?;
        let password_authentication = !authentication_secret.is_empty();
        let args = if password_authentication {
            ssh_arguments_for_auth(&tunnel, &host.alias, true)
        } else {
            ssh_arguments(&tunnel, &host.alias)
        };
        let broker = if password_authentication {
            if !self.askpass_executable.is_file() {
                bail!("Aegiz SSH password helper is missing from the app bundle");
            }
            Some(AskpassBroker::bind(&self.runtime_directory, authentication_secret).await?)
        } else {
            None
        };

        self.store
            .set_tunnel_status(id, TunnelStatus::Starting, None)
            .await?;
        self.store
            .audit("tunnel.start", Some(id), "started", "")
            .await?;

        let mut command = tokio::process::Command::new(&*self.watchdog_executable);
        command
            .args(&args)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            // The watchdog must outlive an abruptly dropped Rust handle long
            // enough to observe stdin EOF and terminate its OpenSSH child.
            .kill_on_drop(false);
        command.env("PATH", augmented_executable_path());
        if let Some(broker) = &broker {
            command
                .env("SSH_ASKPASS", &*self.askpass_executable)
                .env("SSH_ASKPASS_REQUIRE", "force")
                .env("DISPLAY", "aegiz:0")
                .env("AEGIZ_ASKPASS_SOCKET", &broker.socket_path)
                .env("AEGIZ_ASKPASS_TOKEN", &broker.token);
        }
        let mut child = command.spawn().context("could not launch OpenSSH")?;
        let stop_pipe = child
            .stdin
            .take()
            .ok_or_else(|| anyhow!("could not create the tunnel watchdog control pipe"))?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| anyhow!("could not capture tunnel diagnostics"))?;
        let mut process = ManagedTunnel {
            stop_pipe: Some(stop_pipe),
            child,
            stderr: CapturedStderr::spawn(stderr),
        };

        if let Some(broker) = broker {
            match wait_for_authentication(&mut process.child, broker.delivery).await? {
                AuthenticationOutcome::Delivered => {}
                AuthenticationOutcome::Exited(status) => {
                    return self.fail_start(id, process, status).await;
                }
                AuthenticationOutcome::TimedOut => {
                    let result = process.shutdown().await.ok();
                    let code = result.as_ref().and_then(|(status, _)| status.code());
                    let detail =
                        compact_error(result.as_ref().map_or("", |(_, stderr)| stderr), code);
                    let message = format!(
                        "OpenSSH did not request the configured password before the authentication timeout. {detail}"
                    );
                    self.record_start_failure(id, &message).await?;
                    bail!(message);
                }
                AuthenticationOutcome::BrokerFailed(message) => {
                    let _ = process.shutdown().await;
                    self.record_start_failure(id, &message).await?;
                    bail!(message);
                }
            }
        }

        match wait_for_forward_ready(&mut process.child, &tunnel).await? {
            StartupOutcome::Ready => {}
            StartupOutcome::Exited(status) => {
                return self.fail_start(id, process, status).await;
            }
            StartupOutcome::TimedOut => {
                let result = process.shutdown().await.ok();
                let code = result.as_ref().and_then(|(status, _)| status.code());
                let detail = compact_error(result.as_ref().map_or("", |(_, stderr)| stderr), code);
                let message = format!(
                    "OpenSSH did not make the forward ready within {} seconds. {detail}",
                    STARTUP_TIMEOUT.as_secs()
                );
                self.record_start_failure(id, &message).await?;
                bail!(message);
            }
        }
        self.children.lock().await.insert(id, process);

        self.store
            .set_tunnel_status(id, TunnelStatus::Running, None)
            .await?;
        self.store
            .audit("tunnel.start", Some(id), "running", "")
            .await?;
        Ok(())
    }

    async fn fail_start(&self, id: Uuid, process: ManagedTunnel, status: ExitStatus) -> Result<()> {
        let (_, stderr) = process.finish().await?;
        let message = compact_error(&stderr, status.code());
        self.record_start_failure(id, &message).await?;
        bail!(message)
    }

    async fn record_start_failure(&self, id: Uuid, message: &str) -> Result<()> {
        self.store
            .set_tunnel_status(id, TunnelStatus::Failed, Some(message))
            .await?;
        self.store
            .audit("tunnel.start", Some(id), "failed", message)
            .await?;
        Ok(())
    }

    pub async fn stop(&self, id: Uuid) -> Result<()> {
        self.store
            .set_tunnel_status(id, TunnelStatus::Stopping, None)
            .await?;
        let process = { self.children.lock().await.remove(&id) };
        if let Some(process) = process {
            process.shutdown().await?;
        }
        self.store
            .set_tunnel_status(id, TunnelStatus::Stopped, None)
            .await?;
        self.store
            .audit("tunnel.stop", Some(id), "stopped", "")
            .await?;
        Ok(())
    }

    pub async fn stop_all(&self) {
        let ids: Vec<Uuid> = self.children.lock().await.keys().copied().collect();
        for id in ids {
            let _ = self.stop(id).await;
        }
    }

    pub async fn reconcile(&self) -> Result<()> {
        let exited = {
            let mut children = self.children.lock().await;
            let mut statuses = Vec::new();
            for (id, process) in children.iter_mut() {
                if let Some(status) = process.child.try_wait()? {
                    statuses.push((*id, status));
                }
            }
            statuses
                .into_iter()
                .filter_map(|(id, status)| {
                    children.remove(&id).map(|process| (id, status, process))
                })
                .collect::<Vec<_>>()
        };
        for (id, status, process) in exited {
            let (_, stderr) = process.finish().await?;
            let message = format!(
                "OpenSSH tunnel stopped unexpectedly. {}",
                compact_error(&stderr, status.code())
            );
            self.record_start_failure(id, &message).await?;
        }
        Ok(())
    }
}

fn augmented_executable_path() -> String {
    let preferred = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ];
    let mut candidates = preferred.map(str::to_owned).to_vec();
    candidates.extend(
        std::env::var("PATH")
            .unwrap_or_default()
            .split(':')
            .map(str::to_owned),
    );
    let mut paths: Vec<String> = Vec::new();
    for path in candidates {
        if !path.is_empty() && !paths.iter().any(|existing| existing == &path) {
            paths.push(path);
        }
    }
    paths.join(":")
}

fn readiness_address(tunnel: &Tunnel) -> Option<String> {
    if tunnel.kind == TunnelKind::Remote {
        return None;
    }
    let host = match tunnel.bind_address.trim() {
        "" | "*" | "0.0.0.0" => "127.0.0.1",
        "::" | "[::]" => "::1",
        value => value.trim_matches(['[', ']']),
    };
    Some(if host.contains(':') {
        format!("[{host}]:{}", tunnel.local_port)
    } else {
        format!("{host}:{}", tunnel.local_port)
    })
}

async fn ensure_local_port_available(tunnel: &Tunnel) -> Result<()> {
    let Some(address) = readiness_address(tunnel) else {
        return Ok(());
    };
    if matches!(
        tokio::time::timeout(Duration::from_millis(150), TcpStream::connect(&address)).await,
        Ok(Ok(_))
    ) {
        bail!(
            "local endpoint {}:{} is already in use; stop the conflicting tunnel or choose another local port",
            tunnel.bind_address,
            tunnel.local_port
        );
    }
    Ok(())
}

enum StartupOutcome {
    Ready,
    Exited(ExitStatus),
    TimedOut,
}

async fn wait_for_forward_ready(child: &mut Child, tunnel: &Tunnel) -> Result<StartupOutcome> {
    let started = tokio::time::Instant::now();
    let address = readiness_address(tunnel);
    loop {
        if let Some(status) = child.try_wait()? {
            return Ok(StartupOutcome::Exited(status));
        }
        if let Some(address) = &address {
            if matches!(
                tokio::time::timeout(Duration::from_millis(150), TcpStream::connect(address)).await,
                Ok(Ok(_))
            ) {
                return Ok(StartupOutcome::Ready);
            }
        } else if started.elapsed() >= Duration::from_secs(1) {
            return Ok(StartupOutcome::Ready);
        }
        if started.elapsed() >= STARTUP_TIMEOUT {
            return Ok(StartupOutcome::TimedOut);
        }
        tokio::time::sleep(Duration::from_millis(75)).await;
    }
}

fn validate(tunnel: &Tunnel, alias: &str) -> Result<()> {
    if alias.starts_with('-') || alias.contains('\0') {
        bail!("unsafe SSH host alias");
    }
    if tunnel.local_port == 0 {
        bail!("local port must be between 1 and 65535");
    }
    if tunnel.kind != TunnelKind::Dynamic
        && (tunnel.remote_host.is_empty() || tunnel.remote_port == 0)
    {
        bail!("remote destination and port are required");
    }
    if tunnel.bind_address.contains(['\n', '\r']) || tunnel.remote_host.contains(['\n', '\r']) {
        bail!("tunnel address contains unsupported characters");
    }
    Ok(())
}

pub fn ssh_arguments(tunnel: &Tunnel, alias: &str) -> Vec<String> {
    ssh_arguments_for_auth(tunnel, alias, false)
}

fn ssh_arguments_for_auth(
    tunnel: &Tunnel,
    alias: &str,
    password_authentication: bool,
) -> Vec<String> {
    let forward = match tunnel.kind {
        TunnelKind::Local => format!(
            "{}:{}:{}:{}",
            tunnel.bind_address, tunnel.local_port, tunnel.remote_host, tunnel.remote_port
        ),
        TunnelKind::Remote => format!(
            "{}:{}:{}:{}",
            tunnel.bind_address, tunnel.local_port, tunnel.remote_host, tunnel.remote_port
        ),
        TunnelKind::Dynamic => format!("{}:{}", tunnel.bind_address, tunnel.local_port),
    };
    let direction = match tunnel.kind {
        TunnelKind::Local => "-L",
        TunnelKind::Remote => "-R",
        TunnelKind::Dynamic => "-D",
    };

    let mut arguments = vec![
        "-N".into(),
        "-T".into(),
        "-o".into(),
        format!(
            "BatchMode={}",
            if password_authentication { "no" } else { "yes" }
        ),
        "-o".into(),
        "ConnectTimeout=10".into(),
        "-o".into(),
        "ExitOnForwardFailure=yes".into(),
        "-o".into(),
        "ServerAliveInterval=30".into(),
        "-o".into(),
        "ServerAliveCountMax=3".into(),
    ];
    if password_authentication {
        arguments.extend([
            "-o".into(),
            "NumberOfPasswordPrompts=1".into(),
            "-o".into(),
            "PreferredAuthentications=keyboard-interactive,password".into(),
            "-o".into(),
            "PubkeyAuthentication=no".into(),
        ]);
    }
    arguments.extend([direction.into(), forward, alias.into()]);
    arguments
}

struct AskpassBroker {
    socket_path: PathBuf,
    token: String,
    delivery: oneshot::Receiver<std::result::Result<(), String>>,
}

impl AskpassBroker {
    async fn bind(runtime_directory: &Path, secret: CredentialLease) -> Result<Self> {
        // AF_UNIX paths are short on macOS. Keep the file name compact so the
        // private ~/Library/Caches/Aegiz directory remains usable.
        let identifier = Uuid::new_v4().simple().to_string();
        let socket_path = runtime_directory.join(format!("ap-{}.sock", &identifier[..8]));
        let listener = UnixListener::bind(&socket_path)
            .with_context(|| format!("could not create {}", socket_path.display()))?;
        tokio::fs::set_permissions(&socket_path, std::fs::Permissions::from_mode(0o600)).await?;
        let token = Uuid::new_v4().to_string();
        let expected_token = token.clone();
        let cleanup_path = socket_path.clone();
        let (sender, delivery) = oneshot::channel();
        tokio::spawn(async move {
            let result = tokio::time::timeout(AUTHENTICATION_TIMEOUT, async move {
                let (mut stream, _) = listener
                    .accept()
                    .await
                    .context("SSH password helper did not connect")?;
                let mut supplied_token = vec![0_u8; expected_token.len()];
                stream
                    .read_exact(&mut supplied_token)
                    .await
                    .context("SSH password helper sent an incomplete token")?;
                let accepted = supplied_token.as_slice() == expected_token.as_bytes();
                supplied_token.zeroize();
                if !accepted {
                    bail!("SSH password helper authentication failed");
                }
                stream
                    .write_all(secret.expose())
                    .await
                    .context("could not deliver the SSH password")?;
                stream.shutdown().await?;
                Ok::<(), anyhow::Error>(())
            })
            .await
            .map_err(|_| anyhow!("SSH password helper timed out"))
            .and_then(|value| value)
            .map_err(|error| error.to_string());
            let _ = tokio::fs::remove_file(&cleanup_path).await;
            let _ = sender.send(result);
        });
        Ok(Self {
            socket_path,
            token,
            delivery,
        })
    }
}

enum AuthenticationOutcome {
    Delivered,
    Exited(ExitStatus),
    TimedOut,
    BrokerFailed(String),
}

async fn wait_for_authentication(
    child: &mut Child,
    mut delivery: oneshot::Receiver<std::result::Result<(), String>>,
) -> Result<AuthenticationOutcome> {
    let deadline = tokio::time::Instant::now() + AUTHENTICATION_TIMEOUT;
    loop {
        tokio::select! {
            result = &mut delivery => {
                return Ok(match result {
                    Ok(Ok(())) => AuthenticationOutcome::Delivered,
                    Ok(Err(message)) => AuthenticationOutcome::BrokerFailed(message),
                    Err(_) => AuthenticationOutcome::BrokerFailed(
                        "SSH password helper stopped before delivering the secret".into()
                    ),
                });
            }
            _ = tokio::time::sleep(Duration::from_millis(50)) => {
                if let Some(status) = child.try_wait()? {
                    return Ok(AuthenticationOutcome::Exited(status));
                }
                if tokio::time::Instant::now() >= deadline {
                    return Ok(AuthenticationOutcome::TimedOut);
                }
            }
        }
    }
}

fn compact_error(stderr: &str, code: Option<i32>) -> String {
    let text = stderr
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .take(3)
        .collect::<Vec<_>>()
        .join(" ");
    if text.is_empty() {
        format!("OpenSSH exited before the tunnel was ready (code {code:?})")
    } else {
        text
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

    fn tunnel(kind: TunnelKind) -> Tunnel {
        let now = Utc::now();
        Tunnel {
            id: Uuid::new_v4(),
            host_id: Uuid::new_v4(),
            label: "database".into(),
            kind,
            bind_address: "127.0.0.1".into(),
            local_port: 5433,
            remote_host: "postgres.internal".into(),
            remote_port: 5432,
            status: TunnelStatus::Stopped,
            last_error: None,
            created_at: now,
            updated_at: now,
        }
    }

    #[test]
    fn local_forward_never_uses_a_shell() {
        let args = ssh_arguments(&tunnel(TunnelKind::Local), "prod-bastion");
        assert_eq!(
            args[args.len() - 3..],
            [
                "-L",
                "127.0.0.1:5433:postgres.internal:5432",
                "prod-bastion"
            ]
        );
    }

    #[test]
    fn dynamic_forward_has_no_destination() {
        let args = ssh_arguments(&tunnel(TunnelKind::Dynamic), "edge");
        assert_eq!(args[args.len() - 3..], ["-D", "127.0.0.1:5433", "edge"]);
    }

    #[test]
    fn password_authentication_uses_askpass_compatible_arguments_without_the_secret() {
        let args = ssh_arguments_for_auth(&tunnel(TunnelKind::Local), "password-host", true);
        assert!(args.iter().any(|value| value == "BatchMode=no"));
        assert!(
            args.iter()
                .any(|value| value == "PreferredAuthentications=keyboard-interactive,password")
        );
        assert!(
            args.iter()
                .any(|value| value == "NumberOfPasswordPrompts=1")
        );
        assert!(!args.iter().any(|value| value.contains("hunter2")));
    }

    #[test]
    fn runtime_path_contains_gui_safe_homebrew_and_system_locations_once() {
        let path = augmented_executable_path();
        let entries = path.split(':').collect::<Vec<_>>();
        assert!(entries.contains(&"/opt/homebrew/bin"));
        assert!(entries.contains(&"/usr/local/bin"));
        assert!(entries.contains(&"/usr/bin"));
        let unique = entries
            .iter()
            .copied()
            .collect::<std::collections::HashSet<_>>();
        assert_eq!(unique.len(), entries.len());
    }

    #[test]
    fn readiness_address_uses_loopback_for_wildcard_binds_and_skips_remote_forwards() {
        let mut route = tunnel(TunnelKind::Local);
        route.bind_address = "0.0.0.0".into();
        assert_eq!(readiness_address(&route).as_deref(), Some("127.0.0.1:5433"));
        route.bind_address = "::".into();
        assert_eq!(readiness_address(&route).as_deref(), Some("[::1]:5433"));
        route.kind = TunnelKind::Remote;
        assert_eq!(readiness_address(&route), None);
    }

    #[tokio::test]
    async fn occupied_local_endpoint_is_rejected_without_starting_ssh() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let mut route = tunnel(TunnelKind::Local);
        route.local_port = port;
        let error = ensure_local_port_available(&route).await.unwrap_err();
        assert!(error.to_string().contains("already in use"));
    }

    #[test]
    fn tunnel_error_storage_is_compact_and_omits_trailing_noise() {
        let message = compact_error("first\nsecond\nthird\nfourth\n", Some(255));
        assert_eq!(message, "first second third");
    }

    #[tokio::test]
    async fn askpass_broker_delivers_a_secret_once_over_a_private_socket() {
        let identifier = Uuid::new_v4().simple().to_string();
        let directory = std::env::temp_dir().join(format!("az-ap-{}", &identifier[..8]));
        tokio::fs::create_dir(&directory).await.unwrap();
        tokio::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700))
            .await
            .unwrap();
        let broker = AskpassBroker::bind(
            &directory,
            CredentialLease::new(b"temporary-password".to_vec()).unwrap(),
        )
        .await
        .unwrap();
        let socket = broker.socket_path.clone();
        let token = broker.token.clone();
        let client = tokio::spawn(async move {
            let mut stream = tokio::net::UnixStream::connect(socket).await.unwrap();
            stream.write_all(token.as_bytes()).await.unwrap();
            stream.shutdown().await.unwrap();
            let mut received = Vec::new();
            stream.read_to_end(&mut received).await.unwrap();
            received
        });
        assert!(broker.delivery.await.unwrap().is_ok());
        assert_eq!(client.await.unwrap(), b"temporary-password");
        tokio::fs::remove_dir(&directory).await.unwrap();
    }
}
