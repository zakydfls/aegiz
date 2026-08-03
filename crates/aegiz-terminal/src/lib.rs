#![forbid(unsafe_code)]

use portable_pty::{ChildKiller, CommandBuilder, MasterPty, NativePtySystem, PtySize, PtySystem};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{Arc, Mutex, Weak},
};
use thiserror::Error;
use uuid::Uuid;

const MIN_COLUMNS: u16 = 2;
const MAX_COLUMNS: u16 = 500;
const MIN_ROWS: u16 = 2;
const MAX_ROWS: u16 = 300;
const MAX_INPUT_BYTES: usize = 64 * 1024;
const OUTPUT_CHUNK_BYTES: usize = 16 * 1024;

pub type OutputHandler = Arc<dyn Fn(Vec<u8>) + Send + Sync + 'static>;
pub type ExitHandler = Arc<dyn Fn(TerminalExit) + Send + Sync + 'static>;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum TerminalLaunch {
    LocalShell { working_directory: Option<PathBuf> },
    Ssh { host_alias: String },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalOpenRequest {
    pub launch: TerminalLaunch,
    pub columns: u16,
    pub rows: u16,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalDescriptor {
    pub id: String,
    pub process_id: Option<u32>,
    pub title: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalExit {
    pub session_id: String,
    pub exit_code: u32,
    pub signal: Option<String>,
}

#[derive(Debug, Error)]
pub enum TerminalError {
    #[error("terminal dimensions must be within 2-500 columns and 2-300 rows")]
    InvalidDimensions,
    #[error("terminal input exceeds the 64 KiB message limit")]
    InputTooLarge,
    #[error("SSH host alias is invalid")]
    InvalidHostAlias,
    #[error("terminal working directory must be an existing absolute directory")]
    InvalidWorkingDirectory,
    #[error("trusted OpenSSH executable is unavailable")]
    OpenSshUnavailable,
    #[error("terminal session was not found")]
    SessionNotFound,
    #[error("terminal session state is unavailable")]
    StateUnavailable,
    #[error("PTY operation failed")]
    Pty,
    #[error("terminal I/O failed")]
    Io,
}

#[derive(Clone)]
pub struct TerminalManager {
    inner: Arc<ManagerInner>,
}

struct ManagerInner {
    sessions: Mutex<HashMap<String, Arc<TerminalSession>>>,
}

struct TerminalSession {
    master: Mutex<Box<dyn MasterPty + Send>>,
    writer: Mutex<Box<dyn Write + Send>>,
    killer: Mutex<Box<dyn ChildKiller + Send + Sync>>,
}

impl Default for TerminalManager {
    fn default() -> Self {
        Self {
            inner: Arc::new(ManagerInner {
                sessions: Mutex::new(HashMap::new()),
            }),
        }
    }
}

impl TerminalManager {
    pub fn open(
        &self,
        request: TerminalOpenRequest,
        on_output: OutputHandler,
        on_exit: ExitHandler,
    ) -> Result<TerminalDescriptor, TerminalError> {
        validate_dimensions(request.columns, request.rows)?;
        let (command, title) = command_for_launch(&request.launch)?;
        self.open_command(
            command,
            title,
            request.columns,
            request.rows,
            on_output,
            on_exit,
        )
    }

    pub fn write(&self, session_id: &str, input: &[u8]) -> Result<(), TerminalError> {
        if input.len() > MAX_INPUT_BYTES {
            return Err(TerminalError::InputTooLarge);
        }
        let session = self.session(session_id)?;
        let mut writer = session
            .writer
            .lock()
            .map_err(|_| TerminalError::StateUnavailable)?;
        writer.write_all(input).map_err(|_| TerminalError::Io)?;
        writer.flush().map_err(|_| TerminalError::Io)
    }

    pub fn resize(&self, session_id: &str, columns: u16, rows: u16) -> Result<(), TerminalError> {
        validate_dimensions(columns, rows)?;
        self.session(session_id)?
            .master
            .lock()
            .map_err(|_| TerminalError::StateUnavailable)?
            .resize(PtySize {
                rows,
                cols: columns,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|_| TerminalError::Pty)
    }

    pub fn close(&self, session_id: &str) -> Result<(), TerminalError> {
        let session = self
            .inner
            .sessions
            .lock()
            .map_err(|_| TerminalError::StateUnavailable)?
            .remove(session_id)
            .ok_or(TerminalError::SessionNotFound)?;
        let result = session
            .killer
            .lock()
            .map_err(|_| TerminalError::StateUnavailable)?
            .kill();
        result.map_err(|_| TerminalError::Io)
    }

    pub fn active_session_count(&self) -> Result<usize, TerminalError> {
        self.inner
            .sessions
            .lock()
            .map(|sessions| sessions.len())
            .map_err(|_| TerminalError::StateUnavailable)
    }

    fn session(&self, session_id: &str) -> Result<Arc<TerminalSession>, TerminalError> {
        self.inner
            .sessions
            .lock()
            .map_err(|_| TerminalError::StateUnavailable)?
            .get(session_id)
            .cloned()
            .ok_or(TerminalError::SessionNotFound)
    }

    fn open_command(
        &self,
        mut command: CommandBuilder,
        title: String,
        columns: u16,
        rows: u16,
        on_output: OutputHandler,
        on_exit: ExitHandler,
    ) -> Result<TerminalDescriptor, TerminalError> {
        command.env("TERM", "xterm-256color");
        command.env("COLORTERM", "truecolor");
        let pair = NativePtySystem::default()
            .openpty(PtySize {
                rows,
                cols: columns,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|_| TerminalError::Pty)?;
        let mut child = pair
            .slave
            .spawn_command(command)
            .map_err(|_| TerminalError::Pty)?;
        drop(pair.slave);
        let process_id = child.process_id();
        let mut reader = pair
            .master
            .try_clone_reader()
            .map_err(|_| TerminalError::Pty)?;
        let writer = pair.master.take_writer().map_err(|_| TerminalError::Pty)?;
        let killer = child.clone_killer();
        let id = Uuid::new_v4().simple().to_string();
        let session = Arc::new(TerminalSession {
            master: Mutex::new(pair.master),
            writer: Mutex::new(writer),
            killer: Mutex::new(killer),
        });
        self.inner
            .sessions
            .lock()
            .map_err(|_| TerminalError::StateUnavailable)?
            .insert(id.clone(), session);

        let output_id = id.clone();
        std::thread::Builder::new()
            .name(format!("aegiz-pty-read-{}", &id[..8]))
            .spawn(move || {
                let mut buffer = vec![0_u8; OUTPUT_CHUNK_BYTES];
                loop {
                    match reader.read(&mut buffer) {
                        Ok(0) | Err(_) => break,
                        Ok(count) => on_output(buffer[..count].to_vec()),
                    }
                }
                drop(output_id);
            })
            .map_err(|_| TerminalError::Io)?;

        let weak_inner: Weak<ManagerInner> = Arc::downgrade(&self.inner);
        let exit_id = id.clone();
        std::thread::Builder::new()
            .name(format!("aegiz-pty-wait-{}", &id[..8]))
            .spawn(move || {
                let status = child.wait();
                if let Some(inner) = weak_inner.upgrade()
                    && let Ok(mut sessions) = inner.sessions.lock()
                {
                    sessions.remove(&exit_id);
                }
                let (exit_code, signal) = status
                    .map(|status| (status.exit_code(), status.signal().map(ToOwned::to_owned)))
                    .unwrap_or((1, Some("wait failed".to_owned())));
                on_exit(TerminalExit {
                    session_id: exit_id,
                    exit_code,
                    signal,
                });
            })
            .map_err(|_| TerminalError::Io)?;

        Ok(TerminalDescriptor {
            id,
            process_id,
            title,
        })
    }
}

impl Drop for ManagerInner {
    fn drop(&mut self) {
        if let Ok(mut sessions) = self.sessions.lock() {
            for (_, session) in sessions.drain() {
                if let Ok(mut killer) = session.killer.lock() {
                    let _ = killer.kill();
                }
            }
        }
    }
}

fn validate_dimensions(columns: u16, rows: u16) -> Result<(), TerminalError> {
    if !(MIN_COLUMNS..=MAX_COLUMNS).contains(&columns) || !(MIN_ROWS..=MAX_ROWS).contains(&rows) {
        return Err(TerminalError::InvalidDimensions);
    }
    Ok(())
}

fn command_for_launch(launch: &TerminalLaunch) -> Result<(CommandBuilder, String), TerminalError> {
    match launch {
        TerminalLaunch::LocalShell { working_directory } => {
            let mut command = CommandBuilder::new_default_prog();
            if let Some(directory) = working_directory {
                validate_working_directory(directory)?;
                command.cwd(directory);
            }
            Ok((command, "Local shell".to_owned()))
        }
        TerminalLaunch::Ssh { host_alias } => {
            validate_host_alias(host_alias)?;
            let executable = trusted_ssh_executable().ok_or(TerminalError::OpenSshUnavailable)?;
            let mut command = CommandBuilder::new(executable);
            command.args([
                "-oConnectTimeout=15",
                "-oServerAliveInterval=30",
                "-oServerAliveCountMax=3",
                "-oConnectionAttempts=1",
                "--",
                host_alias,
            ]);
            Ok((command, host_alias.clone()))
        }
    }
}

fn validate_working_directory(path: &Path) -> Result<(), TerminalError> {
    if !path.is_absolute() || !path.is_dir() {
        return Err(TerminalError::InvalidWorkingDirectory);
    }
    Ok(())
}

fn validate_host_alias(alias: &str) -> Result<(), TerminalError> {
    if alias.is_empty()
        || alias.len() > 255
        || alias.starts_with('-')
        || !alias
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        return Err(TerminalError::InvalidHostAlias);
    }
    Ok(())
}

#[cfg(unix)]
fn trusted_ssh_executable() -> Option<PathBuf> {
    [
        "/usr/bin/ssh",
        "/opt/homebrew/bin/ssh",
        "/usr/local/bin/ssh",
    ]
    .into_iter()
    .map(PathBuf::from)
    .find(|path| path.is_file())
}

#[cfg(windows)]
fn trusted_ssh_executable() -> Option<PathBuf> {
    [r"C:\Windows\System32\OpenSSH\ssh.exe"]
        .into_iter()
        .map(PathBuf::from)
        .find(|path| path.is_file())
}

#[cfg(not(any(unix, windows)))]
fn trusted_ssh_executable() -> Option<PathBuf> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        sync::{Condvar, Mutex},
        time::{Duration, Instant},
    };

    #[test]
    fn launch_validation_rejects_option_and_directory_injection() {
        assert!(matches!(
            command_for_launch(&TerminalLaunch::Ssh {
                host_alias: "-oProxyCommand=bad".into()
            }),
            Err(TerminalError::InvalidHostAlias)
        ));
        assert!(matches!(
            command_for_launch(&TerminalLaunch::LocalShell {
                working_directory: Some(PathBuf::from("relative"))
            }),
            Err(TerminalError::InvalidWorkingDirectory)
        ));
        assert!(validate_dimensions(1, 24).is_err());
        assert!(validate_dimensions(80, 24).is_ok());
    }

    #[cfg(unix)]
    #[test]
    fn native_pty_streams_output_and_reconciles_the_session() {
        let manager = TerminalManager::default();
        let output = Arc::new((Mutex::new(Vec::<u8>::new()), Condvar::new()));
        let output_copy = output.clone();
        let exit = Arc::new((Mutex::new(None::<TerminalExit>), Condvar::new()));
        let exit_copy = exit.clone();
        let descriptor = manager
            .open_command(
                {
                    let mut command = CommandBuilder::new("/usr/bin/printf");
                    command.arg("aegiz-pty-ok");
                    command
                },
                "Fixture".into(),
                80,
                24,
                Arc::new(move |chunk| {
                    let (bytes, ready) = &*output_copy;
                    bytes.lock().unwrap().extend(chunk);
                    ready.notify_all();
                }),
                Arc::new(move |status| {
                    let (value, ready) = &*exit_copy;
                    *value.lock().unwrap() = Some(status);
                    ready.notify_all();
                }),
            )
            .unwrap();

        let deadline = Instant::now() + Duration::from_secs(3);
        let (exit_value, exit_ready) = &*exit;
        let mut status = exit_value.lock().unwrap();
        while status.is_none() && Instant::now() < deadline {
            status = exit_ready
                .wait_timeout(status, Duration::from_millis(50))
                .unwrap()
                .0;
        }
        assert_eq!(status.as_ref().unwrap().session_id, descriptor.id);
        assert_eq!(status.as_ref().unwrap().exit_code, 0);

        let output_deadline = Instant::now() + Duration::from_secs(1);
        let (bytes, ready) = &*output;
        let mut bytes = bytes.lock().unwrap();
        while !bytes
            .windows(b"aegiz-pty-ok".len())
            .any(|window| window == b"aegiz-pty-ok")
            && Instant::now() < output_deadline
        {
            bytes = ready
                .wait_timeout(bytes, Duration::from_millis(20))
                .unwrap()
                .0;
        }
        assert!(bytes.windows(12).any(|window| window == b"aegiz-pty-ok"));
        assert_eq!(manager.active_session_count().unwrap(), 0);
    }
}
