#![forbid(unsafe_code)]

use aegiz_platform::{
    CredentialAccessPolicy, CredentialContractError, CredentialDraft, CredentialLease,
    CredentialMetadata, CredentialProvider, CredentialReference, PlatformFuture,
};
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    sync::Arc,
};
use thiserror::Error;
use uuid::Uuid;

const CATALOG_VERSION: u32 = 1;
const PROVIDER_ID: &str = "native-os";
const SERVICE_NAME: &str = "dev.aegiz.desktop.cross-platform";
const MAX_LABEL_BYTES: usize = 256;
const MAX_REASON_BYTES: usize = 512;

#[derive(Debug, Error)]
pub enum NativeCredentialError {
    #[error("credential reference is not owned by the native OS provider")]
    ForeignReference,
    #[error("credential was not found")]
    NotFound,
    #[error("credential label must be 1-256 bytes without control characters")]
    InvalidLabel,
    #[error("credential access reason must be 1-512 bytes without control characters")]
    InvalidReason,
    #[error("this OS credential backend cannot enforce per-read user presence")]
    UnsupportedAccessPolicy,
    #[error("credential metadata catalog path must be absolute")]
    CatalogPathMustBeAbsolute,
    #[error("credential metadata catalog has insecure permissions")]
    InsecureCatalogPermissions,
    #[error("credential metadata catalog is invalid")]
    InvalidCatalog,
    #[error("credential metadata catalog operation failed: {0}")]
    CatalogIo(#[from] std::io::Error),
    #[error("native credential store is unavailable")]
    StoreUnavailable,
    #[error("credential contract rejected the operation: {0}")]
    Contract(#[from] CredentialContractError),
    #[error("credential worker stopped before completing")]
    WorkerStopped,
}

#[derive(Clone)]
pub struct NativeCredentialProvider {
    catalog_path: PathBuf,
    store: Arc<dyn SecretStore>,
}

impl NativeCredentialProvider {
    pub fn new(catalog_path: PathBuf) -> Result<Self, NativeCredentialError> {
        if !catalog_path.is_absolute() {
            return Err(NativeCredentialError::CatalogPathMustBeAbsolute);
        }
        Ok(Self {
            catalog_path,
            store: Arc::new(KeyringSecretStore),
        })
    }

    pub fn provider_id(&self) -> &'static str {
        PROVIDER_ID
    }

    fn validate_reference(
        &self,
        reference: &CredentialReference,
    ) -> Result<(), NativeCredentialError> {
        if reference.provider() != PROVIDER_ID {
            return Err(NativeCredentialError::ForeignReference);
        }
        Ok(())
    }

    #[cfg(test)]
    fn with_store(catalog_path: PathBuf, store: Arc<dyn SecretStore>) -> Self {
        Self {
            catalog_path,
            store,
        }
    }
}

impl CredentialProvider for NativeCredentialProvider {
    type Error = NativeCredentialError;

    fn list(&self) -> PlatformFuture<'_, Vec<CredentialMetadata>, Self::Error> {
        let path = self.catalog_path.clone();
        Box::pin(async move {
            tokio::task::spawn_blocking(move || {
                let mut entries = read_catalog(&path)?.entries;
                entries.sort_by(|left, right| {
                    left.label
                        .to_lowercase()
                        .cmp(&right.label.to_lowercase())
                        .then_with(|| {
                            left.reference
                                .identifier()
                                .cmp(right.reference.identifier())
                        })
                });
                Ok(entries)
            })
            .await
            .map_err(|_| NativeCredentialError::WorkerStopped)?
        })
    }

    fn save(
        &self,
        existing: Option<&CredentialReference>,
        draft: CredentialDraft,
    ) -> PlatformFuture<'_, CredentialMetadata, Self::Error> {
        let existing = existing.cloned();
        let path = self.catalog_path.clone();
        let store = self.store.clone();
        Box::pin(async move {
            validate_label(&draft.label)?;
            if draft.access_policy != CredentialAccessPolicy::LoginSession {
                return Err(NativeCredentialError::UnsupportedAccessPolicy);
            }
            if existing
                .as_ref()
                .is_some_and(|reference| reference.provider() != PROVIDER_ID)
            {
                return Err(NativeCredentialError::ForeignReference);
            }

            tokio::task::spawn_blocking(move || {
                let mut catalog = read_catalog(&path)?;
                let identifier = existing
                    .as_ref()
                    .map(|reference| reference.identifier().to_owned())
                    .unwrap_or_else(|| Uuid::new_v4().simple().to_string());
                let previous_index = catalog
                    .entries
                    .iter()
                    .position(|entry| entry.reference.identifier() == identifier);
                if existing.is_some() && previous_index.is_none() {
                    return Err(NativeCredentialError::NotFound);
                }

                let previous_secret = if previous_index.is_some() {
                    Some(CredentialLease::new(store.get(&identifier)?)?)
                } else {
                    None
                };
                store.set(&identifier, draft.secret.expose())?;

                let metadata = CredentialMetadata {
                    reference: CredentialReference::new(PROVIDER_ID, &identifier)?,
                    label: draft.label,
                    access_policy: draft.access_policy,
                };
                if let Some(index) = previous_index {
                    catalog.entries[index] = metadata.clone();
                } else {
                    catalog.entries.push(metadata.clone());
                }

                if let Err(error) = write_catalog(&path, &catalog) {
                    if let Some(previous_secret) = previous_secret {
                        let _ = store.set(&identifier, previous_secret.expose());
                    } else {
                        let _ = store.delete(&identifier);
                    }
                    return Err(error);
                }
                Ok(metadata)
            })
            .await
            .map_err(|_| NativeCredentialError::WorkerStopped)?
        })
    }

    fn resolve(
        &self,
        reference: &CredentialReference,
        reason: &str,
    ) -> PlatformFuture<'_, CredentialLease, Self::Error> {
        let validation = self
            .validate_reference(reference)
            .and_then(|()| validate_reason(reason));
        let identifier = reference.identifier().to_owned();
        let store = self.store.clone();
        Box::pin(async move {
            validation?;
            tokio::task::spawn_blocking(move || {
                let secret = store.get(&identifier)?;
                CredentialLease::new(secret).map_err(NativeCredentialError::from)
            })
            .await
            .map_err(|_| NativeCredentialError::WorkerStopped)?
        })
    }

    fn delete(&self, reference: &CredentialReference) -> PlatformFuture<'_, (), Self::Error> {
        let validation = self.validate_reference(reference);
        let identifier = reference.identifier().to_owned();
        let path = self.catalog_path.clone();
        let store = self.store.clone();
        Box::pin(async move {
            validation?;
            tokio::task::spawn_blocking(move || {
                let mut catalog = read_catalog(&path)?;
                let index = catalog
                    .entries
                    .iter()
                    .position(|entry| entry.reference.identifier() == identifier)
                    .ok_or(NativeCredentialError::NotFound)?;
                let previous_secret = CredentialLease::new(store.get(&identifier)?)?;
                store.delete(&identifier)?;
                catalog.entries.remove(index);
                if let Err(error) = write_catalog(&path, &catalog) {
                    let _ = store.set(&identifier, previous_secret.expose());
                    return Err(error);
                }
                Ok(())
            })
            .await
            .map_err(|_| NativeCredentialError::WorkerStopped)?
        })
    }
}

#[derive(Default, Deserialize, Serialize)]
struct CredentialCatalog {
    version: u32,
    entries: Vec<CredentialMetadata>,
}

fn read_catalog(path: &Path) -> Result<CredentialCatalog, NativeCredentialError> {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(CredentialCatalog {
                version: CATALOG_VERSION,
                entries: Vec::new(),
            });
        }
        Err(error) => return Err(error.into()),
    };
    verify_private_permissions(path)?;
    let catalog: CredentialCatalog =
        serde_json::from_slice(&bytes).map_err(|_| NativeCredentialError::InvalidCatalog)?;
    if catalog.version != CATALOG_VERSION
        || catalog
            .entries
            .iter()
            .any(|entry| entry.reference.provider() != PROVIDER_ID)
    {
        return Err(NativeCredentialError::InvalidCatalog);
    }
    Ok(catalog)
}

fn write_catalog(path: &Path, catalog: &CredentialCatalog) -> Result<(), NativeCredentialError> {
    let parent = path
        .parent()
        .ok_or(NativeCredentialError::CatalogPathMustBeAbsolute)?;
    fs::create_dir_all(parent)?;
    set_private_directory_permissions(parent)?;
    let temporary = parent.join(format!(
        ".{}.{}.tmp",
        path.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("credentials"),
        Uuid::new_v4().simple()
    ));
    let bytes =
        serde_json::to_vec_pretty(catalog).map_err(|_| NativeCredentialError::InvalidCatalog)?;
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    configure_private_file_creation(&mut options);
    let result = (|| {
        let mut file = options.open(&temporary)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        replace_file(&temporary, path)?;
        verify_private_permissions(path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

#[cfg(unix)]
fn configure_private_file_creation(options: &mut OpenOptions) {
    use std::os::unix::fs::OpenOptionsExt;
    options.mode(0o600);
}

#[cfg(not(unix))]
fn configure_private_file_creation(_options: &mut OpenOptions) {}

#[cfg(unix)]
fn set_private_directory_permissions(path: &Path) -> Result<(), NativeCredentialError> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}

#[cfg(not(unix))]
fn set_private_directory_permissions(_path: &Path) -> Result<(), NativeCredentialError> {
    Ok(())
}

#[cfg(unix)]
fn verify_private_permissions(path: &Path) -> Result<(), NativeCredentialError> {
    use std::os::unix::fs::PermissionsExt;
    if fs::metadata(path)?.permissions().mode() & 0o077 != 0 {
        return Err(NativeCredentialError::InsecureCatalogPermissions);
    }
    Ok(())
}

#[cfg(not(unix))]
fn verify_private_permissions(_path: &Path) -> Result<(), NativeCredentialError> {
    Ok(())
}

#[cfg(unix)]
fn replace_file(temporary: &Path, destination: &Path) -> Result<(), std::io::Error> {
    fs::rename(temporary, destination)
}

#[cfg(not(unix))]
fn replace_file(temporary: &Path, destination: &Path) -> Result<(), std::io::Error> {
    if destination.exists() {
        let backup = destination.with_extension("aegiz-backup");
        let _ = fs::remove_file(&backup);
        fs::rename(destination, &backup)?;
        if let Err(error) = fs::rename(temporary, destination) {
            let _ = fs::rename(&backup, destination);
            return Err(error);
        }
        let _ = fs::remove_file(backup);
        Ok(())
    } else {
        fs::rename(temporary, destination)
    }
}

fn validate_label(label: &str) -> Result<(), NativeCredentialError> {
    if label.is_empty() || label.len() > MAX_LABEL_BYTES || label.chars().any(char::is_control) {
        return Err(NativeCredentialError::InvalidLabel);
    }
    Ok(())
}

fn validate_reason(reason: &str) -> Result<(), NativeCredentialError> {
    if reason.is_empty() || reason.len() > MAX_REASON_BYTES || reason.chars().any(char::is_control)
    {
        return Err(NativeCredentialError::InvalidReason);
    }
    Ok(())
}

trait SecretStore: Send + Sync {
    fn set(&self, identifier: &str, secret: &[u8]) -> Result<(), NativeCredentialError>;
    fn get(&self, identifier: &str) -> Result<Vec<u8>, NativeCredentialError>;
    fn delete(&self, identifier: &str) -> Result<(), NativeCredentialError>;
}

struct KeyringSecretStore;

impl KeyringSecretStore {
    fn entry(identifier: &str) -> Result<keyring::v1::Entry, NativeCredentialError> {
        keyring::v1::Entry::new(SERVICE_NAME, identifier)
            .map_err(|_| NativeCredentialError::StoreUnavailable)
    }
}

impl SecretStore for KeyringSecretStore {
    fn set(&self, identifier: &str, secret: &[u8]) -> Result<(), NativeCredentialError> {
        Self::entry(identifier)?
            .set_secret(secret)
            .map_err(map_keyring_error)
    }

    fn get(&self, identifier: &str) -> Result<Vec<u8>, NativeCredentialError> {
        Self::entry(identifier)?
            .get_secret()
            .map_err(map_keyring_error)
    }

    fn delete(&self, identifier: &str) -> Result<(), NativeCredentialError> {
        Self::entry(identifier)?
            .delete_credential()
            .map_err(map_keyring_error)
    }
}

fn map_keyring_error(error: keyring::v1::Error) -> NativeCredentialError {
    if matches!(error, keyring::v1::Error::NoEntry) {
        NativeCredentialError::NotFound
    } else {
        NativeCredentialError::StoreUnavailable
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{collections::HashMap, sync::Mutex};

    #[derive(Default)]
    struct MemoryStore(Mutex<HashMap<String, Vec<u8>>>);

    impl SecretStore for MemoryStore {
        fn set(&self, identifier: &str, secret: &[u8]) -> Result<(), NativeCredentialError> {
            self.0
                .lock()
                .unwrap()
                .insert(identifier.to_owned(), secret.to_vec());
            Ok(())
        }

        fn get(&self, identifier: &str) -> Result<Vec<u8>, NativeCredentialError> {
            self.0
                .lock()
                .unwrap()
                .get(identifier)
                .cloned()
                .ok_or(NativeCredentialError::NotFound)
        }

        fn delete(&self, identifier: &str) -> Result<(), NativeCredentialError> {
            self.0
                .lock()
                .unwrap()
                .remove(identifier)
                .map(|_| ())
                .ok_or(NativeCredentialError::NotFound)
        }
    }

    fn fixture() -> (PathBuf, NativeCredentialProvider, Arc<MemoryStore>) {
        let root = std::env::temp_dir().join(format!("aegiz-credential-{}", Uuid::new_v4()));
        let path = root.join("catalog.json");
        let store = Arc::new(MemoryStore::default());
        let provider = NativeCredentialProvider::with_store(path.clone(), store.clone());
        (path, provider, store)
    }

    #[tokio::test]
    async fn metadata_and_secret_lifecycles_remain_separate() {
        let (path, provider, store) = fixture();
        let saved = provider
            .save(
                None,
                CredentialDraft {
                    label: "Staging database".into(),
                    access_policy: CredentialAccessPolicy::LoginSession,
                    secret: CredentialLease::new(b"fixture-secret".to_vec()).unwrap(),
                },
            )
            .await
            .unwrap();

        let catalog = fs::read_to_string(&path).unwrap();
        assert!(!catalog.contains("fixture-secret"));
        assert_eq!(provider.list().await.unwrap(), vec![saved.clone()]);
        assert_eq!(
            provider
                .resolve(&saved.reference, "Connect to staging database")
                .await
                .unwrap()
                .expose(),
            b"fixture-secret"
        );

        let updated = provider
            .save(
                Some(&saved.reference),
                CredentialDraft {
                    label: "Staging DB password".into(),
                    access_policy: CredentialAccessPolicy::LoginSession,
                    secret: CredentialLease::new(b"rotated".to_vec()).unwrap(),
                },
            )
            .await
            .unwrap();
        assert_eq!(updated.reference, saved.reference);
        assert_eq!(
            provider
                .resolve(&updated.reference, "Connect to staging database")
                .await
                .unwrap()
                .expose(),
            b"rotated"
        );

        provider.delete(&updated.reference).await.unwrap();
        assert!(provider.list().await.unwrap().is_empty());
        assert!(store.0.lock().unwrap().is_empty());
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[tokio::test]
    async fn unsupported_user_presence_is_never_silently_downgraded() {
        let (path, provider, _) = fixture();
        let error = provider
            .save(
                None,
                CredentialDraft {
                    label: "Protected".into(),
                    access_policy: CredentialAccessPolicy::UserPresence,
                    secret: CredentialLease::new(vec![1]).unwrap(),
                },
            )
            .await
            .unwrap_err();
        assert!(matches!(
            error,
            NativeCredentialError::UnsupportedAccessPolicy
        ));
        assert!(!path.exists());
    }

    #[tokio::test]
    async fn foreign_references_and_unbounded_reasons_are_rejected() {
        let (path, provider, _) = fixture();
        let reference = CredentialReference::new("another-provider", "id").unwrap();
        assert!(matches!(
            provider.resolve(&reference, "Use credential").await,
            Err(NativeCredentialError::ForeignReference)
        ));
        let own = CredentialReference::new(PROVIDER_ID, "missing").unwrap();
        assert!(matches!(
            provider.resolve(&own, "").await,
            Err(NativeCredentialError::InvalidReason)
        ));
        assert!(!path.exists());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn catalog_is_owner_only_and_insecure_existing_files_fail_closed() {
        use std::os::unix::fs::PermissionsExt;

        let (path, provider, _) = fixture();
        provider
            .save(
                None,
                CredentialDraft {
                    label: "Fixture".into(),
                    access_policy: CredentialAccessPolicy::LoginSession,
                    secret: CredentialLease::new(vec![1]).unwrap(),
                },
            )
            .await
            .unwrap();
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            fs::metadata(path.parent().unwrap())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(matches!(
            provider.list().await,
            Err(NativeCredentialError::InsecureCatalogPermissions)
        ));
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }
}
