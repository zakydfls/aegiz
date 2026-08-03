use aegiz_domain::Host;
use anyhow::{Context, Result};
use chrono::Utc;
use std::path::Path;
use uuid::Uuid;

#[derive(Clone, Debug, Default)]
struct Block {
    aliases: Vec<String>,
    hostname: Option<String>,
    user: Option<String>,
    port: Option<u16>,
    proxy_jump: Option<String>,
    identity_file: Option<String>,
}

pub async fn parse_file(path: &Path) -> Result<(Vec<Host>, Vec<String>, u32)> {
    let contents = tokio::fs::read_to_string(path)
        .await
        .with_context(|| format!("could not read {}", path.display()))?;
    Ok(parse(&contents, &path.to_string_lossy()))
}

pub fn parse(contents: &str, source: &str) -> (Vec<Host>, Vec<String>, u32) {
    let mut blocks = Vec::new();
    let mut current: Option<Block> = None;
    let mut warnings = Vec::new();

    for (index, raw_line) in contents.lines().enumerate() {
        let line = strip_comment(raw_line).trim();
        if line.is_empty() {
            continue;
        }

        let (key, value) = match line.split_once(char::is_whitespace) {
            Some((key, value)) => (key.to_ascii_lowercase(), value.trim()),
            None => {
                warnings.push(format!("line {} has no value and was ignored", index + 1));
                continue;
            }
        };

        if key == "host" {
            if let Some(block) = current.take() {
                blocks.push(block);
            }
            current = Some(Block {
                aliases: split_values(value),
                ..Default::default()
            });
            continue;
        }

        let Some(block) = current.as_mut() else {
            continue;
        };

        match key.as_str() {
            "hostname" if block.hostname.is_none() => block.hostname = first_value(value),
            "user" if block.user.is_none() => block.user = first_value(value),
            "port" if block.port.is_none() => {
                block.port = first_value(value).and_then(|port| port.parse().ok())
            }
            "proxyjump" if block.proxy_jump.is_none() => block.proxy_jump = first_value(value),
            "identityfile" if block.identity_file.is_none() => {
                block.identity_file = first_value(value)
            }
            _ => {}
        }
    }
    if let Some(block) = current {
        blocks.push(block);
    }

    let now = Utc::now();
    let mut hosts = Vec::new();
    let mut skipped = 0;
    for block in blocks {
        for alias in &block.aliases {
            if alias.contains('*') || alias.contains('?') || alias.starts_with('!') {
                skipped += 1;
                continue;
            }
            let stable_key = format!("{source}\0{alias}");
            hosts.push(Host {
                id: Uuid::new_v5(&Uuid::NAMESPACE_URL, stable_key.as_bytes()),
                alias: alias.clone(),
                hostname: block.hostname.clone().unwrap_or_else(|| alias.clone()),
                user: block.user.clone(),
                port: block.port.unwrap_or(22),
                proxy_jump: block.proxy_jump.clone(),
                identity_hint: block
                    .identity_file
                    .as_ref()
                    .and_then(|path| Path::new(path).file_name())
                    .map(|name| name.to_string_lossy().into_owned()),
                source: source.to_owned(),
                tags: Vec::new(),
                created_at: now,
                updated_at: now,
            });
        }
    }
    (hosts, warnings, skipped)
}

fn first_value(value: &str) -> Option<String> {
    split_values(value).into_iter().next()
}

fn split_values(value: &str) -> Vec<String> {
    value
        .split_whitespace()
        .map(|item| item.trim_matches(['"', '\'']).to_owned())
        .collect()
}

fn strip_comment(line: &str) -> &str {
    let mut single_quote = false;
    let mut double_quote = false;
    for (index, character) in line.char_indices() {
        match character {
            '\'' if !double_quote => single_quote = !single_quote,
            '"' if !single_quote => double_quote = !double_quote,
            '#' if !single_quote && !double_quote => return &line[..index],
            _ => {}
        }
    }
    line
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn imports_explicit_hosts_without_private_key_paths() {
        let config = r#"
            Host *
              ServerAliveInterval 30

            Host prod-api prod-worker
              HostName 10.20.30.40
              User deploy
              Port 2202
              ProxyJump bastion
              IdentityFile ~/.ssh/company_prod

            Host *.internal
              User root
        "#;

        let (hosts, warnings, skipped) = parse(config, "/tmp/config");
        assert!(warnings.is_empty());
        assert_eq!(skipped, 2);
        assert_eq!(hosts.len(), 2);
        assert_eq!(hosts[0].alias, "prod-api");
        assert_eq!(hosts[0].port, 2202);
        assert_eq!(hosts[0].identity_hint.as_deref(), Some("company_prod"));
        assert!(!hosts[0].identity_hint.as_deref().unwrap().contains("/"));
    }

    #[test]
    fn comments_inside_quotes_are_preserved() {
        assert_eq!(
            strip_comment(r#"HostName "host#1" # note"#).trim(),
            r#"HostName "host#1""#
        );
    }
}
