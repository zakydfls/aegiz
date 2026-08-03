use crate::{
    application::{adapters::redact, tunnels::TunnelManager},
    proto::{OperationEvent, RunDatabaseQueryRequest},
};
use aegiz_domain::{DatabaseEngine, DatabaseProfile};
use aegiz_platform::CredentialLease;
use aegiz_storage::Store;
use anyhow::{Context, Result};
use futures_util::TryStreamExt;
use sqlx::{
    Column, Connection, Row, TypeInfo, ValueRef,
    mysql::{MySqlConnectOptions, MySqlConnection, MySqlRow},
    postgres::{PgConnectOptions, PgConnection, PgRow},
};
use std::{
    collections::HashMap,
    future::Future,
    pin::Pin,
    str,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::TcpStream,
    sync::{Mutex, mpsc, oneshot},
    time::{Duration, timeout},
};
use uuid::Uuid;

type EventSender = mpsc::Sender<Result<OperationEvent, tonic::Status>>;

#[derive(Clone)]
pub struct DatabaseRuntime {
    store: Store,
    tunnels: TunnelManager,
    cancellations: Arc<Mutex<HashMap<Uuid, oneshot::Sender<()>>>>,
}

struct EphemeralTunnelLease {
    tunnel_id: Option<Uuid>,
    tunnels: TunnelManager,
}

impl EphemeralTunnelLease {
    fn new(tunnels: TunnelManager, tunnel_id: Uuid) -> Self {
        Self {
            tunnel_id: Some(tunnel_id),
            tunnels,
        }
    }

    async fn release(mut self) -> Result<()> {
        if let Some(tunnel_id) = self.tunnel_id.take() {
            self.tunnels.stop(tunnel_id).await?;
        }
        Ok(())
    }
}

impl Drop for EphemeralTunnelLease {
    fn drop(&mut self) {
        let Some(tunnel_id) = self.tunnel_id.take() else {
            return;
        };
        let tunnels = self.tunnels.clone();
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move {
                let _ = tunnels.stop(tunnel_id).await;
            });
        }
    }
}

impl DatabaseRuntime {
    pub fn new(store: Store, tunnels: TunnelManager) -> Self {
        Self {
            store,
            tunnels,
            cancellations: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub async fn execute(&self, mut request: RunDatabaseQueryRequest, sender: EventSender) {
        let operation_id = Uuid::new_v4();
        let sequence = Arc::new(AtomicU64::new(1));
        let secret = match CredentialLease::new(std::mem::take(&mut request.secret_value)) {
            Ok(value) => value,
            Err(error) => {
                terminal_error(&sender, &sequence, operation_id, &error.to_string()).await;
                return;
            }
        };
        let tunnel_ssh_auth_secret =
            match CredentialLease::new(std::mem::take(&mut request.tunnel_ssh_auth_secret)) {
                Ok(value) => value,
                Err(error) => {
                    terminal_error(&sender, &sequence, operation_id, &error.to_string()).await;
                    return;
                }
            };
        let profile_id = match Uuid::parse_str(&request.profile_id) {
            Ok(value) => value,
            Err(_) => {
                terminal_error(&sender, &sequence, operation_id, "Invalid database profile").await;
                return;
            }
        };
        let mut profile = match self.store.get_database_profile(profile_id).await {
            Ok(value) => value,
            Err(_) => {
                terminal_error(
                    &sender,
                    &sequence,
                    operation_id,
                    "Database profile was not found",
                )
                .await;
                return;
            }
        };
        let is_read = query_is_read_only_for_engine(profile.engine, &request.sql);
        if (profile.read_only || !request.confirmed_mutation) && !is_read {
            terminal_error(
                &sender,
                &sequence,
                operation_id,
                if profile.read_only {
                    "This profile is read-only"
                } else {
                    "Database mutations require confirmation"
                },
            )
            .await;
            return;
        }
        if request.sql.trim().is_empty() || request.sql.len() > 256 * 1024 {
            terminal_error(
                &sender,
                &sequence,
                operation_id,
                "Query is empty or exceeds 256 KiB",
            )
            .await;
            return;
        }

        let mut query_owned_tunnel: Option<EphemeralTunnelLease> = None;
        if let Some(tunnel_id) = profile.tunnel_id {
            let mut tunnel = match self.store.get_tunnel(tunnel_id).await {
                Ok(value) => value,
                Err(_) => {
                    terminal_error(
                        &sender,
                        &sequence,
                        operation_id,
                        "The selected database tunnel was not found",
                    )
                    .await;
                    return;
                }
            };
            if tunnel.status != aegiz_domain::TunnelStatus::Running {
                if !profile.auto_start_tunnel {
                    terminal_error(
                        &sender,
                        &sequence,
                        operation_id,
                        "The selected database tunnel is not running",
                    )
                    .await;
                    return;
                }
                if let Err(error) = self
                    .tunnels
                    .start_with_credential(tunnel_id, tunnel_ssh_auth_secret)
                    .await
                {
                    terminal_error(
                        &sender,
                        &sequence,
                        operation_id,
                        &format!("Could not start the ephemeral tunnel: {error}"),
                    )
                    .await;
                    return;
                }
                query_owned_tunnel =
                    Some(EphemeralTunnelLease::new(self.tunnels.clone(), tunnel_id));
                tunnel = match self.store.get_tunnel(tunnel_id).await {
                    Ok(value) => value,
                    Err(error) => {
                        if let Some(lease) = query_owned_tunnel.take() {
                            let _ = lease.release().await;
                        }
                        terminal_error(
                            &sender,
                            &sequence,
                            operation_id,
                            &format!("Could not load the ephemeral tunnel route: {error}"),
                        )
                        .await;
                        return;
                    }
                };
            }
            profile.hostname = tunnel.bind_address;
            profile.port = tunnel.local_port;
        }

        // Register cancellation before publishing the operation identifier so
        // an immediate Cancel click cannot lose a race with query startup.
        let (cancel_sender, cancel_receiver) = oneshot::channel();
        self.cancellations
            .lock()
            .await
            .insert(operation_id, cancel_sender);

        let _ = self
            .store
            .audit(
                "database.query",
                Some(profile.id),
                "started",
                &format!("engine={} read_only={is_read}", profile.engine.as_str()),
            )
            .await;
        send(
            &sender,
            &sequence,
            OperationEvent {
                operation_id: operation_id.to_string(),
                phase: "running".into(),
                message: format!("Connecting to {}", profile.label),
                progress: 5,
                terminal: false,
                success: false,
                stream: "system".into(),
                sequence: 0,
                exit_code: 0,
            },
        )
        .await;

        let query = run_query(
            &profile,
            &request.sql,
            secret.expose(),
            is_read,
            profile.read_only,
            operation_id,
            &sender,
            &sequence,
        );
        let result = tokio::select! {
            result = query => result.map(|rows| (rows, false)),
            _ = cancel_receiver => Ok((0, true)),
        };
        self.cancellations.lock().await.remove(&operation_id);
        let cleanup_error = if let Some(lease) = query_owned_tunnel.take() {
            lease.release().await.err()
        } else {
            None
        };

        let (message, success, outcome, exit_code) = match (result, cleanup_error) {
            (_, Some(error)) => (
                format!("Query route cleanup failed: {}", redact(&error.to_string())),
                false,
                "failed",
                -1,
            ),
            (Ok((_, true)), None) => ("Query cancelled".into(), false, "cancelled", -1),
            (Ok((rows, false)), None) => (
                format!("Query completed · {rows} row(s)"),
                true,
                "success",
                0,
            ),
            (Err(error), None) => (redact(&error.to_string()), false, "failed", -1),
        };
        let _ = self
            .store
            .audit(
                "database.query",
                Some(profile.id),
                outcome,
                &format!("engine={} exit_code={exit_code}", profile.engine.as_str()),
            )
            .await;
        send(
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

    pub async fn cancel(&self, operation_id: Uuid) -> bool {
        self.cancellations
            .lock()
            .await
            .remove(&operation_id)
            .is_some_and(|sender| sender.send(()).is_ok())
    }

    pub async fn cancel_all(&self) {
        let values = self
            .cancellations
            .lock()
            .await
            .drain()
            .map(|(_, sender)| sender)
            .collect::<Vec<_>>();
        for sender in values {
            let _ = sender.send(());
        }
    }
}

// Keep query intent, enforcement, cancellation identity, and event sink
// explicit at this sensitive boundary.
#[allow(clippy::too_many_arguments)]
async fn run_query(
    profile: &DatabaseProfile,
    sql: &str,
    secret: &[u8],
    read_only: bool,
    enforce_read_only: bool,
    operation_id: Uuid,
    sender: &EventSender,
    sequence: &AtomicU64,
) -> Result<usize> {
    let password = str::from_utf8(secret).context("database secret is not UTF-8")?;
    match profile.engine {
        DatabaseEngine::Postgres => {
            let options = PgConnectOptions::new()
                .host(&profile.hostname)
                .port(profile.port)
                .username(&profile.username)
                .database(&profile.database_name)
                .password(password);
            let mut connection = PgConnection::connect_with(&options)
                .await
                .context("PostgreSQL connection failed")?;
            send_system(
                sender,
                sequence,
                operation_id,
                "Transaction state: auto-commit · isolated connection for this run",
                15,
            )
            .await;
            if enforce_read_only {
                sqlx::query("SET default_transaction_read_only = on")
                    .execute(&mut connection)
                    .await
                    .context("PostgreSQL could not enforce read-only mode")?;
            }
            if read_only {
                stream_postgres_rows(&mut connection, sql, operation_id, sender, sequence).await
            } else {
                let result = sqlx::query(sql)
                    .execute(&mut connection)
                    .await
                    .context("PostgreSQL query failed")?;
                Ok(result.rows_affected() as usize)
            }
        }
        DatabaseEngine::MySql => {
            let options = MySqlConnectOptions::new()
                .host(&profile.hostname)
                .port(profile.port)
                .username(&profile.username)
                .database(&profile.database_name)
                .password(password);
            let mut connection = MySqlConnection::connect_with(&options)
                .await
                .context("MySQL connection failed")?;
            send_system(
                sender,
                sequence,
                operation_id,
                "Transaction state: auto-commit · isolated connection for this run",
                15,
            )
            .await;
            if enforce_read_only {
                sqlx::query("SET SESSION TRANSACTION READ ONLY")
                    .execute(&mut connection)
                    .await
                    .context("MySQL could not enforce read-only mode")?;
            }
            if read_only {
                stream_mysql_rows(&mut connection, sql, operation_id, sender, sequence).await
            } else {
                let result = sqlx::query(sql)
                    .execute(&mut connection)
                    .await
                    .context("MySQL query failed")?;
                Ok(result.rows_affected() as usize)
            }
        }
        DatabaseEngine::Redis => {
            run_redis_command(profile, sql, secret, operation_id, sender, sequence).await
        }
    }
}

#[derive(Debug)]
enum RedisValue {
    Simple(String),
    Error(String),
    Integer(i64),
    Bulk(Option<Vec<u8>>),
    Array(Option<Vec<RedisValue>>),
}

async fn run_redis_command(
    profile: &DatabaseProfile,
    command: &str,
    secret: &[u8],
    operation_id: Uuid,
    sender: &EventSender,
    sequence: &AtomicU64,
) -> Result<usize> {
    let stream = timeout(
        Duration::from_secs(10),
        TcpStream::connect((profile.hostname.as_str(), profile.port)),
    )
    .await
    .context("Redis connection timed out")?
    .context("Redis connection failed")?;
    let mut connection = BufReader::new(stream);

    if !secret.is_empty() {
        if secret.len() > 64 * 1024 {
            anyhow::bail!("Redis secret exceeds 64 KiB");
        }
        let auth = b"AUTH".as_slice();
        let username = profile.username.as_bytes();
        let parts: Vec<&[u8]> = if username.is_empty() || profile.username == "default" {
            vec![auth, secret]
        } else {
            vec![auth, username, secret]
        };
        write_redis_command(connection.get_mut(), &parts).await?;
        ensure_redis_success(read_redis_value(&mut connection, 0).await?)
            .context("Redis authentication failed")?;
    }

    let database = profile.database_name.trim();
    if database != "0" {
        let index: u16 = database
            .parse()
            .context("Redis database must be an integer from 0 to 65535")?;
        let index = index.to_string();
        write_redis_command(
            connection.get_mut(),
            &[b"SELECT".as_slice(), index.as_bytes()],
        )
        .await?;
        ensure_redis_success(read_redis_value(&mut connection, 0).await?)
            .context("Redis database selection failed")?;
    }

    send_system(
        sender,
        sequence,
        operation_id,
        "Redis connection state: isolated connection for this command",
        15,
    )
    .await;
    let arguments = parse_redis_command(command)?;
    let argument_bytes = arguments
        .iter()
        .map(|argument| argument.as_bytes())
        .collect::<Vec<_>>();
    write_redis_command(connection.get_mut(), &argument_bytes).await?;
    let value = read_redis_value(&mut connection, 0).await?;
    if let RedisValue::Error(message) = &value {
        anyhow::bail!("Redis command failed: {}", redact(message));
    }

    let mut rows = Vec::new();
    flatten_redis_value(&value, "", &mut rows);
    if rows.is_empty() {
        rows.push(vec!["(empty)".into()]);
    }
    let count = rows.len().min(1000);
    for row in rows.into_iter().take(1000) {
        send_row(sender, sequence, operation_id, row).await;
    }
    Ok(count)
}

fn parse_redis_command(input: &str) -> Result<Vec<String>> {
    #[derive(Clone, Copy, PartialEq, Eq)]
    enum Mode {
        Normal,
        Single,
        Double,
    }

    if input.contains(['\0', '\n', '\r']) {
        anyhow::bail!("Redis command contains unsupported control characters");
    }

    let mut mode = Mode::Normal;
    let mut escaping = false;
    let mut token_started = false;
    let mut current = String::new();
    let mut arguments = Vec::new();
    for character in input.trim().chars() {
        if escaping {
            current.push(character);
            token_started = true;
            escaping = false;
            continue;
        }
        match mode {
            Mode::Normal => match character {
                '\\' => {
                    escaping = true;
                    token_started = true;
                }
                '\'' => {
                    mode = Mode::Single;
                    token_started = true;
                }
                '"' => {
                    mode = Mode::Double;
                    token_started = true;
                }
                character if character.is_whitespace() => {
                    if token_started {
                        arguments.push(std::mem::take(&mut current));
                        token_started = false;
                    }
                }
                _ => {
                    current.push(character);
                    token_started = true;
                }
            },
            Mode::Single => {
                if character == '\'' {
                    mode = Mode::Normal;
                } else {
                    current.push(character);
                }
            }
            Mode::Double => {
                if character == '"' {
                    mode = Mode::Normal;
                } else if character == '\\' {
                    escaping = true;
                } else {
                    current.push(character);
                }
            }
        }
    }
    if escaping || mode != Mode::Normal {
        anyhow::bail!("Redis command contains an unfinished quote or escape");
    }
    if token_started {
        arguments.push(current);
    }
    if arguments.is_empty()
        || arguments.len() > 128
        || arguments.iter().map(String::len).sum::<usize>() > 256 * 1024
        || arguments
            .iter()
            .any(|argument| argument.contains(['\0', '\n', '\r']))
    {
        anyhow::bail!("Redis command is empty or exceeds safety limits");
    }
    Ok(arguments)
}

async fn write_redis_command(stream: &mut TcpStream, parts: &[&[u8]]) -> Result<()> {
    let mut payload = Vec::new();
    payload.extend_from_slice(format!("*{}\r\n", parts.len()).as_bytes());
    for part in parts {
        payload.extend_from_slice(format!("${}\r\n", part.len()).as_bytes());
        payload.extend_from_slice(part);
        payload.extend_from_slice(b"\r\n");
    }
    stream
        .write_all(&payload)
        .await
        .context("Redis command write failed")?;
    stream.flush().await.context("Redis command flush failed")
}

fn read_redis_value<'a>(
    reader: &'a mut BufReader<TcpStream>,
    depth: usize,
) -> Pin<Box<dyn Future<Output = Result<RedisValue>> + Send + 'a>> {
    Box::pin(async move {
        if depth > 8 {
            anyhow::bail!("Redis response nesting exceeds the safety limit");
        }
        let mut prefix = [0_u8; 1];
        reader
            .read_exact(&mut prefix)
            .await
            .context("Redis response ended unexpectedly")?;
        match prefix[0] {
            b'+' => Ok(RedisValue::Simple(read_redis_line(reader).await?)),
            b'-' => Ok(RedisValue::Error(read_redis_line(reader).await?)),
            b':' => Ok(RedisValue::Integer(
                read_redis_line(reader)
                    .await?
                    .parse()
                    .context("Redis returned an invalid integer")?,
            )),
            b'$' => {
                let length: i64 = read_redis_line(reader)
                    .await?
                    .parse()
                    .context("Redis returned an invalid bulk length")?;
                if length == -1 {
                    return Ok(RedisValue::Bulk(None));
                }
                if !(0..=1_048_576).contains(&length) {
                    anyhow::bail!("Redis bulk response exceeds the 1 MiB preview limit");
                }
                let mut value = vec![0_u8; length as usize];
                reader
                    .read_exact(&mut value)
                    .await
                    .context("Redis bulk response ended unexpectedly")?;
                consume_redis_crlf(reader).await?;
                Ok(RedisValue::Bulk(Some(value)))
            }
            b'*' => {
                let count: i64 = read_redis_line(reader)
                    .await?
                    .parse()
                    .context("Redis returned an invalid array length")?;
                if count == -1 {
                    return Ok(RedisValue::Array(None));
                }
                if !(0..=1000).contains(&count) {
                    anyhow::bail!("Redis array response exceeds the 1000 item limit");
                }
                let mut values = Vec::with_capacity(count as usize);
                for _ in 0..count {
                    values.push(read_redis_value(reader, depth + 1).await?);
                }
                Ok(RedisValue::Array(Some(values)))
            }
            _ => anyhow::bail!("Redis returned an unsupported RESP response"),
        }
    })
}

async fn read_redis_line(reader: &mut BufReader<TcpStream>) -> Result<String> {
    let mut line = Vec::new();
    let count = reader
        .read_until(b'\n', &mut line)
        .await
        .context("Redis response read failed")?;
    if count == 0 || line.len() > 64 * 1024 || !line.ends_with(b"\r\n") {
        anyhow::bail!("Redis returned an invalid or oversized response line");
    }
    line.truncate(line.len() - 2);
    String::from_utf8(line).context("Redis response line is not UTF-8")
}

async fn consume_redis_crlf(reader: &mut BufReader<TcpStream>) -> Result<()> {
    let mut suffix = [0_u8; 2];
    reader.read_exact(&mut suffix).await?;
    if suffix != *b"\r\n" {
        anyhow::bail!("Redis bulk response has an invalid terminator");
    }
    Ok(())
}

fn ensure_redis_success(value: RedisValue) -> Result<()> {
    match value {
        RedisValue::Simple(_) => Ok(()),
        RedisValue::Error(message) => anyhow::bail!("{}", redact(&message)),
        _ => anyhow::bail!("Redis returned an unexpected response"),
    }
}

fn flatten_redis_value(value: &RedisValue, path: &str, rows: &mut Vec<Vec<String>>) {
    if rows.len() >= 1000 {
        return;
    }
    match value {
        RedisValue::Simple(value) => rows.push(redis_scalar_row(path, value.clone())),
        RedisValue::Error(value) => rows.push(redis_scalar_row(path, redact(value))),
        RedisValue::Integer(value) => rows.push(redis_scalar_row(path, value.to_string())),
        RedisValue::Bulk(None) | RedisValue::Array(None) => {
            rows.push(redis_scalar_row(path, "NULL".into()));
        }
        RedisValue::Bulk(Some(value)) => {
            let rendered = String::from_utf8(value.clone())
                .unwrap_or_else(|value| format!("[binary {} bytes]", value.as_bytes().len()));
            rows.push(redis_scalar_row(path, rendered));
        }
        RedisValue::Array(Some(values)) => {
            for (index, value) in values.iter().enumerate() {
                let child = if path.is_empty() {
                    index.to_string()
                } else {
                    format!("{path}.{index}")
                };
                flatten_redis_value(value, &child, rows);
            }
        }
    }
}

fn redis_scalar_row(path: &str, value: String) -> Vec<String> {
    if path.is_empty() {
        vec![value]
    } else {
        vec![path.into(), value]
    }
}

async fn stream_postgres_rows(
    connection: &mut PgConnection,
    sql: &str,
    operation_id: Uuid,
    sender: &EventSender,
    sequence: &AtomicU64,
) -> Result<usize> {
    let mut rows = sqlx::query(sql).fetch(connection);
    let mut count = 0;
    while let Some(row) = rows.try_next().await.context("PostgreSQL query failed")? {
        if count == 0 {
            send_row(
                sender,
                sequence,
                operation_id,
                row.columns().iter().map(|column| column.name()),
            )
            .await;
        }
        send_row(
            sender,
            sequence,
            operation_id,
            (0..row.len()).map(|index| postgres_value(&row, index)),
        )
        .await;
        count += 1;
        if count >= 1000 {
            send_row(
                sender,
                sequence,
                operation_id,
                ["[result truncated at 1000 rows]"],
            )
            .await;
            break;
        }
    }
    Ok(count)
}

async fn stream_mysql_rows(
    connection: &mut MySqlConnection,
    sql: &str,
    operation_id: Uuid,
    sender: &EventSender,
    sequence: &AtomicU64,
) -> Result<usize> {
    let mut rows = sqlx::query(sql).fetch(connection);
    let mut count = 0;
    while let Some(row) = rows.try_next().await.context("MySQL query failed")? {
        if count == 0 {
            send_row(
                sender,
                sequence,
                operation_id,
                row.columns().iter().map(|column| column.name()),
            )
            .await;
        }
        send_row(
            sender,
            sequence,
            operation_id,
            (0..row.len()).map(|index| mysql_value(&row, index)),
        )
        .await;
        count += 1;
        if count >= 1000 {
            send_row(
                sender,
                sequence,
                operation_id,
                ["[result truncated at 1000 rows]"],
            )
            .await;
            break;
        }
    }
    Ok(count)
}

fn postgres_value(row: &PgRow, index: usize) -> String {
    let type_name = row.columns()[index].type_info().name();
    match type_name {
        "BOOL" => row
            .try_get::<Option<bool>, _>(index)
            .ok()
            .flatten()
            .map(|value| value.to_string()),
        "INT2" => numeric::<i16, _>(row, index),
        "INT4" => numeric::<i32, _>(row, index),
        "INT8" => numeric::<i64, _>(row, index),
        "FLOAT4" => numeric::<f32, _>(row, index),
        "FLOAT8" => numeric::<f64, _>(row, index),
        "BYTEA" => row
            .try_get::<Option<Vec<u8>>, _>(index)
            .ok()
            .flatten()
            .map(|value| format!("[binary {} bytes]", value.len())),
        _ => row.try_get::<Option<String>, _>(index).ok().flatten(),
    }
    .unwrap_or_else(|| {
        if row.try_get_raw(index).is_ok_and(|v| v.is_null()) {
            "NULL".into()
        } else {
            format!("<{type_name}>")
        }
    })
}

fn mysql_value(row: &MySqlRow, index: usize) -> String {
    let type_name = row.columns()[index].type_info().name();
    row.try_get::<Option<String>, _>(index)
        .ok()
        .flatten()
        .or_else(|| numeric::<i64, _>(row, index))
        .or_else(|| numeric::<f64, _>(row, index))
        .unwrap_or_else(|| {
            if row.try_get_raw(index).is_ok_and(|v| v.is_null()) {
                "NULL".into()
            } else {
                format!("<{type_name}>")
            }
        })
}

fn numeric<'r, T, R>(row: &'r R, index: usize) -> Option<String>
where
    R: Row,
    usize: sqlx::ColumnIndex<R>,
    T: sqlx::Decode<'r, R::Database> + sqlx::Type<R::Database> + ToString,
{
    row.try_get::<Option<T>, _>(index)
        .ok()
        .flatten()
        .map(|value| value.to_string())
}

async fn send_row<I, V>(sender: &EventSender, sequence: &AtomicU64, operation_id: Uuid, values: I)
where
    I: IntoIterator<Item = V>,
    V: AsRef<str>,
{
    let line = values
        .into_iter()
        .map(|value| {
            value
                .as_ref()
                .replace(['\t', '\r', '\n'], " ")
                .chars()
                .take(4096)
                .collect::<String>()
        })
        .collect::<Vec<_>>()
        .join("\t");
    send(
        sender,
        sequence,
        OperationEvent {
            operation_id: operation_id.to_string(),
            phase: "running".into(),
            message: format!("{}\n", redact(&line)),
            progress: 50,
            terminal: false,
            success: false,
            stream: "stdout".into(),
            sequence: 0,
            exit_code: 0,
        },
    )
    .await;
}

async fn send_system(
    sender: &EventSender,
    sequence: &AtomicU64,
    operation_id: Uuid,
    message: &str,
    progress: u32,
) {
    send(
        sender,
        sequence,
        OperationEvent {
            operation_id: operation_id.to_string(),
            phase: "running".into(),
            message: message.into(),
            progress,
            terminal: false,
            success: false,
            stream: "system".into(),
            sequence: 0,
            exit_code: 0,
        },
    )
    .await;
}

async fn terminal_error(
    sender: &EventSender,
    sequence: &AtomicU64,
    operation_id: Uuid,
    message: &str,
) {
    send(
        sender,
        sequence,
        OperationEvent {
            operation_id: operation_id.to_string(),
            phase: "failed".into(),
            message: message.into(),
            progress: 100,
            terminal: true,
            success: false,
            stream: "system".into(),
            sequence: 0,
            exit_code: -1,
        },
    )
    .await;
}

async fn send(sender: &EventSender, sequence: &AtomicU64, mut event: OperationEvent) {
    event.sequence = sequence.fetch_add(1, Ordering::Relaxed);
    let _ = sender.send(Ok(event)).await;
}

#[cfg(test)]
pub fn query_is_read_only(sql: &str) -> bool {
    query_is_read_only_for_engine(DatabaseEngine::Postgres, sql)
}

pub fn query_is_read_only_for_engine(engine: DatabaseEngine, sql: &str) -> bool {
    let normalized = sql
        .trim_start_matches(|character: char| character.is_whitespace() || character == ';')
        .to_ascii_lowercase();
    if engine != DatabaseEngine::Redis
        && normalized.split_once(';').is_some_and(|(_, suffix)| {
            suffix
                .chars()
                .any(|character| !character.is_whitespace() && character != ';')
        })
    {
        return false;
    }
    let commands: &[&str] = match engine {
        DatabaseEngine::Redis => &[
            "scan", "get", "mget", "type", "ttl", "pttl", "exists", "strlen", "hget", "hgetall",
            "hlen", "lrange", "llen", "smembers", "scard", "zrange", "zcard", "info", "dbsize",
            "ping", "echo",
        ],
        DatabaseEngine::Postgres | DatabaseEngine::MySql => {
            &["select", "show", "explain", "describe", "desc", "values"]
        }
    };
    commands.iter().any(|prefix| {
        normalized == *prefix
            || normalized.starts_with(&format!("{prefix} "))
            || normalized.starts_with(&format!("{prefix}\n"))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn dropped_ephemeral_tunnel_lease_reconciles_its_route() {
        let store = Store::in_memory().await.unwrap();
        let now = chrono::Utc::now();
        let host = aegiz_domain::Host {
            id: Uuid::new_v4(),
            alias: "fixture-host".into(),
            hostname: "127.0.0.1".into(),
            user: None,
            port: 22,
            proxy_jump: None,
            identity_hint: None,
            source: "test".into(),
            tags: Vec::new(),
            created_at: now,
            updated_at: now,
        };
        store
            .upsert_hosts(std::slice::from_ref(&host))
            .await
            .unwrap();
        let tunnel = aegiz_domain::Tunnel {
            id: Uuid::new_v4(),
            host_id: host.id,
            label: "Ephemeral route fixture".into(),
            kind: aegiz_domain::TunnelKind::Local,
            bind_address: "127.0.0.1".into(),
            local_port: 29_999,
            remote_host: "database.internal".into(),
            remote_port: 5432,
            status: aegiz_domain::TunnelStatus::Running,
            last_error: None,
            created_at: now,
            updated_at: now,
        };
        store.save_tunnel(&tunnel).await.unwrap();
        let manager = TunnelManager::new(store.clone(), std::env::temp_dir());

        drop(EphemeralTunnelLease::new(manager, tunnel.id));

        tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                if store.get_tunnel(tunnel.id).await.unwrap().status
                    == aegiz_domain::TunnelStatus::Stopped
                {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("lease drop should schedule deterministic route cleanup");
    }

    #[tokio::test]
    async fn immediate_database_cancellation_cannot_lose_the_registration_race() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = [0_u8; 64];
            let _ = socket.read(&mut request).await;
            std::future::pending::<()>().await;
        });

        let store = Store::in_memory().await.unwrap();
        let profile = fixture_profile(DatabaseEngine::Redis, port, "", "0");
        store.save_database_profile(&profile).await.unwrap();
        let tunnels = TunnelManager::new(store.clone(), std::env::temp_dir());
        let runtime = DatabaseRuntime::new(store, tunnels);
        let request = RunDatabaseQueryRequest {
            profile_id: profile.id.to_string(),
            secret_value: Vec::new(),
            sql: "PING".into(),
            confirmed_mutation: false,
            tunnel_ssh_auth_secret: Vec::new(),
        };
        let (sender, mut receiver) = mpsc::channel(32);
        let executor = {
            let runtime = runtime.clone();
            tokio::spawn(async move { runtime.execute(request, sender).await })
        };
        let running = tokio::time::timeout(Duration::from_secs(1), receiver.recv())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let operation_id = Uuid::parse_str(&running.operation_id).unwrap();

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
        server.abort();
    }

    #[tokio::test]
    async fn database_credentials_share_the_portable_lease_size_limit() {
        let store = Store::in_memory().await.unwrap();
        let tunnels = TunnelManager::new(store.clone(), std::env::temp_dir());
        let runtime = DatabaseRuntime::new(store, tunnels);
        let request = RunDatabaseQueryRequest {
            profile_id: Uuid::new_v4().to_string(),
            secret_value: vec![0; aegiz_platform::MAX_CREDENTIAL_BYTES + 1],
            sql: "SELECT 1".into(),
            confirmed_mutation: false,
            tunnel_ssh_auth_secret: Vec::new(),
        };
        let (sender, mut receiver) = mpsc::channel(8);
        runtime.execute(request, sender).await;
        let terminal = receiver.recv().await.unwrap().unwrap();
        assert!(terminal.terminal);
        assert!(!terminal.success);
        assert!(terminal.message.contains("64 KiB safety limit"));
    }

    #[test]
    fn query_risk_defaults_to_mutation() {
        assert!(query_is_read_only(" SELECT current_user"));
        assert!(query_is_read_only("EXPLAIN SELECT 1"));
        assert!(!query_is_read_only(
            "WITH deleted AS (DELETE FROM users RETURNING *) SELECT * FROM deleted"
        ));
        assert!(!query_is_read_only("UPDATE users SET admin = true"));
        assert!(!query_is_read_only("-- comment\nSELECT 1"));
        assert!(!query_is_read_only("SELECT 1; DELETE FROM users"));
        assert!(query_is_read_only_for_engine(
            DatabaseEngine::Redis,
            "SCAN 0 COUNT 100"
        ));
        assert!(!query_is_read_only_for_engine(
            DatabaseEngine::Redis,
            "DEL session:1"
        ));
    }

    #[test]
    fn redis_command_tokenizer_does_not_invoke_a_shell() {
        assert_eq!(
            parse_redis_command(r#"SET "release key" 'value with spaces'"#).unwrap(),
            ["SET", "release key", "value with spaces"]
        );
        assert!(parse_redis_command("GET \"unfinished").is_err());
        assert!(parse_redis_command("GET safe\nDEL other").is_err());
    }

    #[tokio::test]
    #[ignore = "requires AEGIZ_REDIS_FIXTURE_PORT and a disposable Redis server"]
    async fn native_redis_fixture_round_trip() {
        let port: u16 = std::env::var("AEGIZ_REDIS_FIXTURE_PORT")
            .expect("AEGIZ_REDIS_FIXTURE_PORT is required")
            .parse()
            .unwrap();
        let now = chrono::Utc::now();
        let profile = DatabaseProfile {
            id: Uuid::new_v4(),
            label: "Disposable Redis".into(),
            engine: DatabaseEngine::Redis,
            hostname: "127.0.0.1".into(),
            port,
            database_name: "0".into(),
            username: String::new(),
            secret_reference: None,
            tunnel_id: None,
            auto_start_tunnel: false,
            read_only: false,
            created_at: now,
            updated_at: now,
        };
        let operation = Uuid::new_v4();
        let sequence = AtomicU64::new(1);
        let (sender, mut receiver) = mpsc::channel(32);
        assert_eq!(
            run_redis_command(
                &profile,
                "SET aegiz:fixture verified",
                &[],
                operation,
                &sender,
                &sequence
            )
            .await
            .unwrap(),
            1
        );
        assert_eq!(
            run_redis_command(
                &profile,
                "GET aegiz:fixture",
                &[],
                operation,
                &sender,
                &sequence
            )
            .await
            .unwrap(),
            1
        );
        drop(sender);
        let mut output = String::new();
        while let Some(event) = receiver.recv().await {
            output.push_str(&event.unwrap().message);
        }
        assert!(output.contains("verified"));
    }

    #[tokio::test]
    #[ignore = "requires AEGIZ_POSTGRES_FIXTURE_PORT and a disposable PostgreSQL server"]
    async fn native_postgres_fixture_query() {
        let port: u16 = std::env::var("AEGIZ_POSTGRES_FIXTURE_PORT")
            .expect("AEGIZ_POSTGRES_FIXTURE_PORT is required")
            .parse()
            .unwrap();
        let profile = fixture_profile(DatabaseEngine::Postgres, port, "postgres", "postgres");
        let output = fixture_query_output(
            &profile,
            "SELECT 'verified' AS aegiz_fixture",
            b"aegiz-fixture",
        )
        .await;
        assert!(output.contains("verified"));
    }

    #[tokio::test]
    #[ignore = "requires AEGIZ_MYSQL_FIXTURE_PORT and a disposable MySQL server"]
    async fn native_mysql_fixture_query() {
        let port: u16 = std::env::var("AEGIZ_MYSQL_FIXTURE_PORT")
            .expect("AEGIZ_MYSQL_FIXTURE_PORT is required")
            .parse()
            .unwrap();
        let profile = fixture_profile(DatabaseEngine::MySql, port, "root", "mysql");
        let output = fixture_query_output(
            &profile,
            "SELECT 'verified' AS aegiz_fixture",
            b"aegiz-fixture",
        )
        .await;
        assert!(output.contains("verified"));
    }

    fn fixture_profile(
        engine: DatabaseEngine,
        port: u16,
        username: &str,
        database_name: &str,
    ) -> DatabaseProfile {
        let now = chrono::Utc::now();
        DatabaseProfile {
            id: Uuid::new_v4(),
            label: "Disposable database".into(),
            engine,
            hostname: "127.0.0.1".into(),
            port,
            database_name: database_name.into(),
            username: username.into(),
            secret_reference: None,
            tunnel_id: None,
            auto_start_tunnel: false,
            read_only: true,
            created_at: now,
            updated_at: now,
        }
    }

    async fn fixture_query_output(profile: &DatabaseProfile, sql: &str, secret: &[u8]) -> String {
        let operation = Uuid::new_v4();
        let sequence = AtomicU64::new(1);
        let (sender, mut receiver) = mpsc::channel(32);
        assert_eq!(
            run_query(
                profile, sql, secret, true, true, operation, &sender, &sequence
            )
            .await
            .unwrap(),
            1
        );
        drop(sender);
        let mut output = String::new();
        while let Some(event) = receiver.recv().await {
            output.push_str(&event.unwrap().message);
        }
        output
    }
}
