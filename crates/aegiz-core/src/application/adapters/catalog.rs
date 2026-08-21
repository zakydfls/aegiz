//! Trusted executable discovery and capability metadata.
//!
//! Discovery is separate from execution so a capability refresh cannot inherit
//! process-launch policy or mutable operation state.

use super::redact;
use std::{
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};
use tokio::process::Command;

pub(super) struct ToolSpec {
    pub(super) id: &'static str,
    pub(super) label: &'static str,
    pub(super) candidates: &'static [&'static str],
    pub(super) version_arguments: &'static [&'static str],
    pub(super) runnable: bool,
}

pub(super) const TOOLS: &[ToolSpec] = &[
    ToolSpec {
        id: "openssh",
        label: "OpenSSH",
        candidates: &["/usr/bin/ssh"],
        version_arguments: &["-V"],
        runnable: false,
    },
    ToolSpec {
        id: "ssh-host",
        label: "SSH Host Operations",
        candidates: &["/usr/bin/ssh"],
        version_arguments: &["-V"],
        runnable: true,
    },
    ToolSpec {
        id: "sftp",
        label: "OpenSSH SFTP",
        candidates: &["/usr/bin/sftp"],
        version_arguments: &["-V"],
        runnable: true,
    },
    ToolSpec {
        id: "ghostty",
        label: "Ghostty",
        candidates: &[
            "/Applications/Ghostty.app/Contents/MacOS/ghostty",
            "/opt/homebrew/bin/ghostty",
            "/usr/local/bin/ghostty",
        ],
        version_arguments: &["--version"],
        runnable: false,
    },
    ToolSpec {
        id: "docker",
        label: "Docker / Podman",
        candidates: &[
            "/opt/homebrew/bin/docker",
            "/usr/local/bin/docker",
            "/usr/bin/docker",
            "/opt/podman/bin/podman",
            "/opt/homebrew/bin/podman",
            "/usr/local/bin/podman",
            "/usr/bin/podman",
        ],
        version_arguments: &["--version"],
        runnable: true,
    },
    ToolSpec {
        id: "kubectl",
        label: "kubectl",
        candidates: &[
            "/opt/homebrew/bin/kubectl",
            "/usr/local/bin/kubectl",
            "/usr/bin/kubectl",
        ],
        version_arguments: &["version", "--client"],
        runnable: true,
    },
    ToolSpec {
        id: "aws",
        label: "AWS CLI",
        candidates: &[
            "/opt/homebrew/bin/aws",
            "/usr/local/bin/aws",
            "/usr/bin/aws",
        ],
        version_arguments: &["--version"],
        runnable: true,
    },
    ToolSpec {
        id: "terraform",
        label: "Terraform",
        candidates: &[
            "/opt/homebrew/bin/terraform",
            "/usr/local/bin/terraform",
            "/usr/bin/terraform",
        ],
        version_arguments: &["version"],
        runnable: true,
    },
    ToolSpec {
        id: "ansible",
        label: "Ansible",
        candidates: &[
            "/opt/homebrew/bin/ansible",
            "/usr/local/bin/ansible",
            "/usr/bin/ansible",
        ],
        version_arguments: &["--version"],
        runnable: true,
    },
    ToolSpec {
        id: "ansible-playbook",
        label: "Ansible Playbook",
        candidates: &[
            "/opt/homebrew/bin/ansible-playbook",
            "/usr/local/bin/ansible-playbook",
            "/usr/bin/ansible-playbook",
        ],
        version_arguments: &["--version"],
        runnable: true,
    },
    ToolSpec {
        id: "ansible-inventory",
        label: "Ansible Inventory",
        candidates: &[
            "/opt/homebrew/bin/ansible-inventory",
            "/usr/local/bin/ansible-inventory",
            "/usr/bin/ansible-inventory",
        ],
        version_arguments: &["--version"],
        runnable: true,
    },
];

pub(super) fn tool_spec(id: &str) -> Option<&'static ToolSpec> {
    TOOLS.iter().find(|spec| spec.id == id)
}

pub(super) fn resolve_executable(spec: &ToolSpec) -> Option<PathBuf> {
    spec.candidates
        .iter()
        .map(PathBuf::from)
        .find(|path| is_executable(path))
}

pub(super) async fn detect_version(spec: &ToolSpec, path: &Path) -> (String, String) {
    let mut command = Command::new(path);
    command
        .args(spec.version_arguments)
        .stdin(Stdio::null())
        .kill_on_drop(true);
    match tokio::time::timeout(Duration::from_secs(3), command.output()).await {
        Ok(Ok(output)) => {
            let text = if output.stdout.is_empty() {
                String::from_utf8_lossy(&output.stderr)
            } else {
                String::from_utf8_lossy(&output.stdout)
            };
            let version = redact(text.trim())
                .lines()
                .next()
                .unwrap_or_default()
                .chars()
                .take(240)
                .collect::<String>();
            if output.status.success() || !version.is_empty() {
                (version, String::new())
            } else {
                (
                    String::new(),
                    format!("Version check exited with {}", output.status),
                )
            }
        }
        Ok(Err(error)) => (String::new(), format!("Version check failed: {error}")),
        Err(_) => (String::new(), "Version check timed out".into()),
    }
}

pub(super) fn is_executable(path: &Path) -> bool {
    is_executable_impl(path)
}

#[cfg(unix)]
fn is_executable_impl(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;

    path.metadata()
        .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}

#[cfg(not(unix))]
fn is_executable_impl(path: &Path) -> bool {
    path.is_file()
}
