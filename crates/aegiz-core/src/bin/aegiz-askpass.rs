use std::{
    env,
    io::{Read, Write},
    os::unix::net::UnixStream,
};
use zeroize::Zeroize;

const MAX_SECRET_BYTES: u64 = 64 * 1024;

fn main() {
    if run().is_err() {
        std::process::exit(1);
    }
}

fn run() -> std::io::Result<()> {
    let socket = env::var_os("AEGIZ_ASKPASS_SOCKET").ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::InvalidInput, "missing broker socket")
    })?;
    let mut token = env::var("AEGIZ_ASKPASS_TOKEN")
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidInput, "missing token"))?;
    if token.len() != 36 || !token.is_ascii() {
        token.zeroize();
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "invalid token",
        ));
    }

    let mut stream = UnixStream::connect(socket)?;
    stream.write_all(token.as_bytes())?;
    token.zeroize();
    stream.shutdown(std::net::Shutdown::Write)?;

    let mut secret = Vec::new();
    stream.take(MAX_SECRET_BYTES + 1).read_to_end(&mut secret)?;
    if secret.is_empty() || secret.len() as u64 > MAX_SECRET_BYTES {
        secret.zeroize();
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "invalid secret response",
        ));
    }

    let mut output = std::io::stdout().lock();
    output.write_all(&secret)?;
    output.write_all(b"\n")?;
    output.flush()?;
    secret.zeroize();
    Ok(())
}
