#![forbid(unsafe_code)]

use serde::{Deserialize, Serialize};
use std::{
    error::Error,
    fmt,
    future::Future,
    path::{Path, PathBuf},
    pin::Pin,
};
use thiserror::Error;
use zeroize::Zeroize;

pub const MAX_CREDENTIAL_BYTES: usize = 64 * 1024;
const WINDOWS_PIPE_PREFIX: &str = r"\\.\pipe\aegiz-";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum LocalTransportEndpoint {
    UnixSocket(PathBuf),
    WindowsNamedPipe(String),
}

impl LocalTransportEndpoint {
    pub fn unix_socket(path: PathBuf) -> Result<Self, LocalTransportError> {
        if !path.is_absolute() {
            return Err(LocalTransportError::UnixPathMustBeAbsolute);
        }
        if path.as_os_str().as_encoded_bytes().contains(&0) {
            return Err(LocalTransportError::InvalidControlCharacter);
        }
        if path.file_name().is_none() || path.parent().is_none_or(|parent| parent == Path::new("/"))
        {
            return Err(LocalTransportError::UnixPathNeedsPrivateParent);
        }
        Ok(Self::UnixSocket(path))
    }

    pub fn windows_named_pipe(scope: &str) -> Result<Self, LocalTransportError> {
        if scope.is_empty() || scope.len() > 120 {
            return Err(LocalTransportError::InvalidWindowsPipeScope);
        }
        if !scope
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        {
            return Err(LocalTransportError::InvalidWindowsPipeScope);
        }
        Ok(Self::WindowsNamedPipe(format!(
            "{WINDOWS_PIPE_PREFIX}{scope}"
        )))
    }

    pub fn unix_path(&self) -> Option<&Path> {
        match self {
            Self::UnixSocket(path) => Some(path),
            Self::WindowsNamedPipe(_) => None,
        }
    }

    pub fn windows_pipe_name(&self) -> Option<&str> {
        match self {
            Self::WindowsNamedPipe(name) => Some(name),
            Self::UnixSocket(_) => None,
        }
    }

    pub fn runtime_directory(&self) -> Option<&Path> {
        self.unix_path().and_then(Path::parent)
    }
}

#[derive(Debug, Error, Eq, PartialEq)]
pub enum LocalTransportError {
    #[error("Unix socket path must be absolute")]
    UnixPathMustBeAbsolute,
    #[error("Unix socket path needs an application-private parent directory")]
    UnixPathNeedsPrivateParent,
    #[error("local endpoint contains an unsupported control character")]
    InvalidControlCharacter,
    #[error(
        "Windows named-pipe scope must be 1-120 ASCII letters, digits, dots, dashes, or underscores"
    )]
    InvalidWindowsPipeScope,
}

pub type PlatformFuture<'a, T, E> = Pin<Box<dyn Future<Output = Result<T, E>> + Send + 'a>>;

pub trait LocalTransportProvider: Send + Sync {
    type Binding: Send;
    type Error: Error + Send + Sync + 'static;

    /// Bind a local-only endpoint with OS ACLs that restrict access to the
    /// interactive user that launched the Aegiz shell.
    fn bind(
        &self,
        endpoint: &LocalTransportEndpoint,
    ) -> PlatformFuture<'_, Self::Binding, Self::Error>;
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct CredentialReference {
    provider: String,
    identifier: String,
}

impl CredentialReference {
    pub fn new(provider: &str, identifier: &str) -> Result<Self, CredentialContractError> {
        validate_identifier("provider", provider, 64)?;
        validate_identifier("credential", identifier, 512)?;
        Ok(Self {
            provider: provider.to_owned(),
            identifier: identifier.to_owned(),
        })
    }

    pub fn provider(&self) -> &str {
        &self.provider
    }

    pub fn identifier(&self) -> &str {
        &self.identifier
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum CredentialAccessPolicy {
    LoginSession,
    UserPresence,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct CredentialMetadata {
    pub reference: CredentialReference,
    pub label: String,
    pub access_policy: CredentialAccessPolicy,
}

pub struct CredentialDraft {
    pub label: String,
    pub access_policy: CredentialAccessPolicy,
    pub secret: CredentialLease,
}

pub struct CredentialLease {
    bytes: Vec<u8>,
}

impl CredentialLease {
    pub fn new(bytes: Vec<u8>) -> Result<Self, CredentialContractError> {
        if bytes.len() > MAX_CREDENTIAL_BYTES {
            return Err(CredentialContractError::SecretTooLarge);
        }
        Ok(Self { bytes })
    }

    pub fn expose(&self) -> &[u8] {
        &self.bytes
    }

    pub fn is_empty(&self) -> bool {
        self.bytes.is_empty()
    }

    pub fn len(&self) -> usize {
        self.bytes.len()
    }
}

impl fmt::Debug for CredentialLease {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CredentialLease")
            .field("bytes", &"[REDACTED]")
            .field("len", &self.bytes.len())
            .finish()
    }
}

impl Drop for CredentialLease {
    fn drop(&mut self) {
        self.bytes.zeroize();
    }
}

#[derive(Debug, Error, Eq, PartialEq)]
pub enum CredentialContractError {
    #[error("{0} identifier is invalid")]
    InvalidIdentifier(&'static str),
    #[error("credential exceeds the 64 KiB safety limit")]
    SecretTooLarge,
}

pub trait CredentialProvider: Send + Sync {
    type Error: Error + Send + Sync + 'static;

    fn list(&self) -> PlatformFuture<'_, Vec<CredentialMetadata>, Self::Error>;
    fn save(
        &self,
        existing: Option<&CredentialReference>,
        draft: CredentialDraft,
    ) -> PlatformFuture<'_, CredentialMetadata, Self::Error>;
    fn resolve(
        &self,
        reference: &CredentialReference,
        reason: &str,
    ) -> PlatformFuture<'_, CredentialLease, Self::Error>;
    fn delete(&self, reference: &CredentialReference) -> PlatformFuture<'_, (), Self::Error>;
}

fn validate_identifier(
    field: &'static str,
    value: &str,
    maximum: usize,
) -> Result<(), CredentialContractError> {
    if value.is_empty()
        || value.len() > maximum
        || value
            .bytes()
            .any(|byte| byte == 0 || byte == b'\n' || byte == b'\r')
    {
        return Err(CredentialContractError::InvalidIdentifier(field));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{collections::HashMap, sync::Mutex};

    #[cfg(unix)]
    #[test]
    fn unix_endpoints_require_an_absolute_path_with_a_private_parent() {
        let unix =
            LocalTransportEndpoint::unix_socket(PathBuf::from("/tmp/aegiz-fixture/core.sock"))
                .unwrap();
        assert_eq!(
            unix.runtime_directory(),
            Some(Path::new("/tmp/aegiz-fixture"))
        );
        assert!(LocalTransportEndpoint::unix_socket(PathBuf::from("core.sock")).is_err());
        assert!(LocalTransportEndpoint::unix_socket(PathBuf::from("/core.sock")).is_err());
    }

    #[test]
    fn windows_named_pipe_endpoints_use_a_local_canonical_namespace() {
        let pipe = LocalTransportEndpoint::windows_named_pipe("user_123.session-1").unwrap();
        assert_eq!(
            pipe.windows_pipe_name(),
            Some(r"\\.\pipe\aegiz-user_123.session-1")
        );
        assert!(LocalTransportEndpoint::windows_named_pipe(r"..\remote").is_err());
    }

    #[test]
    fn credential_lease_is_bounded_non_cloneable_and_redacted_in_debug() {
        let lease = CredentialLease::new(b"fixture-secret".to_vec()).unwrap();
        assert_eq!(lease.expose(), b"fixture-secret");
        assert!(!format!("{lease:?}").contains("fixture-secret"));
        assert_eq!(lease.len(), "fixture-secret".len());
        assert!(CredentialLease::new(vec![0; MAX_CREDENTIAL_BYTES + 1]).is_err());
    }

    #[derive(Debug, Error)]
    #[error("fixture credential was not found")]
    struct FixtureError;

    #[derive(Default)]
    struct FixtureProvider {
        values: Mutex<HashMap<String, Vec<u8>>>,
    }

    impl CredentialProvider for FixtureProvider {
        type Error = FixtureError;

        fn list(&self) -> PlatformFuture<'_, Vec<CredentialMetadata>, Self::Error> {
            let values = self.values.lock().unwrap();
            let metadata = values
                .keys()
                .map(|identifier| CredentialMetadata {
                    reference: CredentialReference::new("fixture", identifier).unwrap(),
                    label: identifier.clone(),
                    access_policy: CredentialAccessPolicy::LoginSession,
                })
                .collect();
            Box::pin(async move { Ok(metadata) })
        }

        fn save(
            &self,
            existing: Option<&CredentialReference>,
            draft: CredentialDraft,
        ) -> PlatformFuture<'_, CredentialMetadata, Self::Error> {
            let identifier = existing
                .map(|reference| reference.identifier().to_owned())
                .unwrap_or_else(|| "generated-fixture".to_owned());
            self.values
                .lock()
                .unwrap()
                .insert(identifier.clone(), draft.secret.expose().to_vec());
            let metadata = CredentialMetadata {
                reference: CredentialReference::new("fixture", &identifier).unwrap(),
                label: draft.label,
                access_policy: draft.access_policy,
            };
            Box::pin(async move { Ok(metadata) })
        }

        fn resolve(
            &self,
            reference: &CredentialReference,
            _reason: &str,
        ) -> PlatformFuture<'_, CredentialLease, Self::Error> {
            let value = self
                .values
                .lock()
                .unwrap()
                .get(reference.identifier())
                .cloned();
            Box::pin(async move {
                value
                    .map(|bytes| CredentialLease::new(bytes).unwrap())
                    .ok_or(FixtureError)
            })
        }

        fn delete(&self, reference: &CredentialReference) -> PlatformFuture<'_, (), Self::Error> {
            let removed = self
                .values
                .lock()
                .unwrap()
                .remove(reference.identifier())
                .is_some();
            Box::pin(async move { removed.then_some(()).ok_or(FixtureError) })
        }
    }

    #[tokio::test]
    async fn credential_provider_contract_round_trips_only_leases() {
        let provider = FixtureProvider::default();
        let draft = CredentialDraft {
            label: "Fixture".into(),
            access_policy: CredentialAccessPolicy::UserPresence,
            secret: CredentialLease::new(b"temporary-value".to_vec()).unwrap(),
        };
        let metadata = provider.save(None, draft).await.unwrap();
        assert_eq!(metadata.access_policy, CredentialAccessPolicy::UserPresence);
        assert_eq!(provider.list().await.unwrap().len(), 1);
        let lease = provider
            .resolve(&metadata.reference, "Fixture verification")
            .await
            .unwrap();
        assert_eq!(lease.expose(), b"temporary-value");
        provider.delete(&metadata.reference).await.unwrap();
        assert!(provider.list().await.unwrap().is_empty());
    }
}
