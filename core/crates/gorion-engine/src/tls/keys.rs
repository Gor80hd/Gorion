//! Набор шифров TLS 1.3 и расписание ключей (RFC 8446, раздел 7).

use aes_gcm::aead::{AeadInPlace, KeyInit};
use aes_gcm::{Aes128Gcm, Aes256Gcm};
use chacha20poly1305::ChaCha20Poly1305;
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256, Sha384};

use crate::error::{EngineError, Result};

pub const TLS_AES_128_GCM_SHA256: u16 = 0x1301;
pub const TLS_AES_256_GCM_SHA384: u16 = 0x1302;
pub const TLS_CHACHA20_POLY1305_SHA256: u16 = 0x1303;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Suite {
    Aes128GcmSha256,
    Aes256GcmSha384,
    ChaCha20Poly1305Sha256,
}

impl Suite {
    pub fn from_id(id: u16) -> Option<Self> {
        match id {
            TLS_AES_128_GCM_SHA256 => Some(Self::Aes128GcmSha256),
            TLS_AES_256_GCM_SHA384 => Some(Self::Aes256GcmSha384),
            TLS_CHACHA20_POLY1305_SHA256 => Some(Self::ChaCha20Poly1305Sha256),
            _ => None,
        }
    }

    pub fn hash_len(self) -> usize {
        match self {
            Self::Aes256GcmSha384 => 48,
            _ => 32,
        }
    }

    fn key_len(self) -> usize {
        match self {
            Self::Aes128GcmSha256 => 16,
            _ => 32,
        }
    }

    pub fn hash(self, data: &[u8]) -> Vec<u8> {
        match self {
            Self::Aes256GcmSha384 => Sha384::digest(data).to_vec(),
            _ => Sha256::digest(data).to_vec(),
        }
    }

    pub fn extract(self, salt: &[u8], ikm: &[u8]) -> Vec<u8> {
        match self {
            Self::Aes256GcmSha384 => Hkdf::<Sha384>::extract(Some(salt), ikm).0.to_vec(),
            _ => Hkdf::<Sha256>::extract(Some(salt), ikm).0.to_vec(),
        }
    }

    /// HKDF-Expand-Label с префиксом «tls13 ».
    pub fn expand_label(self, secret: &[u8], label: &str, context: &[u8], len: usize) -> Vec<u8> {
        let full = [b"tls13 ", label.as_bytes()].concat();
        let mut info = Vec::with_capacity(4 + full.len() + context.len());
        info.extend_from_slice(&(len as u16).to_be_bytes());
        info.push(full.len() as u8);
        info.extend_from_slice(&full);
        info.push(context.len() as u8);
        info.extend_from_slice(context);
        let mut out = vec![0u8; len];
        // Длины фиксированы протоколом и меньше 255 * hash_len: ошибки нет.
        let expanded = match self {
            Self::Aes256GcmSha384 => {
                Hkdf::<Sha384>::from_prk(secret).map(|h| h.expand(&info, &mut out).is_ok())
            }
            _ => Hkdf::<Sha256>::from_prk(secret).map(|h| h.expand(&info, &mut out).is_ok()),
        };
        debug_assert!(matches!(expanded, Ok(true)));
        out
    }

    pub fn derive_secret(self, secret: &[u8], label: &str, transcript: &[u8]) -> Vec<u8> {
        self.expand_label(secret, label, &self.hash(transcript), self.hash_len())
    }

    pub fn hmac(self, key: &[u8], data: &[u8]) -> Vec<u8> {
        match self {
            Self::Aes256GcmSha384 => {
                let mut mac = <Hmac<Sha384> as Mac>::new_from_slice(key).expect("any key length");
                mac.update(data);
                mac.finalize().into_bytes().to_vec()
            }
            _ => {
                let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(key).expect("any key length");
                mac.update(data);
                mac.finalize().into_bytes().to_vec()
            }
        }
    }

    /// verify_data сообщения Finished.
    pub fn finished(self, base_secret: &[u8], transcript: &[u8]) -> Vec<u8> {
        let key = self.expand_label(base_secret, "finished", &[], self.hash_len());
        self.hmac(&key, &self.hash(transcript))
    }
}

/// Секреты рукопожатия и приложения по порядку RFC 8446, 7.1.
pub struct Schedule {
    suite: Suite,
    handshake_secret: Vec<u8>,
}

impl Schedule {
    pub fn new(suite: Suite, shared: &[u8]) -> Self {
        let zeros = vec![0u8; suite.hash_len()];
        let early = suite.extract(&[], &zeros);
        let derived = suite.derive_secret(&early, "derived", &[]);
        let handshake_secret = suite.extract(&derived, shared);
        Self {
            suite,
            handshake_secret,
        }
    }

    /// (клиентский, серверный) секреты рукопожатия по ClientHello..ServerHello.
    pub fn handshake(&self, transcript: &[u8]) -> (Vec<u8>, Vec<u8>) {
        let s = self.suite;
        (
            s.derive_secret(&self.handshake_secret, "c hs traffic", transcript),
            s.derive_secret(&self.handshake_secret, "s hs traffic", transcript),
        )
    }

    /// (клиентский, серверный) секреты приложения по ClientHello..server Finished.
    pub fn application(&self, transcript: &[u8]) -> (Vec<u8>, Vec<u8>) {
        let s = self.suite;
        let derived = s.derive_secret(&self.handshake_secret, "derived", &[]);
        let master = s.extract(&derived, &vec![0u8; s.hash_len()]);
        (
            s.derive_secret(&master, "c ap traffic", transcript),
            s.derive_secret(&master, "s ap traffic", transcript),
        )
    }
}

enum Cipher {
    Aes128(Box<Aes128Gcm>),
    Aes256(Box<Aes256Gcm>),
    ChaCha(Box<ChaCha20Poly1305>),
}

/// Ключ защиты записей одного направления.
pub struct RecordKey {
    suite: Suite,
    secret: Vec<u8>,
    cipher: Cipher,
    iv: [u8; 12],
    seq: u64,
}

pub const TAG_LEN: usize = 16;

impl RecordKey {
    pub fn new(suite: Suite, secret: Vec<u8>) -> Self {
        let key = suite.expand_label(&secret, "key", &[], suite.key_len());
        let iv_bytes = suite.expand_label(&secret, "iv", &[], 12);
        let mut iv = [0u8; 12];
        iv.copy_from_slice(&iv_bytes);
        let cipher = match suite {
            Suite::Aes128GcmSha256 => Cipher::Aes128(Box::new(
                Aes128Gcm::new_from_slice(&key).expect("16-byte key"),
            )),
            Suite::Aes256GcmSha384 => Cipher::Aes256(Box::new(
                Aes256Gcm::new_from_slice(&key).expect("32-byte key"),
            )),
            Suite::ChaCha20Poly1305Sha256 => Cipher::ChaCha(Box::new(
                ChaCha20Poly1305::new_from_slice(&key).expect("32-byte key"),
            )),
        };
        Self {
            suite,
            secret,
            cipher,
            iv,
            seq: 0,
        }
    }

    /// Следующее поколение ключа после KeyUpdate.
    pub fn updated(&self) -> Self {
        let next = self
            .suite
            .expand_label(&self.secret, "traffic upd", &[], self.suite.hash_len());
        Self::new(self.suite, next)
    }

    fn nonce(&mut self) -> Result<[u8; 12]> {
        let mut nonce = self.iv;
        for (n, s) in nonce[4..].iter_mut().zip(self.seq.to_be_bytes()) {
            *n ^= s;
        }
        self.seq = self
            .seq
            .checked_add(1)
            .ok_or(EngineError::Protocol("tls: sequence number exhausted"))?;
        Ok(nonce)
    }

    /// Запечатывает `data` с типом `content_type` и добавляет запись в `out`.
    pub fn seal(&mut self, content_type: u8, data: &[u8], out: &mut Vec<u8>) -> Result<()> {
        let len = data.len() + 1 + TAG_LEN;
        let header = [
            super::CONTENT_APPLICATION_DATA,
            0x03,
            0x03,
            (len >> 8) as u8,
            len as u8,
        ];
        let mut body = Vec::with_capacity(len);
        body.extend_from_slice(data);
        body.push(content_type);
        let nonce = self.nonce()?;
        let sealed = match &self.cipher {
            Cipher::Aes128(c) => c.encrypt_in_place(&nonce.into(), &header, &mut body),
            Cipher::Aes256(c) => c.encrypt_in_place(&nonce.into(), &header, &mut body),
            Cipher::ChaCha(c) => c.encrypt_in_place(&nonce.into(), &header, &mut body),
        };
        sealed.map_err(|_| EngineError::Protocol("tls: encryption failed"))?;
        out.extend_from_slice(&header);
        out.extend_from_slice(&body);
        Ok(())
    }

    /// Расшифровывает тело записи; возвращает внутренний тип содержимого.
    pub fn open(&mut self, header: &[u8; 5], body: &mut Vec<u8>) -> Result<u8> {
        let nonce = self.nonce()?;
        let opened = match &self.cipher {
            Cipher::Aes128(c) => c.decrypt_in_place(&nonce.into(), header, body),
            Cipher::Aes256(c) => c.decrypt_in_place(&nonce.into(), header, body),
            Cipher::ChaCha(c) => c.decrypt_in_place(&nonce.into(), header, body),
        };
        opened.map_err(|_| EngineError::Decrypt)?;
        // TLSInnerPlaintext: содержимое, тип, нули выравнивания.
        while let Some(byte) = body.pop() {
            if byte != 0 {
                return Ok(byte);
            }
        }
        Err(EngineError::Protocol("tls: record without content type"))
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    fn hex(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    /// RFC 8448, раздел 3: простое рукопожатие 1-RTT.
    #[test]
    fn key_schedule_matches_rfc8448() {
        let suite = Suite::Aes128GcmSha256;
        let shared = hex("8bd4054fb55b9d63fdfbacf9f04b9f0d35e6d63f537563efd46272900f89492d");
        let schedule = Schedule::new(suite, &shared);
        assert_eq!(
            schedule.handshake_secret,
            hex("1dc826e93606aa6fdc0aadc12f741b01046aa6b99f691ed221a9f0ca043fbeac")
        );
        let s_hs = hex("b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38");
        let key = RecordKey::new(suite, s_hs);
        assert_eq!(key.iv.to_vec(), hex("5d313eb2671276ee13000b30"));
    }
}
