mod application {
    pub mod adapters;
    pub mod databases;
    pub mod tunnels;
}

mod infrastructure {
    pub mod ssh_config;
    pub mod transport;
}

mod interfaces {
    pub mod rpc;
}

pub mod proto {
    tonic::include_proto!("aegiz.v1");
}

use aegiz_platform::{LocalTransportEndpoint, LocalTransportProvider};
use aegiz_storage::Store;
use anyhow::{Context, Result, bail};
use application::{adapters::AdapterRuntime, databases::DatabaseRuntime, tunnels::TunnelManager};
use clap::Parser;
use std::{
    io::{self, BufRead},
    path::PathBuf,
};
use tokio::io::AsyncReadExt;
use tokio_stream::wrappers::UnixListenerStream;
use tracing_subscriber::EnvFilter;

#[derive(Debug, Parser)]
#[command(name = "aegiz-core", about = "Local Aegiz control process")]
struct Arguments {
    #[arg(long)]
    socket: PathBuf,
    #[arg(long)]
    database: PathBuf,
    #[arg(long, default_value_t = false)]
    session_stdin: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("aegiz_core=info")),
        )
        .with_target(false)
        .compact()
        .init();

    let arguments = Arguments::parse();
    if !arguments.session_stdin {
        bail!("the core must be launched with --session-stdin");
    }
    let session = read_session()?;
    if session.len() != 64 || !session.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        bail!("invalid bootstrap session");
    }

    let endpoint = LocalTransportEndpoint::unix_socket(arguments.socket.clone())?;
    let socket_path = endpoint
        .unix_path()
        .context("this core build requires a Unix local transport")?;
    let runtime_directory = endpoint
        .runtime_directory()
        .context("Aegiz socket needs a private parent directory")?;
    let listener = infrastructure::transport::UnixTransportProvider
        .bind(&endpoint)
        .await
        .with_context(|| format!("could not bind {}", socket_path.display()))?;

    let store = Store::open(&arguments.database).await?;
    let recovered_tunnels = store.recover_transient_tunnel_statuses().await?;
    if recovered_tunnels > 0 {
        tracing::warn!(
            recovered_tunnels,
            "reconciled transient tunnel states from the previous core instance"
        );
    }
    let manager = TunnelManager::new(store.clone(), runtime_directory.to_path_buf());
    let adapters = AdapterRuntime::new(store.clone());
    let databases = DatabaseRuntime::new(store.clone(), manager.clone());
    let core_service =
        proto::aegiz_core_server::AegizCoreServer::new(interfaces::rpc::CoreService::new(
            store,
            manager.clone(),
            adapters.clone(),
            databases.clone(),
        ))
        .max_decoding_message_size(64 * 1024 * 1024)
        .max_encoding_message_size(64 * 1024 * 1024);
    let service = tonic::service::interceptor::InterceptedService::new(
        core_service,
        interfaces::rpc::SessionAuth::new(session),
    );
    tracing::info!(socket = %socket_path.display(), "Aegiz core ready");

    tonic::transport::Server::builder()
        .add_service(service)
        .serve_with_incoming_shutdown(UnixListenerStream::new(listener), shutdown_signal())
        .await?;

    adapters.cancel_all().await;
    databases.cancel_all().await;
    manager.stop_all().await;
    let _ = tokio::fs::remove_file(socket_path).await;
    Ok(())
}

async fn shutdown_signal() {
    let mut parent_pipe = tokio::io::stdin();
    let mut byte = [0_u8; 1];
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {}
        _ = parent_pipe.read(&mut byte) => {}
    }
}

fn read_session() -> Result<String> {
    let mut value = String::new();
    io::stdin()
        .lock()
        .read_line(&mut value)
        .context("could not read bootstrap session")?;
    Ok(value.trim().to_owned())
}
