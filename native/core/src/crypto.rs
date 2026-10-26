use aes_gcm::{
    Aes256Gcm, KeyInit, Nonce,
    aead::{Aead, Payload},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use hkdf::Hkdf;
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

use crate::{Error, Result};

const MAX_BYTES: usize = 1024 * 1024;

#[derive(Clone, Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Identity {
    pub version: u32,
    pub vault_id: String,
    pub key: String,
    pub token: String,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Document {
    pub version: u32,
    pub vault_id: String,
    pub record_id: String,
    pub envelope: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sync: Option<crate::sync::Metadata>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RecoveryBundle {
    pub version: u32,
    pub vault_id: String,
    pub envelope: String,
}

// HAB1 recovery plaintext matches client/vault.mjs, independently of the
// native secure-storage identity representation.
#[derive(Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
#[serde(deny_unknown_fields)]
struct RecoveryIdentity {
    id: String,
    key: String,
    token: String,
}

pub fn random<const N: usize>() -> Result<[u8; N]> {
    let mut bytes = [0; N];
    getrandom::fill(&mut bytes).map_err(|_| Error::storage("Secure randomness is unavailable."))?;
    Ok(bytes)
}

pub fn id() -> Result<String> {
    let mut bytes = random::<16>()?;
    bytes[6] = bytes[6] & 0x0f | 0x40;
    bytes[8] = bytes[8] & 0x3f | 0x80;
    let hex = bytes
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    Ok(format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    ))
}

pub fn valid_id(id: &str) -> bool {
    id.len() == 36
        && id.bytes().enumerate().all(|(index, byte)| {
            if [8, 13, 18, 23].contains(&index) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
            }
        })
}

pub fn encode(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}

pub(crate) fn decode(value: &str) -> Result<Vec<u8>> {
    let bytes = URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| Error::invalid("Invalid encrypted data."))?;
    if encode(&bytes) != value {
        return Err(Error::invalid("Invalid encrypted data."));
    }
    Ok(bytes)
}

fn decode_key(value: &str) -> Result<Zeroizing<Vec<u8>>> {
    let bytes = Zeroizing::new(decode(value)?);
    if bytes.len() != 32 {
        return Err(Error::invalid("Invalid private encryption key."));
    }
    Ok(bytes)
}

impl Identity {
    pub fn create() -> Result<Self> {
        let key = Zeroizing::new(random::<32>()?);
        let token = Zeroizing::new(random::<32>()?);
        Ok(Self {
            version: 1,
            vault_id: id()?,
            key: encode(key.as_ref()),
            token: encode(token.as_ref()),
        })
    }

    pub fn validate(&self) -> Result<()> {
        if self.version != 1 || !valid_id(&self.vault_id) {
            return Err(Error::invalid("Unsupported vault identity."));
        }
        decode_key(&self.key)?;
        decode_key(&self.token)?;
        Ok(())
    }

    pub fn seal_document(&self, record_id: &str, plaintext: &[u8]) -> Result<Document> {
        self.validate()?;
        if !valid_id(record_id) {
            return Err(Error::invalid("Invalid record identity."));
        }
        let key = decode_key(&self.key)?;
        let context = format!("habibi/record/v1\0{}\0{record_id}", self.vault_id);
        Ok(Document {
            version: 1,
            vault_id: self.vault_id.clone(),
            record_id: record_id.to_owned(),
            envelope: encode(&seal(&key, context.as_bytes(), plaintext)?),
            sync: None,
        })
    }

    // A local-only keyed digest authenticates sync bookkeeping, including its
    // binding to the current encrypted local record. It is never transported.
    pub(crate) fn sync_tag(&self, data: &[u8]) -> Result<String> {
        let key = decode_key(&self.key)?;
        Ok(encode(
            derived_key(&key, b"habibi/local-sync/v1", data)?.as_ref(),
        ))
    }

    pub fn open_document(&self, document: &Document) -> Result<Zeroizing<Vec<u8>>> {
        self.validate()?;
        if document.version != 1
            || document.vault_id != self.vault_id
            || !valid_id(&document.record_id)
            || document.envelope.len() > MAX_BYTES.div_ceil(3) * 4
        {
            return Err(Error::invalid(
                "This encrypted record does not belong to this vault.",
            ));
        }
        let context = format!(
            "habibi/record/v1\0{}\0{}",
            self.vault_id, document.record_id
        );
        let key = decode_key(&self.key)?;
        open(&key, context.as_bytes(), &decode(&document.envelope)?)
    }

    pub fn recovery(&self) -> Result<(RecoveryBundle, String)> {
        self.validate()?;
        let key = Zeroizing::new(random::<32>()?);
        let saved = RecoveryIdentity {
            id: self.vault_id.clone(),
            key: self.key.clone(),
            token: self.token.clone(),
        };
        let plaintext = Zeroizing::new(serde_json::to_vec(&saved)?);
        let context = format!("habibi/recovery/v1\0{}", self.vault_id);
        Ok((
            RecoveryBundle {
                version: 1,
                vault_id: self.vault_id.clone(),
                envelope: encode(&seal(key.as_ref(), context.as_bytes(), &plaintext)?),
            },
            encode(key.as_ref()),
        ))
    }

    pub fn recover(bundle: &RecoveryBundle, recovery_key: &str) -> Result<Self> {
        if bundle.version != 1 || !valid_id(&bundle.vault_id) || bundle.envelope.len() > 4096 {
            return Err(Error::invalid("Unsupported recovery bundle."));
        }
        let key = decode_key(recovery_key)?;
        let context = format!("habibi/recovery/v1\0{}", bundle.vault_id);
        let plaintext = open(&key, context.as_bytes(), &decode(&bundle.envelope)?)?;
        let saved: RecoveryIdentity = serde_json::from_slice(&plaintext)?;
        let identity = Self {
            version: 1,
            vault_id: saved.id.clone(),
            key: saved.key.clone(),
            token: saved.token.clone(),
        };
        identity.validate()?;
        if identity.vault_id != bundle.vault_id {
            return Err(Error::invalid("Recovery vault mismatch."));
        }
        Ok(identity)
    }
}

fn derived_key(key: &[u8], salt: &[u8], context: &[u8]) -> Result<Zeroizing<[u8; 32]>> {
    let mut derived = Zeroizing::new([0; 32]);
    Hkdf::<Sha256>::new(Some(salt), key)
        .expand(context, derived.as_mut())
        .map_err(|_| Error::invalid("Invalid encryption context."))?;
    Ok(derived)
}

fn seal(key: &[u8], context: &[u8], plaintext: &[u8]) -> Result<Vec<u8>> {
    if plaintext.len() > MAX_BYTES - 64 {
        return Err(Error::invalid(
            "Your vault has reached its 1 MiB local limit.",
        ));
    }
    let salt = random::<32>()?;
    let nonce = random::<12>()?;
    let mut header = b"HAB1".to_vec();
    header.extend_from_slice(&salt);
    header.extend_from_slice(&nonce);
    let mut aad = header.clone();
    aad.extend_from_slice(context);
    let derived = derived_key(key, &salt, context)?;
    let cipher = Aes256Gcm::new_from_slice(derived.as_ref())
        .map_err(|_| Error::invalid("Invalid encryption key."))?;
    let encrypted = cipher
        .encrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: plaintext,
                aad: &aad,
            },
        )
        .map_err(|_| Error::storage("Could not encrypt your vault."))?;
    header.extend_from_slice(&encrypted);
    Ok(header)
}

fn open(key: &[u8], context: &[u8], envelope: &[u8]) -> Result<Zeroizing<Vec<u8>>> {
    if envelope.len() < 64 || envelope.len() > MAX_BYTES || &envelope[..4] != b"HAB1" {
        return Err(Error::invalid("Invalid encrypted record."));
    }
    let derived = derived_key(key, &envelope[4..36], context)?;
    let cipher = Aes256Gcm::new_from_slice(derived.as_ref())
        .map_err(|_| Error::invalid("Invalid encryption key."))?;
    let mut aad = envelope[..48].to_vec();
    aad.extend_from_slice(context);
    cipher
        .decrypt(
            Nonce::from_slice(&envelope[36..48]),
            Payload {
                msg: &envelope[48..],
                aad: &aad,
            },
        )
        .map(Zeroizing::new)
        .map_err(|_| {
            Error::invalid("Could not unlock this data. Check the backup and recovery key.")
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fresh_identity_and_authenticated_record_binding() {
        let identity = Identity::create().unwrap();
        let other = Identity::create().unwrap();
        assert_ne!(identity.key, identity.token);
        assert_ne!(identity.key, other.key);
        let record_id = id().unwrap();
        let document = identity
            .seal_document(&record_id, b"private workout")
            .unwrap();
        let second = identity
            .seal_document(&record_id, b"private workout")
            .unwrap();
        assert_ne!(document.envelope, second.envelope);
        assert_eq!(
            &**identity.open_document(&document).unwrap(),
            b"private workout"
        );
        assert!(other.open_document(&document).is_err());
        let mut replaced = document.clone();
        replaced.record_id = id().unwrap();
        assert!(identity.open_document(&replaced).is_err());
        let mut bytes = decode(&document.envelope).unwrap();
        bytes[49] ^= 1;
        replaced = document;
        replaced.envelope = encode(&bytes);
        assert!(identity.open_document(&replaced).is_err());
    }

    #[test]
    fn recovery_requires_both_artifacts_and_authenticates_the_vault() {
        let identity = Identity::create().unwrap();
        let (mut bundle, key) = identity.recovery().unwrap();
        let restored = Identity::recover(&bundle, &key).unwrap();
        assert_eq!(identity.key, restored.key);
        assert_eq!(identity.token, restored.token);
        assert!(Identity::recover(&bundle, &encode(&[9; 32])).is_err());
        bundle.vault_id = id().unwrap();
        assert!(Identity::recover(&bundle, &key).is_err());
    }
}
