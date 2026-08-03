use crate::proto::{OperationEvent, ToolCapability};
use aegiz_storage::Store;
use anyhow::{Context, Result, anyhow, bail};
use regex::Regex;
use std::{
    collections::HashMap,
    path::PathBuf,
    process::Stdio,
    sync::{
        Arc, LazyLock,
        atomic::{AtomicU64, Ordering},
    },
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWriteExt},
    process::Command,
    sync::{Mutex, mpsc, oneshot},
};
use uuid::Uuid;

mod catalog;
mod policy;

use catalog::{TOOLS, ToolSpec, detect_version, is_executable, resolve_executable, tool_spec};
pub use policy::{redact, requires_confirmation};

const MAX_ARGUMENTS: usize = 128;
const MAX_ARGUMENT_BYTES: usize = 32 * 1024;
const MAX_STREAM_LINE_BYTES: usize = 16 * 1024;

type EventSender = mpsc::Sender<Result<OperationEvent, tonic::Status>>;

#[derive(Clone)]
pub struct AdapterRuntime {
    store: Store,
    cancellations: Arc<Mutex<HashMap<Uuid, oneshot::Sender<()>>>>,
    executable_overrides: Arc<HashMap<String, PathBuf>>,
    #[cfg(test)]
    invocation_prefix_overrides: Arc<HashMap<String, Vec<String>>>,
}

impl AdapterRuntime {
    pub fn new(store: Store) -> Self {
        Self {
            store,
            cancellations: Arc::new(Mutex::new(HashMap::new())),
            executable_overrides: Arc::new(HashMap::new()),
            #[cfg(test)]
            invocation_prefix_overrides: Arc::new(HashMap::new()),
        }
    }

    #[cfg(test)]
    fn with_executable_override(mut self, adapter_id: &str, executable: PathBuf) -> Self {
        let mut overrides = self.executable_overrides.as_ref().clone();
        overrides.insert(adapter_id.to_owned(), executable);
        self.executable_overrides = Arc::new(overrides);
        self
    }

    #[cfg(test)]
    fn with_invocation_prefix(mut self, adapter_id: &str, arguments: Vec<String>) -> Self {
        let mut overrides = self.invocation_prefix_overrides.as_ref().clone();
        overrides.insert(adapter_id.to_owned(), arguments);
        self.invocation_prefix_overrides = Arc::new(overrides);
        self
    }

    fn executable(&self, spec: &ToolSpec) -> Option<PathBuf> {
        self.executable_overrides
            .get(spec.id)
            .filter(|path| is_executable(path))
            .cloned()
            .or_else(|| resolve_executable(spec))
    }

    pub async fn capabilities(&self) -> Vec<ToolCapability> {
        let mut capabilities = Vec::with_capacity(TOOLS.len());
        for spec in TOOLS {
            let Some(path) = self.executable(spec) else {
                capabilities.push(ToolCapability {
                    id: spec.id.into(),
                    label: spec.label.into(),
                    available: false,
                    executable_path: String::new(),
                    version: String::new(),
                    diagnostic: "Not found in trusted system locations".into(),
                    runnable: spec.runnable,
                });
                continue;
            };
            let (version, diagnostic) = detect_version(spec, &path).await;
            capabilities.push(ToolCapability {
                id: spec.id.into(),
                label: spec.label.into(),
                available: true,
                executable_path: path.display().to_string(),
                version,
                diagnostic,
                runnable: spec.runnable,
            });
        }
        capabilities
    }

    pub async fn execute(
        &self,
        operation_id: Uuid,
        adapter_id: String,
        arguments: Vec<String>,
        working_directory: String,
        confirmed_mutation: bool,
        sender: EventSender,
    ) {
        let sequence = Arc::new(AtomicU64::new(1));
        let result = self
            .execute_inner(
                operation_id,
                &adapter_id,
                &arguments,
                &working_directory,
                confirmed_mutation,
                &sender,
                sequence.clone(),
            )
            .await;

        self.cancellations.lock().await.remove(&operation_id);
        let (message, success, outcome, exit_code) = match result {
            Ok(ExecutionOutcome::Exited(code)) if code == 0 => {
                ("Command completed".to_owned(), true, "success", code)
            }
            Ok(ExecutionOutcome::Exited(code)) => (
                format!("Command exited with status {code}"),
                false,
                "failed",
                code,
            ),
            Ok(ExecutionOutcome::Cancelled) => {
                ("Operation cancelled".to_owned(), false, "cancelled", -1)
            }
            Err(error) => (redact(&error.to_string()), false, "failed", -1),
        };

        let _ = self
            .store
            .audit(
                "adapter.run",
                Some(operation_id),
                outcome,
                &format!(
                    "adapter={adapter_id} arguments={} exit_code={exit_code}",
                    arguments.len()
                ),
            )
            .await;
        send_event(
            &sender,
            &sequence,
            OperationEvent {
                operation_id: operation_id.to_string(),
                phase: outcome.into(),
                message,
                progress: 100,
                terminal: true,
                success,
                stream: "system".into(),
                sequence: 0,
                exit_code,
            },
        )
        .await;
    }

    // The execution boundary keeps each security-relevant input explicit.
    #[allow(clippy::too_many_arguments)]
    async fn execute_inner(
        &self,
        operation_id: Uuid,
        adapter_id: &str,
        arguments: &[String],
        working_directory: &str,
        confirmed_mutation: bool,
        sender: &EventSender,
        sequence: Arc<AtomicU64>,
    ) -> Result<ExecutionOutcome> {
        validate_arguments(arguments)?;
        let spec = tool_spec(adapter_id).ok_or_else(|| anyhow!("unknown adapter"))?;
        if !spec.runnable {
            bail!("this capability cannot be run from the operations console");
        }
        validate_adapter_arguments(adapter_id, arguments)?;
        let executable = self
            .executable(spec)
            .ok_or_else(|| anyhow!("{} is not installed", spec.label))?;
        let mutation = requires_confirmation(adapter_id, arguments);
        if mutation && !confirmed_mutation {
            bail!("this command can change infrastructure and requires confirmation");
        }
        let working_directory = validate_working_directory(working_directory).await?;

        self.store
            .audit(
                "adapter.run",
                Some(operation_id),
                "started",
                &format!(
                    "adapter={adapter_id} arguments={} mutation={mutation}",
                    arguments.len()
                ),
            )
            .await?;
        let (process_arguments, standard_input) =
            prepare_adapter_invocation(adapter_id, arguments).await?;
        let mut command = Command::new(executable);
        #[cfg(test)]
        if let Some(prefix) = self.invocation_prefix_overrides.get(adapter_id) {
            command.args(prefix);
        }
        command
            .args(process_arguments)
            .stdin(if standard_input.is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        if let Some(directory) = working_directory {
            command.current_dir(directory);
        }
        let mut child = command
            .spawn()
            .with_context(|| format!("could not launch {}", spec.label))?;
        if let Some(input) = standard_input {
            let mut stdin = child
                .stdin
                .take()
                .ok_or_else(|| anyhow!("stdin pipe is unavailable"))?;
            stdin
                .write_all(input.as_bytes())
                .await
                .context("could not send the SFTP request")?;
            stdin.shutdown().await.ok();
        }
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| anyhow!("stdout pipe is unavailable"))?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| anyhow!("stderr pipe is unavailable"))?;

        let stdout_task = tokio::spawn(stream_output(
            stdout,
            "stdout",
            operation_id,
            sender.clone(),
            sequence.clone(),
        ));
        let stderr_task = tokio::spawn(stream_output(
            stderr,
            "stderr",
            operation_id,
            sender.clone(),
            sequence.clone(),
        ));
        let (cancel_sender, cancel_receiver) = oneshot::channel();
        self.cancellations
            .lock()
            .await
            .insert(operation_id, cancel_sender);
        // Publish the operation only after cancellation is registered. This
        // makes the first visible Cancel action deterministic, even for a
        // process that starts slowly or exits quickly.
        send_event(
            sender,
            &sequence,
            OperationEvent {
                operation_id: operation_id.to_string(),
                phase: "running".into(),
                message: format!("Running {}", spec.label),
                progress: 5,
                terminal: false,
                success: false,
                stream: "system".into(),
                sequence: 0,
                exit_code: 0,
            },
        )
        .await;

        let outcome = tokio::select! {
            status = child.wait() => {
                let status = status.context("could not wait for adapter process")?;
                ExecutionOutcome::Exited(status.code().unwrap_or(-1))
            }
            _ = cancel_receiver => {
                child.kill().await.context("could not cancel adapter process")?;
                let _ = child.wait().await;
                ExecutionOutcome::Cancelled
            }
        };
        let _ = stdout_task.await;
        let _ = stderr_task.await;
        Ok(outcome)
    }

    pub async fn cancel(&self, operation_id: Uuid) -> bool {
        self.cancellations
            .lock()
            .await
            .remove(&operation_id)
            .is_some_and(|sender| sender.send(()).is_ok())
    }

    pub async fn cancel_all(&self) {
        let senders = self
            .cancellations
            .lock()
            .await
            .drain()
            .map(|(_, sender)| sender)
            .collect::<Vec<_>>();
        for sender in senders {
            let _ = sender.send(());
        }
    }
}

enum ExecutionOutcome {
    Exited(i32),
    Cancelled,
}

async fn stream_output<R>(
    mut reader: R,
    stream: &'static str,
    operation_id: Uuid,
    sender: EventSender,
    sequence: Arc<AtomicU64>,
) where
    R: AsyncRead + Unpin,
{
    let mut chunk = [0_u8; 4096];
    let mut pending = Vec::new();
    let mut discarding_long_line = false;

    loop {
        let count = match reader.read(&mut chunk).await {
            Ok(0) => break,
            Ok(count) => count,
            Err(_) => break,
        };
        let mut start = 0;
        if discarding_long_line {
            if let Some(position) = chunk[..count].iter().position(|byte| *byte == b'\n') {
                discarding_long_line = false;
                start = position + 1;
            } else {
                continue;
            }
        }
        pending.extend_from_slice(&chunk[start..count]);

        while let Some(position) = pending
            .iter()
            .position(|byte| matches!(*byte, b'\n' | b'\r'))
        {
            let remainder = pending.split_off(position + 1);
            let line = std::mem::replace(&mut pending, remainder);
            if line.iter().any(|byte| !byte.is_ascii_whitespace()) {
                send_output(&sender, &sequence, operation_id, stream, &line).await;
            }
        }
        if pending.len() > MAX_STREAM_LINE_BYTES {
            send_output(
                &sender,
                &sequence,
                operation_id,
                stream,
                b"[output line omitted: exceeded 16 KiB safety limit]\n",
            )
            .await;
            pending.clear();
            discarding_long_line = true;
        }
    }
    if !pending.is_empty() && !discarding_long_line {
        send_output(&sender, &sequence, operation_id, stream, &pending).await;
    }
}

async fn send_output(
    sender: &EventSender,
    sequence: &AtomicU64,
    operation_id: Uuid,
    stream: &str,
    bytes: &[u8],
) {
    let message = redact(&String::from_utf8_lossy(bytes));
    let progress = transfer_progress(&message).unwrap_or(50);
    send_event(
        sender,
        sequence,
        OperationEvent {
            operation_id: operation_id.to_string(),
            phase: "running".into(),
            message,
            progress,
            terminal: false,
            success: false,
            stream: stream.into(),
            sequence: 0,
            exit_code: 0,
        },
    )
    .await;
}

static TRANSFER_PROGRESS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?:^|\s)(100|[1-9]?\d)%").expect("valid progress regex"));

fn transfer_progress(value: &str) -> Option<u32> {
    TRANSFER_PROGRESS
        .captures_iter(value)
        .last()
        .and_then(|captures| captures.get(1))
        .and_then(|value| value.as_str().parse().ok())
}

async fn send_event(sender: &EventSender, sequence: &AtomicU64, mut event: OperationEvent) {
    event.sequence = sequence.fetch_add(1, Ordering::Relaxed);
    let _ = sender.send(Ok(event)).await;
}

fn validate_arguments(arguments: &[String]) -> Result<()> {
    if arguments.len() > MAX_ARGUMENTS {
        bail!("too many command arguments");
    }
    let total_bytes = arguments.iter().map(String::len).sum::<usize>();
    if total_bytes > MAX_ARGUMENT_BYTES {
        bail!("command arguments exceed the 32 KiB safety limit");
    }
    if arguments
        .iter()
        .any(|argument| argument.contains('\0') || argument.contains(['\n', '\r']))
    {
        bail!("command arguments contain unsupported control characters");
    }
    Ok(())
}

fn validate_adapter_arguments(adapter_id: &str, arguments: &[String]) -> Result<()> {
    if adapter_id == "sftp" {
        return validate_sftp_arguments(arguments);
    }
    if adapter_id != "ssh-host" {
        return Ok(());
    }
    const PREFIX: &[&str] = &[
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=10",
        "-o",
        "ConnectionAttempts=1",
    ];
    if arguments.len() != PREFIX.len() + 2
        || !arguments
            .iter()
            .take(PREFIX.len())
            .zip(PREFIX)
            .all(|(actual, expected)| actual == expected)
    {
        bail!("SSH host operations require Aegiz's fixed connection options");
    }
    let alias = &arguments[PREFIX.len()];
    if alias.is_empty()
        || alias.len() > 253
        || alias.starts_with('-')
        || !alias
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_'))
    {
        bail!("SSH host alias is invalid");
    }
    if arguments[PREFIX.len() + 1].trim().is_empty() {
        bail!("remote command is required");
    }
    Ok(())
}

fn validate_sftp_arguments(arguments: &[String]) -> Result<()> {
    let Some(alias) = arguments.first() else {
        bail!("SFTP host alias is required");
    };
    if alias.is_empty()
        || alias.len() > 253
        || alias.starts_with('-')
        || !alias
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_'))
    {
        bail!("SFTP host alias is invalid");
    }
    let operation = arguments.get(1).map(String::as_str).unwrap_or_default();
    let expected = match operation {
        "list" | "mkdir" | "delete" | "rmdir" => 3,
        "upload" | "download" | "rename" | "chmod" => 4,
        _ => bail!("unsupported SFTP operation"),
    };
    if arguments.len() != expected {
        bail!("SFTP operation has an invalid number of fields");
    }
    for value in &arguments[2..] {
        if value.is_empty() || value.len() > 4096 {
            bail!("SFTP path is empty or exceeds 4 KiB");
        }
    }
    if operation == "chmod"
        && (!arguments[2].bytes().all(|byte| matches!(byte, b'0'..=b'7'))
            || !matches!(arguments[2].len(), 3 | 4))
    {
        bail!("SFTP mode must be a three or four digit octal value");
    }
    Ok(())
}

async fn prepare_adapter_invocation(
    adapter_id: &str,
    arguments: &[String],
) -> Result<(Vec<String>, Option<String>)> {
    if adapter_id != "sftp" {
        return Ok((arguments.to_vec(), None));
    }
    let alias = &arguments[0];
    let operation = arguments[1].as_str();
    let command = match operation {
        "list" => format!("ls -la {}", sftp_quote(&arguments[2])),
        "mkdir" => format!("mkdir {}", sftp_quote(&arguments[2])),
        "delete" => format!("rm {}", sftp_quote(&arguments[2])),
        "rmdir" => format!("rmdir {}", sftp_quote(&arguments[2])),
        "rename" => format!(
            "rename {} {}",
            sftp_quote(&arguments[2]),
            sftp_quote(&arguments[3])
        ),
        "chmod" => format!("chmod {} {}", arguments[2], sftp_quote(&arguments[3])),
        "upload" => {
            let local = PathBuf::from(&arguments[2]);
            if !local.is_absolute() || !tokio::fs::metadata(&local).await.is_ok_and(|m| m.is_file())
            {
                bail!("local upload source must be an existing absolute file");
            }
            format!(
                "put -p {} {}",
                sftp_quote(&arguments[2]),
                sftp_quote(&arguments[3])
            )
        }
        "download" => {
            let local = PathBuf::from(&arguments[3]);
            let parent = local
                .parent()
                .ok_or_else(|| anyhow!("local download destination has no parent"))?;
            if !local.is_absolute()
                || !tokio::fs::metadata(parent)
                    .await
                    .is_ok_and(|metadata| metadata.is_dir())
            {
                bail!("local download destination must have an existing absolute parent");
            }
            format!(
                "get -p {} {}",
                sftp_quote(&arguments[2]),
                sftp_quote(&arguments[3])
            )
        }
        _ => bail!("unsupported SFTP operation"),
    };
    let process_arguments = vec![
        "-N".into(),
        "-oBatchMode=yes".into(),
        "-oConnectTimeout=10".into(),
        "-oConnectionAttempts=1".into(),
        "-b".into(),
        "-".into(),
        alias.clone(),
    ];
    Ok((process_arguments, Some(format!("@{command}\n@quit\n"))))
}

fn sftp_quote(value: &str) -> String {
    let escaped = value.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{escaped}\"")
}

async fn validate_working_directory(value: &str) -> Result<Option<PathBuf>> {
    if value.trim().is_empty() {
        return Ok(None);
    }
    let path = PathBuf::from(value);
    if !path.is_absolute() {
        bail!("working directory must be an absolute path");
    }
    let metadata = tokio::fs::metadata(&path)
        .await
        .context("working directory is unavailable")?;
    if !metadata.is_dir() {
        bail!("working directory is not a directory");
    }
    Ok(Some(path))
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn run_fixture(
        runtime: &AdapterRuntime,
        adapter_id: &str,
        arguments: Vec<String>,
        confirmed_mutation: bool,
    ) -> Vec<OperationEvent> {
        let operation_id = Uuid::new_v4();
        let (sender, mut receiver) = mpsc::channel(64);
        runtime
            .execute(
                operation_id,
                adapter_id.into(),
                arguments,
                String::new(),
                confirmed_mutation,
                sender,
            )
            .await;
        let mut events = Vec::new();
        while let Some(event) = receiver.recv().await {
            events.push(event.unwrap());
        }
        events
    }

    fn fixture_runtime(store: Store) -> AdapterRuntime {
        let mut runtime = AdapterRuntime::new(store);
        for adapter in [
            "ssh-host",
            "docker",
            "kubectl",
            "aws",
            "terraform",
            "ansible",
            "ansible-playbook",
            "ansible-inventory",
        ] {
            runtime = runtime.with_executable_override(adapter, PathBuf::from("/bin/echo"));
        }
        runtime.with_executable_override("sftp", PathBuf::from("/bin/cat"))
    }

    #[tokio::test]
    async fn disposable_capability_matrix_runs_every_registered_adapter_without_real_infra() {
        let runtime = fixture_runtime(Store::in_memory().await.unwrap());
        let cases = [
            (
                "ssh-host",
                vec![
                    "-o",
                    "BatchMode=yes",
                    "-o",
                    "ConnectTimeout=10",
                    "-o",
                    "ConnectionAttempts=1",
                    "fixture-host",
                    "uptime",
                ],
            ),
            ("sftp", vec!["fixture-host", "list", "/tmp"]),
            ("docker", vec!["ps"]),
            ("kubectl", vec!["get", "pods"]),
            ("aws", vec!["ec2", "describe-instances"]),
            ("terraform", vec!["version"]),
            ("ansible", vec!["--version"]),
            ("ansible-playbook", vec!["--version"]),
            ("ansible-inventory", vec!["--version"]),
        ];
        let registered = TOOLS
            .iter()
            .filter(|spec| spec.runnable)
            .map(|spec| spec.id)
            .collect::<std::collections::BTreeSet<_>>();
        let covered = cases
            .iter()
            .map(|(adapter, _)| *adapter)
            .collect::<std::collections::BTreeSet<_>>();
        assert_eq!(
            covered, registered,
            "every runnable adapter needs a fixture case"
        );

        for (adapter, arguments) in cases {
            let events = run_fixture(
                &runtime,
                adapter,
                arguments.into_iter().map(str::to_owned).collect(),
                false,
            )
            .await;
            let terminal = events.last().unwrap();
            assert!(terminal.terminal, "{adapter}");
            if adapter == "sftp" {
                assert!(!terminal.success);
                assert_eq!(terminal.phase, "failed");
                assert_eq!(terminal.exit_code, 1);
            } else {
                assert!(terminal.success, "{adapter}: {}", terminal.message);
                assert_eq!(terminal.phase, "success", "{adapter}");
            }
        }
    }

    #[tokio::test]
    async fn disposable_failure_matrix_is_bounded_redacted_and_conservative() {
        let store = Store::in_memory().await.unwrap();
        let runtime = fixture_runtime(store.clone());

        let unknown = run_fixture(&runtime, "unknown", Vec::new(), false).await;
        assert!(unknown.last().unwrap().message.contains("unknown adapter"));

        let non_runnable = run_fixture(&runtime, "openssh", Vec::new(), false).await;
        assert!(
            non_runnable
                .last()
                .unwrap()
                .message
                .contains("cannot be run")
        );

        let denied = run_fixture(
            &runtime,
            "docker",
            vec!["rm".into(), "fixture".into()],
            false,
        )
        .await;
        assert!(
            denied
                .last()
                .unwrap()
                .message
                .contains("requires confirmation")
        );

        let redacted = run_fixture(
            &runtime,
            "docker",
            vec![
                "ps".into(),
                "--filter".into(),
                "token=fixture-secret".into(),
            ],
            false,
        )
        .await;
        let output = redacted
            .iter()
            .map(|event| event.message.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        assert!(!output.contains("fixture-secret"));
        assert!(output.contains("token=[REDACTED]"));

        let long_line = run_fixture(
            &runtime,
            "docker",
            vec!["fixture".into(), "x".repeat(MAX_STREAM_LINE_BYTES + 100)],
            true,
        )
        .await;
        assert!(long_line.iter().any(|event| {
            event
                .message
                .contains("output line omitted: exceeded 16 KiB")
        }));

        let failed_runtime = AdapterRuntime::new(store)
            .with_executable_override("docker", PathBuf::from("/usr/bin/false"));
        let failed = run_fixture(&failed_runtime, "docker", vec!["ps".into()], false).await;
        let terminal = failed.last().unwrap();
        assert!(!terminal.success);
        assert_eq!(terminal.exit_code, 1);
    }

    #[tokio::test]
    #[ignore = "requires the disposable OpenSSH fixture started by scripts/test-ssh-fixtures.sh"]
    async fn native_openssh_host_ops_and_sftp_round_trip() {
        let port = std::env::var("AEGIZ_SSH_FIXTURE_PORT")
            .expect("AEGIZ_SSH_FIXTURE_PORT")
            .parse::<u16>()
            .expect("fixture port");
        let identity = std::env::var("AEGIZ_SSH_FIXTURE_IDENTITY")
            .map(PathBuf::from)
            .expect("AEGIZ_SSH_FIXTURE_IDENTITY");
        let known_hosts = std::env::var("AEGIZ_SSH_FIXTURE_KNOWN_HOSTS")
            .map(PathBuf::from)
            .expect("AEGIZ_SSH_FIXTURE_KNOWN_HOSTS");
        let local_directory = std::env::var("AEGIZ_SSH_FIXTURE_LOCAL_DIR")
            .map(PathBuf::from)
            .expect("AEGIZ_SSH_FIXTURE_LOCAL_DIR");

        let common = vec![
            "-F".into(),
            "/dev/null".into(),
            "-i".into(),
            identity.display().to_string(),
            "-oIdentitiesOnly=yes".into(),
            "-oPasswordAuthentication=no".into(),
            "-oKbdInteractiveAuthentication=no".into(),
            "-oStrictHostKeyChecking=yes".into(),
            format!("-oUserKnownHostsFile={}", known_hosts.display()),
            "-oUser=aegiz".into(),
        ];
        let mut ssh_prefix = common.clone();
        ssh_prefix.extend(["-p".into(), port.to_string()]);
        let mut sftp_prefix = common;
        sftp_prefix.extend(["-P".into(), port.to_string()]);

        let store = Store::in_memory().await.unwrap();
        let runtime = AdapterRuntime::new(store.clone())
            .with_executable_override("ssh-host", PathBuf::from("/usr/bin/ssh"))
            .with_executable_override("sftp", PathBuf::from("/usr/bin/sftp"))
            .with_invocation_prefix("ssh-host", ssh_prefix)
            .with_invocation_prefix("sftp", sftp_prefix);
        let host_arguments = |command: &str| {
            vec![
                "-o".into(),
                "BatchMode=yes".into(),
                "-o".into(),
                "ConnectTimeout=10".into(),
                "-o".into(),
                "ConnectionAttempts=1".into(),
                "127.0.0.1".into(),
                command.into(),
            ]
        };

        let uptime = run_fixture(&runtime, "ssh-host", host_arguments("uptime"), false).await;
        assert_terminal_success("host uptime", &uptime);
        assert!(uptime.iter().any(|event| event.stream == "stdout"));

        let redacted = run_fixture(
            &runtime,
            "ssh-host",
            host_arguments("printf 'token=fixture-secret\\n'"),
            true,
        )
        .await;
        assert_terminal_success("host redaction", &redacted);
        let redacted_output = event_output(&redacted);
        assert!(!redacted_output.contains("fixture-secret"));
        assert!(redacted_output.contains("token=[REDACTED]"));

        let remote_directory = "/home/aegiz/fixture";
        let initial = run_fixture(
            &runtime,
            "sftp",
            vec!["127.0.0.1".into(), "list".into(), remote_directory.into()],
            false,
        )
        .await;
        assert_terminal_success("initial SFTP listing", &initial);
        assert!(event_output(&initial).contains("seed file.txt"));

        let upload_source = local_directory.join("upload source.txt");
        let upload_bytes = b"Aegiz disposable SFTP fixture\n";
        tokio::fs::write(&upload_source, upload_bytes)
            .await
            .unwrap();
        let remote_upload = format!("{remote_directory}/uploaded file.txt");
        let uploaded = run_fixture(
            &runtime,
            "sftp",
            vec![
                "127.0.0.1".into(),
                "upload".into(),
                upload_source.display().to_string(),
                remote_upload.clone(),
            ],
            true,
        )
        .await;
        assert_terminal_success("SFTP upload", &uploaded);

        let remote_renamed = format!("{remote_directory}/renamed file.txt");
        let renamed = run_fixture(
            &runtime,
            "sftp",
            vec![
                "127.0.0.1".into(),
                "rename".into(),
                remote_upload,
                remote_renamed.clone(),
            ],
            true,
        )
        .await;
        assert_terminal_success("SFTP rename", &renamed);

        let chmod = run_fixture(
            &runtime,
            "sftp",
            vec![
                "127.0.0.1".into(),
                "chmod".into(),
                "640".into(),
                remote_renamed.clone(),
            ],
            true,
        )
        .await;
        assert_terminal_success("SFTP chmod", &chmod);

        let download_target = local_directory.join("downloaded file.txt");
        let downloaded = run_fixture(
            &runtime,
            "sftp",
            vec![
                "127.0.0.1".into(),
                "download".into(),
                remote_renamed.clone(),
                download_target.display().to_string(),
            ],
            true,
        )
        .await;
        assert_terminal_success("SFTP download", &downloaded);
        assert_eq!(
            tokio::fs::read(download_target).await.unwrap(),
            upload_bytes
        );

        let removed = run_fixture(
            &runtime,
            "sftp",
            vec!["127.0.0.1".into(), "delete".into(), remote_renamed],
            true,
        )
        .await;
        assert_terminal_success("SFTP delete", &removed);

        let audit = store.list_audit_events(100).await.unwrap();
        assert!(audit.iter().any(|event| event.outcome == "success"));
        assert!(
            audit
                .iter()
                .all(|event| !event.detail.contains("fixture-secret"))
        );

        let operation_id = Uuid::new_v4();
        let (sender, mut receiver) = mpsc::channel(16);
        let executor = {
            let runtime = runtime.clone();
            tokio::spawn(async move {
                runtime
                    .execute(
                        operation_id,
                        "ssh-host".into(),
                        host_arguments("sleep 30"),
                        String::new(),
                        true,
                        sender,
                    )
                    .await;
            })
        };
        let running = tokio::time::timeout(Duration::from_secs(5), receiver.recv())
            .await
            .expect("SSH fixture should start")
            .expect("running event")
            .unwrap();
        assert_eq!(running.phase, "running");
        assert!(runtime.cancel(operation_id).await);
        executor.await.unwrap();
        let mut terminal = None;
        while let Some(event) = receiver.recv().await {
            let event = event.unwrap();
            if event.terminal {
                terminal = Some(event);
            }
        }
        assert_eq!(
            terminal.expect("terminal cancellation event").phase,
            "cancelled"
        );
    }

    fn assert_terminal_success(label: &str, events: &[OperationEvent]) {
        let terminal = events.last().expect("terminal event");
        assert!(terminal.terminal, "{label}");
        assert!(terminal.success, "{label}: {}", event_output(events));
        assert_eq!(terminal.phase, "success", "{label}");
        assert_eq!(terminal.exit_code, 0, "{label}");
    }

    fn event_output(events: &[OperationEvent]) -> String {
        events
            .iter()
            .map(|event| event.message.as_str())
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[tokio::test]
    async fn immediate_adapter_cancellation_cannot_lose_the_registration_race() {
        let runtime = AdapterRuntime::new(Store::in_memory().await.unwrap())
            .with_executable_override("docker", PathBuf::from("/bin/sleep"));
        let operation_id = Uuid::new_v4();
        let (sender, mut receiver) = mpsc::channel(16);
        let executor = {
            let runtime = runtime.clone();
            tokio::spawn(async move {
                runtime
                    .execute(
                        operation_id,
                        "docker".into(),
                        vec!["30".into()],
                        String::new(),
                        true,
                        sender,
                    )
                    .await;
            })
        };
        let running = tokio::time::timeout(Duration::from_secs(1), receiver.recv())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert_eq!(running.operation_id, operation_id.to_string());
        assert!(runtime.cancel(operation_id).await);

        let terminal = tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                let event = receiver.recv().await.unwrap().unwrap();
                if event.terminal {
                    break event;
                }
            }
        })
        .await
        .unwrap();
        assert_eq!(terminal.phase, "cancelled");
        assert!(!terminal.success);
        executor.await.unwrap();
    }

    #[tokio::test]
    async fn capability_detection_honors_a_trusted_executable_fixture_override() {
        let runtime = AdapterRuntime::new(Store::in_memory().await.unwrap())
            .with_executable_override("docker", PathBuf::from("/bin/echo"));
        let capabilities = runtime.capabilities().await;
        let docker = capabilities
            .iter()
            .find(|capability| capability.id == "docker")
            .unwrap();
        assert!(docker.available);
        assert!(docker.runnable);
        assert_eq!(docker.executable_path, "/bin/echo");
        assert_eq!(docker.version, "--version");
    }

    #[test]
    fn missing_capability_is_reported_without_path_search() {
        let spec = ToolSpec {
            id: "missing-fixture",
            label: "Missing fixture",
            candidates: &["/aegiz-fixtures/does-not-exist"],
            version_arguments: &["--version"],
            runnable: true,
        };
        assert!(resolve_executable(&spec).is_none());
    }

    #[test]
    fn secrets_are_redacted_from_stream_output() {
        let input = "token=abc123 password: hunter2 Bearer eyJhbGci.abc AKIA1234567890ABCDEF";
        let output = redact(input);
        assert!(!output.contains("abc123"));
        assert!(!output.contains("hunter2"));
        assert!(!output.contains("eyJhbGci"));
        assert!(!output.contains("AKIA1234567890ABCDEF"));
    }

    #[test]
    fn every_external_adapter_uses_the_shared_secret_redactor() {
        for adapter in [
            "ssh-host",
            "sftp",
            "docker",
            "kubectl",
            "aws",
            "terraform",
            "ansible",
            "ansible-playbook",
            "ansible-inventory",
        ] {
            let raw = format!(
                "{adapter}: password=hunter2 token=abc123 Authorization=BearerSecret \
                 postgres://admin:supersecret@database.internal/app"
            );
            let output = redact(&raw);
            assert!(!output.contains("hunter2"), "{adapter}");
            assert!(!output.contains("abc123"), "{adapter}");
            assert!(!output.contains("BearerSecret"), "{adapter}");
            assert!(!output.contains("supersecret"), "{adapter}");
        }
    }

    #[test]
    fn openssh_transfer_progress_is_extracted() {
        assert_eq!(
            transfer_progress("archive.tar.gz  42%  410MB  20.0MB/s  00:30"),
            Some(42)
        );
        assert_eq!(transfer_progress("ordinary diagnostic"), None);
    }

    #[test]
    fn known_read_commands_do_not_require_confirmation() {
        assert!(!requires_confirmation(
            "kubectl",
            &[
                "--context".into(),
                "prod".into(),
                "get".into(),
                "pods".into()
            ]
        ));
        assert!(!requires_confirmation(
            "aws",
            &["ec2".into(), "describe-instances".into()]
        ));
    }

    #[test]
    fn mutations_and_unknown_commands_require_confirmation() {
        assert!(requires_confirmation(
            "kubectl",
            &["delete".into(), "pod".into(), "api".into()]
        ));
        assert!(requires_confirmation(
            "aws",
            &["ec2".into(), "terminate-instances".into()]
        ));
        assert!(requires_confirmation("docker", &["plugin".into()]));
    }

    #[test]
    fn local_control_characters_are_rejected() {
        assert!(validate_arguments(&["get".into(), "pods\nrm".into()]).is_err());
    }

    #[test]
    fn ssh_host_adapter_rejects_local_option_injection() {
        let valid = vec![
            "-o".into(),
            "BatchMode=yes".into(),
            "-o".into(),
            "ConnectTimeout=10".into(),
            "-o".into(),
            "ConnectionAttempts=1".into(),
            "prod-api".into(),
            "uptime".into(),
        ];
        assert!(validate_adapter_arguments("ssh-host", &valid).is_ok());

        let mut injected = valid.clone();
        injected[6] = "-oProxyCommand=touch /tmp/bad".into();
        assert!(validate_adapter_arguments("ssh-host", &injected).is_err());
    }

    #[test]
    fn ssh_host_mutations_require_confirmation() {
        let read = vec![
            "-o".into(),
            "BatchMode=yes".into(),
            "-o".into(),
            "ConnectTimeout=10".into(),
            "-o".into(),
            "ConnectionAttempts=1".into(),
            "prod-api".into(),
            SSH_PROCESS_LIST_COMMAND.into(),
        ];
        assert!(!requires_confirmation("ssh-host", &read));
        let mut mutation = read;
        mutation[7] = "systemctl restart api.service".into();
        assert!(requires_confirmation("ssh-host", &mutation));
    }

    #[test]
    fn ssh_read_allowlist_rejects_remote_shell_suffixes() {
        let mut arguments = vec![
            "-o".into(),
            "BatchMode=yes".into(),
            "-o".into(),
            "ConnectTimeout=10".into(),
            "-o".into(),
            "ConnectionAttempts=1".into(),
            "prod-api".into(),
            "ps -axo pid=,ppid=,user=,%cpu=,%mem=,etime=,comm=,args=; rm -rf /tmp/example".into(),
        ];
        assert!(requires_confirmation("ssh-host", &arguments));

        arguments[7] = "journalctl --no-pager -n 300 -u nginx.service; reboot".into();
        assert!(requires_confirmation("ssh-host", &arguments));

        arguments[7] = "tail -n 200 -F -- '/var/log/app.log'".into();
        assert!(!requires_confirmation("ssh-host", &arguments));
    }

    #[test]
    fn sftp_adapter_is_structured_and_never_accepts_local_shell_commands() {
        assert!(
            validate_sftp_arguments(&["prod-api".into(), "list".into(), "/var/log".into()]).is_ok()
        );
        assert!(
            validate_sftp_arguments(&["prod-api".into(), "!touch".into(), "/tmp/bad".into()])
                .is_err()
        );
        assert_eq!(
            sftp_quote("/srv/a \"quoted\" file"),
            "\"/srv/a \\\"quoted\\\" file\""
        );
    }
}
