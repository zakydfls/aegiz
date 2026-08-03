use aegiz_domain::{
    AuditEvent, Dashboard, DatabaseEngine, DatabaseProfile, Host, ImportReport, Tunnel, TunnelKind,
    TunnelStatus,
};
use anyhow::{Context, Result, anyhow};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sqlx::{Row, SqlitePool, sqlite::SqliteConnectOptions};
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::{
    path::{Path, PathBuf},
    str::FromStr,
};
use uuid::Uuid;

#[derive(Clone)]
pub struct Store {
    pool: SqlitePool,
}

const BACKUP_SCHEMA_VERSION: u32 = 1;
const MAX_BACKUP_RECORDS_PER_TABLE: usize = 100_000;

#[derive(Clone, Debug, Serialize, Deserialize)]
struct BackupSnapshot {
    schema_version: u32,
    created_at: DateTime<Utc>,
    hosts: Vec<Host>,
    tunnels: Vec<Tunnel>,
    database_profiles: Vec<DatabaseProfile>,
    audit_events: Vec<AuditEvent>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RestoreReport {
    pub hosts: u32,
    pub tunnels: u32,
    pub database_profiles: u32,
    pub audit_events: u32,
}

impl Store {
    pub async fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent() {
            tokio::fs::create_dir_all(parent).await?;
            set_directory_private(parent).await?;
        }
        let options = SqliteConnectOptions::from_str(&format!("sqlite://{}", path.display()))?
            .create_if_missing(true)
            .foreign_keys(true)
            .journal_mode(sqlx::sqlite::SqliteJournalMode::Wal);
        let pool = SqlitePool::connect_with(options).await?;
        let store = Self { pool };
        store.migrate().await?;
        set_sqlite_files_private(path).await?;
        Ok(store)
    }

    pub async fn in_memory() -> Result<Self> {
        let pool = SqlitePool::connect("sqlite::memory:").await?;
        let store = Self { pool };
        store.migrate().await?;
        Ok(store)
    }

    /// Reconcile process-backed states after a previous core instance ended.
    /// The tunnel watchdog guarantees the associated OpenSSH process is gone;
    /// this repairs only the durable inventory state left by a hard exit.
    pub async fn recover_transient_tunnel_statuses(&self) -> Result<u64> {
        let now = Utc::now().to_rfc3339();
        let result = sqlx::query(
            "UPDATE tunnels SET status = 'stopped', last_error = NULL, updated_at = ? \
             WHERE status IN ('starting', 'running', 'stopping')",
        )
        .bind(now)
        .execute(&self.pool)
        .await?;
        let recovered = result.rows_affected();
        if recovered > 0 {
            self.audit(
                "tunnel.recover",
                None,
                "stopped",
                &format!("reconciled {recovered} transient tunnel state(s) after core startup"),
            )
            .await?;
        }
        Ok(recovered)
    }

    async fn migrate(&self) -> Result<()> {
        sqlx::query(
            r#"
            CREATE TABLE IF NOT EXISTS hosts (
                id TEXT PRIMARY KEY NOT NULL,
                alias TEXT NOT NULL,
                hostname TEXT NOT NULL,
                user TEXT,
                port INTEGER NOT NULL,
                proxy_jump TEXT,
                identity_hint TEXT,
                source TEXT NOT NULL,
                tags TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                UNIQUE(source, alias)
            );
            CREATE TABLE IF NOT EXISTS tunnels (
                id TEXT PRIMARY KEY NOT NULL,
                host_id TEXT NOT NULL REFERENCES hosts(id) ON DELETE CASCADE,
                label TEXT NOT NULL,
                kind TEXT NOT NULL,
                bind_address TEXT NOT NULL,
                local_port INTEGER NOT NULL,
                remote_host TEXT NOT NULL,
                remote_port INTEGER NOT NULL,
                status TEXT NOT NULL DEFAULT 'stopped',
                last_error TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS audit_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                occurred_at TEXT NOT NULL,
                action TEXT NOT NULL,
                resource_id TEXT,
                outcome TEXT NOT NULL,
                detail TEXT NOT NULL DEFAULT ''
            );
            CREATE TABLE IF NOT EXISTS vault_items (
                id TEXT PRIMARY KEY NOT NULL,
                context TEXT NOT NULL UNIQUE,
                encrypted_blob BLOB NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS database_profiles (
                id TEXT PRIMARY KEY NOT NULL,
                label TEXT NOT NULL,
                engine TEXT NOT NULL,
                hostname TEXT NOT NULL,
                port INTEGER NOT NULL,
                database_name TEXT NOT NULL,
                username TEXT NOT NULL,
                secret_reference TEXT,
                tunnel_id TEXT REFERENCES tunnels(id) ON DELETE SET NULL,
                auto_start_tunnel INTEGER NOT NULL DEFAULT 0,
                read_only INTEGER NOT NULL DEFAULT 1,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            "#,
        )
        .execute(&self.pool)
        .await?;
        // SQLite has no `ADD COLUMN IF NOT EXISTS`, so inspect the table
        // instead of suppressing migration errors.
        let database_columns = sqlx::query("PRAGMA table_info(database_profiles)")
            .fetch_all(&self.pool)
            .await?;
        if !database_columns.iter().any(|row| {
            row.try_get::<String, _>("name")
                .is_ok_and(|name| name == "auto_start_tunnel")
        }) {
            sqlx::query(
                "ALTER TABLE database_profiles ADD COLUMN auto_start_tunnel INTEGER NOT NULL DEFAULT 0",
            )
            .execute(&self.pool)
            .await?;
        }
        Ok(())
    }

    pub async fn upsert_hosts(&self, hosts: &[Host]) -> Result<ImportReport> {
        let mut tx = self.pool.begin().await?;
        let mut report = ImportReport::default();

        for host in hosts {
            let exists: bool = sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM hosts WHERE source = ? AND alias = ?)",
            )
            .bind(&host.source)
            .bind(&host.alias)
            .fetch_one(&mut *tx)
            .await?;

            sqlx::query(
                r#"
                INSERT INTO hosts (
                    id, alias, hostname, user, port, proxy_jump, identity_hint,
                    source, tags, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source, alias) DO UPDATE SET
                    hostname = excluded.hostname,
                    user = excluded.user,
                    port = excluded.port,
                    proxy_jump = excluded.proxy_jump,
                    identity_hint = excluded.identity_hint,
                    tags = excluded.tags,
                    updated_at = excluded.updated_at
                "#,
            )
            .bind(host.id.to_string())
            .bind(&host.alias)
            .bind(&host.hostname)
            .bind(&host.user)
            .bind(i64::from(host.port))
            .bind(&host.proxy_jump)
            .bind(&host.identity_hint)
            .bind(&host.source)
            .bind(host.tags.join(","))
            .bind(host.created_at.to_rfc3339())
            .bind(host.updated_at.to_rfc3339())
            .execute(&mut *tx)
            .await?;

            if exists {
                report.updated += 1;
            } else {
                report.imported += 1;
            }
        }
        tx.commit().await?;
        Ok(report)
    }

    pub async fn list_hosts(&self, query: &str) -> Result<Vec<Host>> {
        let pattern = format!("%{}%", query.trim());
        let rows = sqlx::query(
            r#"
            SELECT * FROM hosts
            WHERE ? = '%%'
               OR alias LIKE ? COLLATE NOCASE
               OR hostname LIKE ? COLLATE NOCASE
               OR tags LIKE ? COLLATE NOCASE
            ORDER BY alias COLLATE NOCASE
            "#,
        )
        .bind(&pattern)
        .bind(&pattern)
        .bind(&pattern)
        .bind(&pattern)
        .fetch_all(&self.pool)
        .await?;
        rows.iter().map(row_to_host).collect()
    }

    pub async fn get_host(&self, id: Uuid) -> Result<Host> {
        let row = sqlx::query("SELECT * FROM hosts WHERE id = ?")
            .bind(id.to_string())
            .fetch_optional(&self.pool)
            .await?
            .ok_or_else(|| anyhow!("host not found"))?;
        row_to_host(&row)
    }

    pub async fn save_tunnel(&self, tunnel: &Tunnel) -> Result<()> {
        sqlx::query(
            r#"
            INSERT INTO tunnels (
                id, host_id, label, kind, bind_address, local_port, remote_host,
                remote_port, status, last_error, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                host_id = excluded.host_id,
                label = excluded.label,
                kind = excluded.kind,
                bind_address = excluded.bind_address,
                local_port = excluded.local_port,
                remote_host = excluded.remote_host,
                remote_port = excluded.remote_port,
                updated_at = excluded.updated_at
            "#,
        )
        .bind(tunnel.id.to_string())
        .bind(tunnel.host_id.to_string())
        .bind(&tunnel.label)
        .bind(tunnel.kind.as_str())
        .bind(&tunnel.bind_address)
        .bind(i64::from(tunnel.local_port))
        .bind(&tunnel.remote_host)
        .bind(i64::from(tunnel.remote_port))
        .bind(tunnel.status.as_str())
        .bind(&tunnel.last_error)
        .bind(tunnel.created_at.to_rfc3339())
        .bind(tunnel.updated_at.to_rfc3339())
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_tunnels(&self) -> Result<Vec<Tunnel>> {
        let rows = sqlx::query("SELECT * FROM tunnels ORDER BY label COLLATE NOCASE")
            .fetch_all(&self.pool)
            .await?;
        rows.iter().map(row_to_tunnel).collect()
    }

    pub async fn get_tunnel(&self, id: Uuid) -> Result<Tunnel> {
        let row = sqlx::query("SELECT * FROM tunnels WHERE id = ?")
            .bind(id.to_string())
            .fetch_optional(&self.pool)
            .await?
            .ok_or_else(|| anyhow!("tunnel not found"))?;
        row_to_tunnel(&row)
    }

    pub async fn set_tunnel_status(
        &self,
        id: Uuid,
        status: TunnelStatus,
        last_error: Option<&str>,
    ) -> Result<()> {
        sqlx::query("UPDATE tunnels SET status = ?, last_error = ?, updated_at = ? WHERE id = ?")
            .bind(status.as_str())
            .bind(last_error)
            .bind(Utc::now().to_rfc3339())
            .bind(id.to_string())
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn save_database_profile(&self, profile: &DatabaseProfile) -> Result<()> {
        sqlx::query(
            r#"
            INSERT INTO database_profiles (
                id, label, engine, hostname, port, database_name, username,
                secret_reference, tunnel_id, auto_start_tunnel, read_only, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                label = excluded.label,
                engine = excluded.engine,
                hostname = excluded.hostname,
                port = excluded.port,
                database_name = excluded.database_name,
                username = excluded.username,
                secret_reference = excluded.secret_reference,
                tunnel_id = excluded.tunnel_id,
                auto_start_tunnel = excluded.auto_start_tunnel,
                read_only = excluded.read_only,
                updated_at = excluded.updated_at
            "#,
        )
        .bind(profile.id.to_string())
        .bind(&profile.label)
        .bind(profile.engine.as_str())
        .bind(&profile.hostname)
        .bind(i64::from(profile.port))
        .bind(&profile.database_name)
        .bind(&profile.username)
        .bind(&profile.secret_reference)
        .bind(profile.tunnel_id.map(|id| id.to_string()))
        .bind(profile.auto_start_tunnel)
        .bind(profile.read_only)
        .bind(profile.created_at.to_rfc3339())
        .bind(profile.updated_at.to_rfc3339())
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_database_profiles(&self) -> Result<Vec<DatabaseProfile>> {
        let rows = sqlx::query(
            "SELECT id, label, engine, hostname, port, database_name, username, \
             secret_reference, tunnel_id, auto_start_tunnel, read_only, created_at, updated_at \
             FROM database_profiles ORDER BY label COLLATE NOCASE",
        )
        .fetch_all(&self.pool)
        .await?;
        rows.iter().map(row_to_database_profile).collect()
    }

    pub async fn get_database_profile(&self, id: Uuid) -> Result<DatabaseProfile> {
        let row = sqlx::query(
            "SELECT id, label, engine, hostname, port, database_name, username, \
             secret_reference, tunnel_id, auto_start_tunnel, read_only, created_at, updated_at \
             FROM database_profiles WHERE id = ?",
        )
        .bind(id.to_string())
        .fetch_optional(&self.pool)
        .await?
        .ok_or_else(|| anyhow!("database profile not found"))?;
        row_to_database_profile(&row)
    }

    pub async fn delete_database_profile(&self, id: Uuid) -> Result<()> {
        sqlx::query("DELETE FROM database_profiles WHERE id = ?")
            .bind(id.to_string())
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn dashboard(&self) -> Result<Dashboard> {
        let host_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM hosts")
            .fetch_one(&self.pool)
            .await?;
        let tunnel_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM tunnels")
            .fetch_one(&self.pool)
            .await?;
        let active_tunnel_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM tunnels WHERE status = 'running'")
                .fetch_one(&self.pool)
                .await?;
        let attention_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM tunnels WHERE status = 'failed'")
                .fetch_one(&self.pool)
                .await?;
        Ok(Dashboard {
            host_count: host_count as u32,
            tunnel_count: tunnel_count as u32,
            active_tunnel_count: active_tunnel_count as u32,
            attention_count: attention_count as u32,
        })
    }

    pub async fn audit(
        &self,
        action: &str,
        resource_id: Option<Uuid>,
        outcome: &str,
        detail: &str,
    ) -> Result<()> {
        sqlx::query(
            "INSERT INTO audit_log (occurred_at, action, resource_id, outcome, detail) VALUES (?, ?, ?, ?, ?)",
        )
        .bind(Utc::now().to_rfc3339())
        .bind(action)
        .bind(resource_id.map(|id| id.to_string()))
        .bind(outcome)
        .bind(detail)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_audit_events(&self, limit: u32) -> Result<Vec<AuditEvent>> {
        let bounded_limit = limit.clamp(1, 10_000);
        let rows = sqlx::query(
            "SELECT id, occurred_at, action, resource_id, outcome, detail \
             FROM audit_log ORDER BY id DESC LIMIT ?",
        )
        .bind(i64::from(bounded_limit))
        .fetch_all(&self.pool)
        .await?;
        rows.iter()
            .map(|row| {
                Ok(AuditEvent {
                    id: row.try_get("id")?,
                    occurred_at: parse_time(row.try_get("occurred_at")?)?,
                    action: row.try_get("action")?,
                    resource_id: row.try_get("resource_id")?,
                    outcome: row.try_get("outcome")?,
                    detail: row.try_get("detail")?,
                })
            })
            .collect()
    }

    /// Exports a logical, versioned snapshot. It intentionally contains only
    /// inventory metadata and already-redacted audit summaries; credential
    /// values and SSH private keys never enter this payload.
    pub async fn export_backup(&self) -> Result<Vec<u8>> {
        let snapshot = BackupSnapshot {
            schema_version: BACKUP_SCHEMA_VERSION,
            created_at: Utc::now(),
            hosts: self.list_hosts("").await?,
            tunnels: self.list_tunnels().await?,
            database_profiles: self.list_database_profiles().await?,
            audit_events: self.list_all_audit_events().await?,
        };
        serde_json::to_vec(&snapshot).context("could not serialize backup snapshot")
    }

    /// Atomically replaces the logical inventory from a validated snapshot.
    /// Managed tunnel process state is never restored: every tunnel comes back
    /// stopped and must be explicitly started by the user.
    pub async fn restore_backup(&self, payload: &[u8]) -> Result<RestoreReport> {
        let mut snapshot: BackupSnapshot =
            serde_json::from_slice(payload).context("backup payload is not valid JSON")?;
        validate_snapshot(&snapshot)?;
        for tunnel in &mut snapshot.tunnels {
            tunnel.status = TunnelStatus::Stopped;
            tunnel.last_error = None;
            tunnel.updated_at = Utc::now();
        }

        let report = RestoreReport {
            hosts: snapshot.hosts.len() as u32,
            tunnels: snapshot.tunnels.len() as u32,
            database_profiles: snapshot.database_profiles.len() as u32,
            audit_events: snapshot.audit_events.len() as u32,
        };
        let mut tx = self.pool.begin().await?;
        sqlx::query("DELETE FROM database_profiles")
            .execute(&mut *tx)
            .await?;
        sqlx::query("DELETE FROM tunnels").execute(&mut *tx).await?;
        sqlx::query("DELETE FROM hosts").execute(&mut *tx).await?;
        sqlx::query("DELETE FROM audit_log")
            .execute(&mut *tx)
            .await?;

        for host in &snapshot.hosts {
            sqlx::query(
                r#"
                INSERT INTO hosts (
                    id, alias, hostname, user, port, proxy_jump, identity_hint,
                    source, tags, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                "#,
            )
            .bind(host.id.to_string())
            .bind(&host.alias)
            .bind(&host.hostname)
            .bind(&host.user)
            .bind(i64::from(host.port))
            .bind(&host.proxy_jump)
            .bind(&host.identity_hint)
            .bind(&host.source)
            .bind(host.tags.join(","))
            .bind(host.created_at.to_rfc3339())
            .bind(host.updated_at.to_rfc3339())
            .execute(&mut *tx)
            .await?;
        }
        for tunnel in &snapshot.tunnels {
            sqlx::query(
                r#"
                INSERT INTO tunnels (
                    id, host_id, label, kind, bind_address, local_port, remote_host,
                    remote_port, status, last_error, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                "#,
            )
            .bind(tunnel.id.to_string())
            .bind(tunnel.host_id.to_string())
            .bind(&tunnel.label)
            .bind(tunnel.kind.as_str())
            .bind(&tunnel.bind_address)
            .bind(i64::from(tunnel.local_port))
            .bind(&tunnel.remote_host)
            .bind(i64::from(tunnel.remote_port))
            .bind(TunnelStatus::Stopped.as_str())
            .bind(Option::<String>::None)
            .bind(tunnel.created_at.to_rfc3339())
            .bind(tunnel.updated_at.to_rfc3339())
            .execute(&mut *tx)
            .await?;
        }
        for profile in &snapshot.database_profiles {
            sqlx::query(
                r#"
                INSERT INTO database_profiles (
                    id, label, engine, hostname, port, database_name, username,
                    secret_reference, tunnel_id, auto_start_tunnel, read_only,
                    created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                "#,
            )
            .bind(profile.id.to_string())
            .bind(&profile.label)
            .bind(profile.engine.as_str())
            .bind(&profile.hostname)
            .bind(i64::from(profile.port))
            .bind(&profile.database_name)
            .bind(&profile.username)
            .bind(&profile.secret_reference)
            .bind(profile.tunnel_id.map(|id| id.to_string()))
            .bind(profile.auto_start_tunnel)
            .bind(profile.read_only)
            .bind(profile.created_at.to_rfc3339())
            .bind(profile.updated_at.to_rfc3339())
            .execute(&mut *tx)
            .await?;
        }
        for event in &snapshot.audit_events {
            sqlx::query(
                "INSERT INTO audit_log \
                 (id, occurred_at, action, resource_id, outcome, detail) \
                 VALUES (?, ?, ?, ?, ?, ?)",
            )
            .bind(event.id)
            .bind(event.occurred_at.to_rfc3339())
            .bind(&event.action)
            .bind(&event.resource_id)
            .bind(&event.outcome)
            .bind(&event.detail)
            .execute(&mut *tx)
            .await?;
        }
        sqlx::query(
            "INSERT INTO audit_log \
             (occurred_at, action, resource_id, outcome, detail) \
             VALUES (?, 'backup.restore', NULL, 'success', ?)",
        )
        .bind(Utc::now().to_rfc3339())
        .bind(format!(
            "{} hosts, {} tunnels, {} database profiles",
            report.hosts, report.tunnels, report.database_profiles
        ))
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(report)
    }

    async fn list_all_audit_events(&self) -> Result<Vec<AuditEvent>> {
        let rows = sqlx::query(
            "SELECT id, occurred_at, action, resource_id, outcome, detail \
             FROM audit_log ORDER BY id ASC",
        )
        .fetch_all(&self.pool)
        .await?;
        rows.iter()
            .map(|row| {
                Ok(AuditEvent {
                    id: row.try_get("id")?,
                    occurred_at: parse_time(row.try_get("occurred_at")?)?,
                    action: row.try_get("action")?,
                    resource_id: row.try_get("resource_id")?,
                    outcome: row.try_get("outcome")?,
                    detail: row.try_get("detail")?,
                })
            })
            .collect()
    }
}

fn validate_snapshot(snapshot: &BackupSnapshot) -> Result<()> {
    if snapshot.schema_version != BACKUP_SCHEMA_VERSION {
        return Err(anyhow!(
            "unsupported backup schema version {}",
            snapshot.schema_version
        ));
    }
    for (label, count) in [
        ("hosts", snapshot.hosts.len()),
        ("tunnels", snapshot.tunnels.len()),
        ("database profiles", snapshot.database_profiles.len()),
        ("audit events", snapshot.audit_events.len()),
    ] {
        if count > MAX_BACKUP_RECORDS_PER_TABLE {
            return Err(anyhow!("backup contains too many {label}"));
        }
    }

    let host_ids = snapshot
        .hosts
        .iter()
        .map(|host| host.id)
        .collect::<std::collections::HashSet<_>>();
    let tunnel_ids = snapshot
        .tunnels
        .iter()
        .map(|tunnel| tunnel.id)
        .collect::<std::collections::HashSet<_>>();
    if host_ids.len() != snapshot.hosts.len()
        || tunnel_ids.len() != snapshot.tunnels.len()
        || snapshot
            .tunnels
            .iter()
            .any(|tunnel| !host_ids.contains(&tunnel.host_id))
        || snapshot
            .database_profiles
            .iter()
            .filter_map(|profile| profile.tunnel_id)
            .any(|id| !tunnel_ids.contains(&id))
    {
        return Err(anyhow!(
            "backup has duplicate or invalid inventory relationships"
        ));
    }
    let bounded = |value: &str| value.len() <= 16_384 && !value.contains(['\0', '\r', '\n']);
    if snapshot.hosts.iter().any(|host| {
        !bounded(&host.alias)
            || !bounded(&host.hostname)
            || !bounded(&host.source)
            || host.user.as_deref().is_some_and(|value| !bounded(value))
            || host
                .proxy_jump
                .as_deref()
                .is_some_and(|value| !bounded(value))
            || host.tags.iter().any(|value| !bounded(value))
    }) || snapshot.tunnels.iter().any(|tunnel| {
        !bounded(&tunnel.label) || !bounded(&tunnel.bind_address) || !bounded(&tunnel.remote_host)
    }) || snapshot.database_profiles.iter().any(|profile| {
        !bounded(&profile.label)
            || !bounded(&profile.hostname)
            || !bounded(&profile.database_name)
            || !bounded(&profile.username)
    }) || snapshot.audit_events.iter().any(|event| {
        !bounded(&event.action)
            || !bounded(&event.outcome)
            || event.detail.len() > 1_048_576
            || event.detail.contains('\0')
    }) {
        return Err(anyhow!("backup contains invalid or oversized fields"));
    }
    Ok(())
}

#[cfg(unix)]
async fn set_directory_private(path: &Path) -> Result<()> {
    tokio::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))
        .await
        .with_context(|| format!("could not secure {}", path.display()))
}

#[cfg(not(unix))]
async fn set_directory_private(_path: &Path) -> Result<()> {
    Ok(())
}

#[cfg(unix)]
async fn set_sqlite_files_private(path: &Path) -> Result<()> {
    for suffix in ["", "-wal", "-shm"] {
        let candidate = if suffix.is_empty() {
            path.to_path_buf()
        } else {
            let mut name = path.as_os_str().to_owned();
            name.push(suffix);
            PathBuf::from(name)
        };
        if tokio::fs::try_exists(&candidate).await? {
            tokio::fs::set_permissions(&candidate, std::fs::Permissions::from_mode(0o600))
                .await
                .with_context(|| format!("could not secure {}", candidate.display()))?;
        }
    }
    Ok(())
}

#[cfg(not(unix))]
async fn set_sqlite_files_private(_path: &Path) -> Result<()> {
    Ok(())
}

fn parse_time(value: String) -> Result<DateTime<Utc>> {
    Ok(DateTime::parse_from_rfc3339(&value)
        .context("invalid persisted timestamp")?
        .with_timezone(&Utc))
}

fn row_to_host(row: &sqlx::sqlite::SqliteRow) -> Result<Host> {
    Ok(Host {
        id: Uuid::parse_str(row.try_get("id")?)?,
        alias: row.try_get("alias")?,
        hostname: row.try_get("hostname")?,
        user: row.try_get("user")?,
        port: u16::try_from(row.try_get::<i64, _>("port")?)?,
        proxy_jump: row.try_get("proxy_jump")?,
        identity_hint: row.try_get("identity_hint")?,
        source: row.try_get("source")?,
        tags: row
            .try_get::<String, _>("tags")?
            .split(',')
            .filter(|tag| !tag.is_empty())
            .map(str::to_owned)
            .collect(),
        created_at: parse_time(row.try_get("created_at")?)?,
        updated_at: parse_time(row.try_get("updated_at")?)?,
    })
}

fn row_to_tunnel(row: &sqlx::sqlite::SqliteRow) -> Result<Tunnel> {
    let kind: String = row.try_get("kind")?;
    let status: String = row.try_get("status")?;
    Ok(Tunnel {
        id: Uuid::parse_str(row.try_get("id")?)?,
        host_id: Uuid::parse_str(row.try_get("host_id")?)?,
        label: row.try_get("label")?,
        kind: TunnelKind::parse(&kind).ok_or_else(|| anyhow!("invalid tunnel kind"))?,
        bind_address: row.try_get("bind_address")?,
        local_port: u16::try_from(row.try_get::<i64, _>("local_port")?)?,
        remote_host: row.try_get("remote_host")?,
        remote_port: u16::try_from(row.try_get::<i64, _>("remote_port")?)?,
        status: match status.as_str() {
            "starting" => TunnelStatus::Starting,
            "running" => TunnelStatus::Running,
            "stopping" => TunnelStatus::Stopping,
            "failed" => TunnelStatus::Failed,
            _ => TunnelStatus::Stopped,
        },
        last_error: row.try_get("last_error")?,
        created_at: parse_time(row.try_get("created_at")?)?,
        updated_at: parse_time(row.try_get("updated_at")?)?,
    })
}

fn row_to_database_profile(row: &sqlx::sqlite::SqliteRow) -> Result<DatabaseProfile> {
    let engine: String = row.try_get("engine")?;
    Ok(DatabaseProfile {
        id: Uuid::parse_str(row.try_get("id")?)?,
        label: row.try_get("label")?,
        engine: DatabaseEngine::parse(&engine).ok_or_else(|| anyhow!("invalid database engine"))?,
        hostname: row.try_get("hostname")?,
        port: u16::try_from(row.try_get::<i64, _>("port")?)?,
        database_name: row.try_get("database_name")?,
        username: row.try_get("username")?,
        secret_reference: row.try_get("secret_reference")?,
        tunnel_id: row
            .try_get::<Option<String>, _>("tunnel_id")?
            .map(|value| Uuid::parse_str(&value))
            .transpose()?,
        auto_start_tunnel: row.try_get("auto_start_tunnel")?,
        read_only: row.try_get("read_only")?,
        created_at: parse_time(row.try_get("created_at")?)?,
        updated_at: parse_time(row.try_get("updated_at")?)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn example_host() -> Host {
        let now = Utc::now();
        Host {
            id: Uuid::new_v4(),
            alias: "edge-prod".into(),
            hostname: "10.0.0.8".into(),
            user: Some("deploy".into()),
            port: 22,
            proxy_jump: Some("bastion".into()),
            identity_hint: Some("id_ed25519".into()),
            source: "~/.ssh/config".into(),
            tags: vec!["prod".into()],
            created_at: now,
            updated_at: now,
        }
    }

    #[tokio::test]
    async fn host_upsert_is_idempotent() {
        let store = Store::in_memory().await.unwrap();
        let host = example_host();
        let first = store
            .upsert_hosts(std::slice::from_ref(&host))
            .await
            .unwrap();
        let second = store
            .upsert_hosts(std::slice::from_ref(&host))
            .await
            .unwrap();
        assert_eq!(first.imported, 1);
        assert_eq!(second.updated, 1);
        assert_eq!(store.list_hosts("").await.unwrap().len(), 1);
    }

    #[tokio::test]
    async fn redis_database_profile_round_trips_ephemeral_route_policy() {
        let store = Store::in_memory().await.unwrap();
        let now = Utc::now();
        let profile = DatabaseProfile {
            id: Uuid::new_v4(),
            label: "Local Redis".into(),
            engine: DatabaseEngine::Redis,
            hostname: "127.0.0.1".into(),
            port: 6379,
            database_name: "0".into(),
            username: String::new(),
            secret_reference: Some("keychain-id".into()),
            tunnel_id: None,
            auto_start_tunnel: true,
            read_only: true,
            created_at: now,
            updated_at: now,
        };
        store.save_database_profile(&profile).await.unwrap();
        let restored = store.get_database_profile(profile.id).await.unwrap();
        assert_eq!(restored.engine, DatabaseEngine::Redis);
        assert!(restored.auto_start_tunnel);
        assert_eq!(restored.secret_reference.as_deref(), Some("keychain-id"));
    }

    #[tokio::test]
    async fn startup_recovery_stops_only_transient_tunnel_states() {
        let store = Store::in_memory().await.unwrap();
        let host = example_host();
        store
            .upsert_hosts(std::slice::from_ref(&host))
            .await
            .unwrap();
        let now = Utc::now();
        let mut tunnels = Vec::new();
        for (index, status) in [
            TunnelStatus::Starting,
            TunnelStatus::Running,
            TunnelStatus::Stopping,
            TunnelStatus::Stopped,
            TunnelStatus::Failed,
        ]
        .into_iter()
        .enumerate()
        {
            let tunnel = Tunnel {
                id: Uuid::new_v4(),
                host_id: host.id,
                label: format!("Recovery fixture {index}"),
                kind: TunnelKind::Local,
                bind_address: "127.0.0.1".into(),
                local_port: 20_000 + u16::try_from(index).unwrap(),
                remote_host: "database.internal".into(),
                remote_port: 5432,
                status,
                last_error: (status == TunnelStatus::Failed).then(|| "keep me".into()),
                created_at: now,
                updated_at: now,
            };
            store.save_tunnel(&tunnel).await.unwrap();
            tunnels.push(tunnel);
        }

        assert_eq!(store.recover_transient_tunnel_statuses().await.unwrap(), 3);

        for tunnel in &tunnels[..3] {
            let restored = store.get_tunnel(tunnel.id).await.unwrap();
            assert_eq!(restored.status, TunnelStatus::Stopped);
            assert!(restored.last_error.is_none());
        }
        assert_eq!(
            store.get_tunnel(tunnels[3].id).await.unwrap().status,
            TunnelStatus::Stopped
        );
        let failed = store.get_tunnel(tunnels[4].id).await.unwrap();
        assert_eq!(failed.status, TunnelStatus::Failed);
        assert_eq!(failed.last_error.as_deref(), Some("keep me"));
        let events = store.list_audit_events(10).await.unwrap();
        assert_eq!(events[0].action, "tunnel.recover");
        assert!(events[0].detail.contains("3 transient tunnel state"));
    }

    #[tokio::test]
    async fn logical_backup_restore_is_atomic_and_stops_tunnels() {
        let source = Store::in_memory().await.unwrap();
        let host = example_host();
        source
            .upsert_hosts(std::slice::from_ref(&host))
            .await
            .unwrap();
        let now = Utc::now();
        let tunnel = Tunnel {
            id: Uuid::new_v4(),
            host_id: host.id,
            label: "Production database".into(),
            kind: TunnelKind::Local,
            bind_address: "127.0.0.1".into(),
            local_port: 15432,
            remote_host: "database.internal".into(),
            remote_port: 5432,
            status: TunnelStatus::Running,
            last_error: None,
            created_at: now,
            updated_at: now,
        };
        source.save_tunnel(&tunnel).await.unwrap();
        let profile = DatabaseProfile {
            id: Uuid::new_v4(),
            label: "Production Postgres".into(),
            engine: DatabaseEngine::Postgres,
            hostname: "127.0.0.1".into(),
            port: 15432,
            database_name: "app".into(),
            username: "deploy".into(),
            secret_reference: Some("keychain-reference".into()),
            tunnel_id: Some(tunnel.id),
            auto_start_tunnel: true,
            read_only: true,
            created_at: now,
            updated_at: now,
        };
        source.save_database_profile(&profile).await.unwrap();
        source
            .audit("fixture.read", Some(host.id), "success", "redacted")
            .await
            .unwrap();
        let payload = source.export_backup().await.unwrap();

        let target = Store::in_memory().await.unwrap();
        let report = target.restore_backup(&payload).await.unwrap();
        assert_eq!(report.hosts, 1);
        assert_eq!(report.tunnels, 1);
        assert_eq!(report.database_profiles, 1);
        assert_eq!(
            target.get_tunnel(tunnel.id).await.unwrap().status,
            TunnelStatus::Stopped
        );
        assert_eq!(
            target
                .get_database_profile(profile.id)
                .await
                .unwrap()
                .secret_reference
                .as_deref(),
            Some("keychain-reference")
        );
        let events = target.list_audit_events(10).await.unwrap();
        assert_eq!(events[0].action, "backup.restore");
        assert!(events.iter().any(|event| event.action == "fixture.read"));
    }

    #[tokio::test]
    async fn invalid_backup_does_not_replace_existing_inventory() {
        let store = Store::in_memory().await.unwrap();
        let host = example_host();
        store
            .upsert_hosts(std::slice::from_ref(&host))
            .await
            .unwrap();
        assert!(
            store
                .restore_backup(br#"{"schema_version":99}"#)
                .await
                .is_err()
        );
        assert_eq!(store.list_hosts("").await.unwrap(), vec![host]);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn legacy_database_profile_schema_migrates_without_data_loss() {
        let root = std::env::temp_dir().join(format!("aegiz-migration-test-{}", Uuid::new_v4()));
        tokio::fs::create_dir_all(&root).await.unwrap();
        let database = root.join("legacy.sqlite");
        let options = SqliteConnectOptions::from_str(&format!("sqlite://{}", database.display()))
            .unwrap()
            .create_if_missing(true);
        let pool = SqlitePool::connect_with(options).await.unwrap();
        sqlx::query(
            r#"
            CREATE TABLE database_profiles (
                id TEXT PRIMARY KEY NOT NULL,
                label TEXT NOT NULL,
                engine TEXT NOT NULL,
                hostname TEXT NOT NULL,
                port INTEGER NOT NULL,
                database_name TEXT NOT NULL,
                username TEXT NOT NULL,
                secret_reference TEXT,
                tunnel_id TEXT,
                read_only INTEGER NOT NULL DEFAULT 1,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            "#,
        )
        .execute(&pool)
        .await
        .unwrap();
        let id = Uuid::new_v4();
        let now = Utc::now().to_rfc3339();
        sqlx::query(
            "INSERT INTO database_profiles \
             (id, label, engine, hostname, port, database_name, username, \
              read_only, created_at, updated_at) \
             VALUES (?, 'Legacy Postgres', 'postgres', '127.0.0.1', 5432, \
                     'app', 'deploy', 1, ?, ?)",
        )
        .bind(id.to_string())
        .bind(&now)
        .bind(&now)
        .execute(&pool)
        .await
        .unwrap();
        pool.close().await;

        let store = Store::open(&database).await.unwrap();
        let profile = store.get_database_profile(id).await.unwrap();
        assert_eq!(profile.label, "Legacy Postgres");
        assert!(!profile.auto_start_tunnel);
        store.pool.close().await;
        tokio::fs::remove_dir_all(root).await.unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn disk_inventory_is_private_to_the_current_user() {
        use std::os::unix::fs::PermissionsExt;

        let root = std::env::temp_dir().join(format!("aegiz-storage-test-{}", Uuid::new_v4()));
        let database = root.join("aegiz.sqlite");
        let store = Store::open(&database).await.unwrap();

        let directory_mode = tokio::fs::metadata(&root)
            .await
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        let database_mode = tokio::fs::metadata(&database)
            .await
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(directory_mode, 0o700);
        assert_eq!(database_mode, 0o600);

        store.pool.close().await;
        tokio::fs::remove_dir_all(root).await.unwrap();
    }
}
