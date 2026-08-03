#![cfg(unix)]

use std::{process::Stdio, time::Duration};
use tokio::{io::AsyncWriteExt, net::TcpListener, process::Command, time::timeout};

#[tokio::test]
async fn parent_pipe_eof_removes_the_real_openssh_child() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let mut watchdog = Command::new(env!("CARGO_BIN_EXE_aegiz-tunnel-watchdog"))
        .args([
            "-F",
            "/dev/null",
            "-N",
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-o",
            "ConnectTimeout=10",
            "-p",
            &port.to_string(),
            "127.0.0.1",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let watchdog_pid = watchdog.id().unwrap();
    let (mut connection, _) = timeout(Duration::from_secs(2), listener.accept())
        .await
        .expect("OpenSSH should connect only to the disposable loopback fixture")
        .unwrap();
    connection
        .write_all(b"SSH-2.0-AegizLifecycleFixture\r\n")
        .await
        .unwrap();
    let ssh_pid = wait_for_child_pid(watchdog_pid).await;

    drop(watchdog.stdin.take());
    let status = timeout(Duration::from_secs(2), watchdog.wait())
        .await
        .expect("watchdog should stop promptly when its parent pipe closes")
        .unwrap();

    assert!(status.success());
    assert!(
        wait_until_process_is_gone(ssh_pid).await,
        "OpenSSH child {ssh_pid} survived its watchdog"
    );
}

async fn wait_for_child_pid(parent_pid: u32) -> u32 {
    timeout(Duration::from_secs(2), async move {
        loop {
            if let Some(pid) = child_pid(parent_pid).await {
                break pid;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("watchdog should have one OpenSSH child")
}

async fn child_pid(parent_pid: u32) -> Option<u32> {
    let output = Command::new("/bin/ps")
        .args(["-axo", "pid=,ppid="])
        .output()
        .await
        .ok()?;
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(parse_process_row)
        .find_map(|(pid, parent)| (parent == parent_pid).then_some(pid))
}

fn parse_process_row(row: &str) -> Option<(u32, u32)> {
    let mut fields = row.split_whitespace();
    Some((fields.next()?.parse().ok()?, fields.next()?.parse().ok()?))
}

async fn wait_until_process_is_gone(pid: u32) -> bool {
    timeout(Duration::from_secs(1), async move {
        loop {
            if !process_exists(pid).await {
                break true;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap_or(false)
}

async fn process_exists(pid: u32) -> bool {
    Command::new("/bin/ps")
        .args(["-p", &pid.to_string(), "-o", "pid="])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .await
        .is_ok_and(|status| status.success())
}
