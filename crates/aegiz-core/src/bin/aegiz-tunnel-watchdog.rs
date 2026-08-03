use std::{
    env,
    io::{self, Read},
    process::{Child, Command, ExitCode, ExitStatus, Stdio},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::Duration,
};

const POLL_INTERVAL: Duration = Duration::from_millis(25);

fn main() -> ExitCode {
    match run() {
        Ok(code) => ExitCode::from(code),
        Err(error) => {
            eprintln!("Aegiz tunnel watchdog failed: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> io::Result<u8> {
    let arguments = env::args_os().skip(1).collect::<Vec<_>>();
    if arguments.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "missing OpenSSH arguments",
        ));
    }

    let mut child = Command::new("/usr/bin/ssh")
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()?;
    let stop_requested = monitor_parent_pipe();
    let outcome = supervise_child(&mut child, &stop_requested, POLL_INTERVAL)?;
    Ok(exit_code(outcome))
}

fn monitor_parent_pipe() -> Arc<AtomicBool> {
    let stop_requested = Arc::new(AtomicBool::new(false));
    let signal = stop_requested.clone();
    thread::spawn(move || {
        let mut input = io::stdin().lock();
        let mut byte = [0_u8; 1];
        let _ = input.read(&mut byte);
        signal.store(true, Ordering::Release);
    });
    stop_requested
}

fn supervise_child(
    child: &mut Child,
    stop_requested: &AtomicBool,
    poll_interval: Duration,
) -> io::Result<WatchdogOutcome> {
    loop {
        if let Some(status) = child.try_wait()? {
            return Ok(WatchdogOutcome::ChildExited(status));
        }
        if stop_requested.load(Ordering::Acquire) {
            let _ = child.kill();
            let _ = child.wait();
            return Ok(WatchdogOutcome::ParentDisconnected);
        }
        thread::sleep(poll_interval);
    }
}

enum WatchdogOutcome {
    ChildExited(ExitStatus),
    ParentDisconnected,
}

fn exit_code(outcome: WatchdogOutcome) -> u8 {
    match outcome {
        WatchdogOutcome::ParentDisconnected => 0,
        WatchdogOutcome::ChildExited(status) => status
            .code()
            .and_then(|code| u8::try_from(code).ok())
            .unwrap_or(1),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    #[test]
    fn parent_disconnect_terminates_the_supervised_process() {
        let mut child = Command::new("/bin/sleep").arg("30").spawn().unwrap();
        let pid = child.id();
        let stop_requested = AtomicBool::new(true);

        let outcome = supervise_child(&mut child, &stop_requested, Duration::ZERO).unwrap();

        assert!(matches!(outcome, WatchdogOutcome::ParentDisconnected));
        assert!(child.try_wait().unwrap().is_some());
        assert_ne!(pid, std::process::id());
    }

    #[test]
    fn child_exit_code_is_preserved() {
        let mut child = Command::new("/usr/bin/false").spawn().unwrap();
        let stop_requested = AtomicBool::new(false);

        let outcome = supervise_child(&mut child, &stop_requested, Duration::ZERO).unwrap();

        assert_eq!(exit_code(outcome), 1);
    }
}
