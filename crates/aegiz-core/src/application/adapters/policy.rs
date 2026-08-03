//! Security policy for external tool invocations.
//!
//! This module is deliberately pure: it does not launch processes, access the
//! database, or know about RPC. Keeping mutation classification and output
//! redaction here makes the policy independently reviewable and reusable by
//! every adapter execution path.

use regex::Regex;
use std::sync::LazyLock;

/// Returns whether an invocation needs an explicit user confirmation.
///
/// The safe default is `true`: unknown commands and malformed argument lists
/// are treated as mutations until a read-only rule proves otherwise.
pub fn requires_confirmation(adapter_id: &str, arguments: &[String]) -> bool {
    match adapter_id {
        "sftp" => arguments.get(1).is_none_or(|operation| operation != "list"),
        "ssh-host" => {
            let Some(command) = arguments.get(7).map(|value| value.trim_start()) else {
                return true;
            };
            !is_known_read_only_ssh_command(command)
        }
        "docker" => docker_requires_confirmation(arguments),
        "kubectl" => classify_by_verbs(
            arguments,
            &[
                "annotate",
                "apply",
                "attach",
                "autoscale",
                "certificate",
                "cordon",
                "cp",
                "create",
                "delete",
                "drain",
                "edit",
                "exec",
                "expose",
                "label",
                "patch",
                "port-forward",
                "replace",
                "rollout",
                "run",
                "scale",
                "set",
                "taint",
                "uncordon",
            ],
            &[
                "api-resources",
                "api-versions",
                "auth",
                "cluster-info",
                "config",
                "describe",
                "diff",
                "explain",
                "get",
                "help",
                "logs",
                "options",
                "top",
                "version",
                "wait",
            ],
        ),
        "aws" => aws_requires_confirmation(arguments),
        "terraform" => classify_by_verbs(
            arguments,
            &[
                "apply",
                "destroy",
                "force-unlock",
                "import",
                "login",
                "logout",
                "refresh",
                "state",
                "taint",
                "untaint",
                "workspace",
            ],
            &[
                "console",
                "fmt",
                "get",
                "graph",
                "help",
                "output",
                "plan",
                "providers",
                "show",
                "validate",
                "version",
            ],
        ),
        "ansible" | "ansible-playbook" => {
            !arguments.iter().any(|argument| argument == "--check")
                && !arguments
                    .iter()
                    .any(|argument| argument == "--help" || argument == "--version")
        }
        "ansible-inventory" => false,
        _ => true,
    }
}

fn docker_requires_confirmation(arguments: &[String]) -> bool {
    const OPTIONS_WITH_VALUE: &[&str] = &[
        "--config",
        "--context",
        "--connection",
        "-c",
        "--host",
        "-H",
        "--log-level",
    ];
    let mut positionals = Vec::new();
    let mut skip_next = false;
    for argument in arguments {
        if skip_next {
            skip_next = false;
        } else if OPTIONS_WITH_VALUE.contains(&argument.as_str()) {
            skip_next = true;
        } else if !argument.starts_with('-') {
            positionals.push(argument.as_str());
        }
    }
    let Some(command) = positionals.first() else {
        return false;
    };
    if *command == "compose" {
        return !positionals.get(1).is_some_and(|subcommand| {
            [
                "config", "events", "images", "logs", "ls", "port", "ps", "top", "version", "wait",
            ]
            .contains(subcommand)
        });
    }
    if *command == "context" {
        return !positionals
            .get(1)
            .is_some_and(|subcommand| ["inspect", "ls", "show"].contains(subcommand));
    }
    ![
        "events", "help", "history", "images", "info", "inspect", "logs", "ps", "stats", "system",
        "top", "version",
    ]
    .contains(command)
}

const SSH_PROCESS_LIST_COMMAND: &str = "ps -axo pid=,ppid=,user=,%cpu=,%mem=,etime=,comm=,args=";
const SSH_SERVICE_LIST_COMMAND: &str =
    "systemctl list-units --type=service --state=running --no-pager --no-legend";
const SSH_FACTS_COMMAND: &str = r#"printf 'OS: '; (grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"' || uname -s); printf 'Kernel: '; uname -sr; printf 'Uptime: '; uptime; printf '\nFilesystems:\n'; df -hP; printf '\nMemory:\n'; (free -h 2>/dev/null || vm_stat 2>/dev/null || true); printf '\nAddresses:\n'; (hostname -I 2>/dev/null || ifconfig 2>/dev/null | awk '/inet / {print $2}')"#;

fn is_known_read_only_ssh_command(raw_command: &str) -> bool {
    let command = raw_command.trim();
    if [
        "true",
        "uptime",
        SSH_PROCESS_LIST_COMMAND,
        SSH_SERVICE_LIST_COMMAND,
        SSH_FACTS_COMMAND,
        "journalctl --no-pager -n 300",
        "journalctl --no-pager -f -n 200",
    ]
    .contains(&command)
    {
        return true;
    }

    for prefix in [
        "journalctl --no-pager -n 300 -u ",
        "journalctl --no-pager -f -n 200 -u ",
    ] {
        if let Some(unit) = command.strip_prefix(prefix) {
            return is_safe_systemd_unit(unit);
        }
    }

    let Some(path) = command
        .strip_prefix("tail -n 200 -F -- '")
        .and_then(|value| value.strip_suffix('\''))
    else {
        return false;
    };
    path.starts_with('/')
        && !path.is_empty()
        && !path
            .chars()
            .any(|character| matches!(character, '\'' | '\0' | '\n' | '\r'))
        && path.len() <= 4096
}

fn is_safe_systemd_unit(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 200
        && value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'@' | b'_' | b'.' | b':' | b'-')
        })
}

fn classify_by_verbs(arguments: &[String], mutations: &[&str], reads: &[&str]) -> bool {
    if arguments
        .iter()
        .any(|argument| mutations.contains(&argument.as_str()))
    {
        return true;
    }
    !arguments
        .iter()
        .any(|argument| reads.contains(&argument.as_str()))
}

fn aws_requires_confirmation(arguments: &[String]) -> bool {
    const GLOBAL_OPTIONS_WITH_VALUE: &[&str] = &[
        "--ca-bundle",
        "--cli-connect-timeout",
        "--cli-read-timeout",
        "--color",
        "--endpoint-url",
        "--output",
        "--profile",
        "--query",
        "--region",
    ];
    let mut positional = Vec::new();
    let mut skip_next = false;
    for argument in arguments {
        if skip_next {
            skip_next = false;
            continue;
        }
        if GLOBAL_OPTIONS_WITH_VALUE.contains(&argument.as_str()) {
            skip_next = true;
            continue;
        }
        if argument.starts_with('-') {
            continue;
        }
        positional.push(argument.as_str());
    }
    let Some(operation) = positional.get(1) else {
        return false;
    };
    ![
        "batch-get",
        "describe",
        "filter",
        "get",
        "head",
        "list",
        "lookup",
        "search",
        "select",
        "simulate",
        "tail",
    ]
    .iter()
    .any(|prefix| operation == prefix || operation.starts_with(&format!("{prefix}-")))
}

static SECRET_ASSIGNMENT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?i)\b(password|passwd|token|secret|access[_-]?key|authorization)\s*[:=]\s*([^\s,;]+)",
    )
    .expect("valid secret assignment regex")
});
static BEARER_TOKEN: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\bbearer\s+[a-z0-9._~+/\-=]+").expect("valid bearer token regex")
});
static AWS_ACCESS_KEY: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b").expect("valid AWS key regex"));
static URL_CREDENTIAL: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)([a-z][a-z0-9+.-]*://[^:/\s]+:)[^@\s]+@").expect("valid URL credential regex")
});

/// Removes values that must never reach the operation stream or audit log.
pub fn redact(value: &str) -> String {
    let value = SECRET_ASSIGNMENT.replace_all(value, "$1=[REDACTED]");
    let value = BEARER_TOKEN.replace_all(&value, "Bearer [REDACTED]");
    let value = AWS_ACCESS_KEY.replace_all(&value, "[REDACTED_AWS_ACCESS_KEY]");
    URL_CREDENTIAL
        .replace_all(&value, "$1[REDACTED]@")
        .into_owned()
}
