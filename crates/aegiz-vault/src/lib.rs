use aes_gcm::{
    Aes256Gcm, KeyInit, Nonce,
    aead::{Aead, Payload},
};
use rand::Rng;
use thiserror::Error;
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

const FORMAT_VERSION: u8 = 1;
const NONCE_LEN: usize = 12;

#[derive(Zeroize, ZeroizeOnDrop)]
pub struct VaultKey([u8; 32]);

impl VaultKey {
    pub fn new(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }
}

#[derive(Debug, Error)]
pub enum VaultError {
    #[error("encrypted value has an unsupported or truncated format")]
    InvalidFormat,
    #[error("encrypted value failed authentication")]
    AuthenticationFailed,
}

pub fn seal(key: &VaultKey, context: &[u8], plaintext: &[u8]) -> Result<Vec<u8>, VaultError> {
    let cipher = Aes256Gcm::new_from_slice(&key.0).expect("AES-256 key length is fixed");
    let nonce_bytes: [u8; NONCE_LEN] = rand::rng().random();
    let ciphertext = cipher
        .encrypt(
            Nonce::from_slice(&nonce_bytes),
            Payload {
                msg: plaintext,
                aad: context,
            },
        )
        .map_err(|_| VaultError::AuthenticationFailed)?;

    let mut output = Vec::with_capacity(1 + NONCE_LEN + ciphertext.len());
    output.push(FORMAT_VERSION);
    output.extend_from_slice(&nonce_bytes);
    output.extend_from_slice(&ciphertext);
    Ok(output)
}

pub fn open(key: &VaultKey, context: &[u8], blob: &[u8]) -> Result<Zeroizing<Vec<u8>>, VaultError> {
    if blob.len() <= 1 + NONCE_LEN || blob[0] != FORMAT_VERSION {
        return Err(VaultError::InvalidFormat);
    }

    let cipher = Aes256Gcm::new_from_slice(&key.0).expect("AES-256 key length is fixed");
    cipher
        .decrypt(
            Nonce::from_slice(&blob[1..1 + NONCE_LEN]),
            Payload {
                msg: &blob[1 + NONCE_LEN..],
                aad: context,
            },
        )
        .map(Zeroizing::new)
        .map_err(|_| VaultError::AuthenticationFailed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_is_bound_to_context() {
        let key = VaultKey::new([7; 32]);
        let blob = seal(&key, b"database:prod", b"sensitive").unwrap();

        assert_eq!(
            open(&key, b"database:prod", &blob).unwrap().as_slice(),
            b"sensitive"
        );
        assert!(matches!(
            open(&key, b"database:staging", &blob),
            Err(VaultError::AuthenticationFailed)
        ));
    }

    #[test]
    fn tampering_is_rejected() {
        let key = VaultKey::new([9; 32]);
        let mut blob = seal(&key, b"host:key", b"private material").unwrap();
        let last = blob.len() - 1;
        blob[last] ^= 1;
        assert!(matches!(
            open(&key, b"host:key", &blob),
            Err(VaultError::AuthenticationFailed)
        ));
    }
}
