#![cfg(unix)]

use std::{process::Stdio, time::Duration};
use tokio::{
    io::AsyncWriteExt,
    process::Command,
    time::{sleep, timeout},
};
use uuid::Uuid;

#[tokio::test]
async fn parent_pipe_eof_stops_core_and_removes_its_private_socket() {
    let identifier = Uuid::new_v4().simple().to_string();
    let root = std::path::PathBuf::from("/tmp").join(format!("az-core-{}", &identifier[..8]));
    let socket = root.join("core.sock");
    let database = root.join("inventory.sqlite");
    let mut core = Command::new(env!("CARGO_BIN_EXE_aegiz-core"))
        .arg("--socket")
        .arg(&socket)
        .arg("--database")
        .arg(&database)
        .arg("--session-stdin")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let mut parent_pipe = core.stdin.take().unwrap();
    parent_pipe
        .write_all(format!("{}\n", "a".repeat(64)).as_bytes())
        .await
        .unwrap();
    parent_pipe.flush().await.unwrap();

    timeout(Duration::from_secs(3), async {
        while !socket.exists() {
            sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("core should create its private RPC socket");

    drop(parent_pipe);
    let status = timeout(Duration::from_secs(3), core.wait())
        .await
        .expect("core should stop promptly when the app parent pipe closes")
        .unwrap();

    assert!(status.success());
    assert!(!socket.exists());
    tokio::fs::remove_dir_all(root).await.unwrap();
}
