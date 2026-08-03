use aegiz_platform::{LocalTransportEndpoint, LocalTransportProvider, PlatformFuture};
use std::os::unix::fs::PermissionsExt;
use tokio::net::UnixListener;

pub struct UnixTransportProvider;

impl LocalTransportProvider for UnixTransportProvider {
    type Binding = UnixListener;
    type Error = std::io::Error;

    fn bind(
        &self,
        endpoint: &LocalTransportEndpoint,
    ) -> PlatformFuture<'_, Self::Binding, Self::Error> {
        let socket_path = endpoint.unix_path().map(ToOwned::to_owned);
        Box::pin(async move {
            let socket_path = socket_path.ok_or_else(|| {
                std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    "Unix transport provider requires a Unix socket endpoint",
                )
            })?;
            let runtime_directory = socket_path.parent().ok_or_else(|| {
                std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    "Unix socket requires a private parent directory",
                )
            })?;
            tokio::fs::create_dir_all(runtime_directory).await?;
            tokio::fs::set_permissions(runtime_directory, std::fs::Permissions::from_mode(0o700))
                .await?;
            if socket_path.exists() {
                tokio::fs::remove_file(&socket_path).await?;
            }
            let listener = UnixListener::bind(&socket_path)?;
            tokio::fs::set_permissions(&socket_path, std::fs::Permissions::from_mode(0o600))
                .await?;
            Ok(listener)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use uuid::Uuid;

    #[tokio::test]
    async fn unix_provider_creates_an_owner_only_binding() {
        let identifier = Uuid::new_v4().simple().to_string();
        let root = PathBuf::from("/tmp").join(format!("az-transport-{}", &identifier[..8]));
        let socket = root.join("core.sock");
        let endpoint = LocalTransportEndpoint::unix_socket(socket.clone()).unwrap();
        let listener = UnixTransportProvider.bind(&endpoint).await.unwrap();

        assert_eq!(
            tokio::fs::metadata(&root)
                .await
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        assert_eq!(
            tokio::fs::metadata(&socket)
                .await
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );

        drop(listener);
        tokio::fs::remove_file(socket).await.unwrap();
        tokio::fs::remove_dir(root).await.unwrap();
    }
}
