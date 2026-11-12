//! REALITY (XTLS): клиент прячется за рукопожатием настоящего сайта.
//!
//! Клиент кладёт в session_id ClientHello зашифрованную метку (версия,
//! время, short id). Ключ — общий секрет X25519 ключа обмена TLS и
//! открытого ключа сервера. Сервер, узнав метку, отвечает сам временным
//! сертификатом Ed25519, подпись которого заменена на HMAC-SHA512 того же
//! ключа; иначе он прозрачно ведёт клиента к настоящему сайту.
//! Эталон: sing-box `common/tls/reality_client.go`, сервер `sagernet/reality`.

use std::fmt;
use std::time::{SystemTime, UNIX_EPOCH};

use aes_gcm::Aes256Gcm;
use aes_gcm::aead::{AeadInPlace, KeyInit};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use sha2::{Sha256, Sha512};
use x25519_dalek::{PublicKey, StaticSecret};

use crate::error::{EngineError, Result};
use crate::tls::cert;
use crate::tls::hello::SESSION_ID_OFFSET;

/// Версия клиента в метке — как у sing-box (сервер может ограничивать её).
const CLIENT_VERSION: [u8; 3] = [1, 8, 1];

#[derive(Clone, PartialEq, Eq)]
pub struct RealityConfig {
    /// Имя сайта, за которым прячется сервер (SNI).
    pub server_name: String,
    pub public_key: [u8; 32],
    pub short_id: [u8; 8],
}

impl fmt::Debug for RealityConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Ключ и short id — пропуск к серверу: в журнал не попадают.
        f.debug_struct("RealityConfig")
            .field("server_name", &self.server_name)
            .finish_non_exhaustive()
    }
}

impl RealityConfig {
    /// `short_id` — до 16 шестнадцатеричных знаков, справа добивается нулями.
    pub fn new(
        server_name: impl Into<String>,
        public_key: [u8; 32],
        short_id: &str,
    ) -> Result<Self> {
        if short_id.len() > 16 || !short_id.len().is_multiple_of(2) {
            return Err(EngineError::Protocol("reality: bad short id"));
        }
        let mut id = [0u8; 8];
        for (i, pair) in short_id.as_bytes().chunks(2).enumerate() {
            let text = std::str::from_utf8(pair)
                .map_err(|_| EngineError::Protocol("reality: bad short id"))?;
            id[i] = u8::from_str_radix(text, 16)
                .map_err(|_| EngineError::Protocol("reality: bad short id"))?;
        }
        Ok(Self {
            server_name: server_name.into(),
            public_key,
            short_id: id,
        })
    }

    /// Шифрует метку в session_id готового ClientHello (там нули) и
    /// возвращает ключ проверки сертификата.
    pub(crate) fn seal_session_id(
        &self,
        hello: &mut [u8],
        random: &[u8; 32],
        secret: &StaticSecret,
    ) -> Result<[u8; 32]> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs() as u32)
            .unwrap_or_default();
        self.seal_at(hello, random, secret, now)
    }

    fn seal_at(
        &self,
        hello: &mut [u8],
        random: &[u8; 32],
        secret: &StaticSecret,
        now: u32,
    ) -> Result<[u8; 32]> {
        let shared = secret.diffie_hellman(&PublicKey::from(self.public_key));
        let mut auth_key = [0u8; 32];
        Hkdf::<Sha256>::new(Some(&random[..20]), shared.as_bytes())
            .expand(b"REALITY", &mut auth_key)
            .map_err(|_| EngineError::Protocol("reality: key derivation failed"))?;

        let mut label = Vec::with_capacity(32);
        label.extend_from_slice(&CLIENT_VERSION);
        label.push(0);
        label.extend_from_slice(&now.to_be_bytes());
        label.extend_from_slice(&self.short_id);

        let session = SESSION_ID_OFFSET..SESSION_ID_OFFSET + 32;
        hello
            .get_mut(session.clone())
            .ok_or(EngineError::Protocol("reality: short ClientHello"))?
            .fill(0);
        let cipher = Aes256Gcm::new(&auth_key.into());
        // Связанные данные — весь ClientHello с нулевым session_id.
        let tag = cipher
            .encrypt_in_place_detached((&random[20..]).into(), hello, &mut label)
            .map_err(|_| EngineError::Protocol("reality: sealing failed"))?;
        hello[session.start..session.start + 16].copy_from_slice(&label);
        hello[session.start + 16..session.end].copy_from_slice(&tag);
        Ok(auth_key)
    }

    /// Сертификат сервера REALITY: подпись — HMAC-SHA512(ключ, открытый ключ).
    /// Возвращает ключ Ed25519 для проверки CertificateVerify.
    pub(crate) fn verify_certificate(auth_key: &[u8; 32], leaf: &[u8]) -> Result<[u8; 32]> {
        let Some(cert) = cert::ed25519(leaf).ok().flatten() else {
            return Err(EngineError::RealityRejected);
        };
        let mut mac = <Hmac<Sha512> as Mac>::new_from_slice(auth_key).expect("any key length");
        mac.update(cert.public_key);
        mac.verify_slice(cert.signature)
            .map_err(|_| EngineError::RealityRejected)?;
        Ok(*cert.public_key)
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use aes_gcm::aead::Aead;

    use super::*;

    /// Сторона сервера по `sagernet/reality`: тот же ключ из закрытого ключа
    /// сервера и открытого ключа клиента, расшифровка с нулевым session_id.
    #[test]
    fn server_can_open_the_label() {
        let server_secret = StaticSecret::from([3u8; 32]);
        let config = RealityConfig::new(
            "www.example.com",
            PublicKey::from(&server_secret).to_bytes(),
            "0123abcd",
        )
        .unwrap();
        let client_secret = StaticSecret::from([4u8; 32]);
        let random = [6u8; 32];
        let mut hello = vec![1u8; 120];
        hello[38] = 32;
        let client_key = config
            .seal_at(&mut hello, &random, &client_secret, 1_700_000_000)
            .unwrap();

        let shared = server_secret.diffie_hellman(&PublicKey::from(&client_secret));
        let mut auth_key = [0u8; 32];
        Hkdf::<Sha256>::new(Some(&random[..20]), shared.as_bytes())
            .expand(b"REALITY", &mut auth_key)
            .unwrap();
        assert_eq!(auth_key, client_key);

        let sealed = hello[39..71].to_vec();
        let mut aad = hello.clone();
        aad[39..71].fill(0);
        let plain = Aes256Gcm::new(&auth_key.into())
            .decrypt(
                (&random[20..]).into(),
                aes_gcm::aead::Payload {
                    msg: &sealed,
                    aad: &aad,
                },
            )
            .unwrap();
        assert_eq!(&plain[..4], &[1, 8, 1, 0]);
        assert_eq!(&plain[4..8], &1_700_000_000u32.to_be_bytes());
        assert_eq!(&plain[8..], &[0x01, 0x23, 0xab, 0xcd, 0, 0, 0, 0]);
    }

    #[test]
    fn short_id_validation() {
        assert!(RealityConfig::new("a", [0; 32], "").is_ok());
        assert!(RealityConfig::new("a", [0; 32], "0123456789abcdef").is_ok());
        assert!(RealityConfig::new("a", [0; 32], "abc").is_err());
        assert!(RealityConfig::new("a", [0; 32], "zz").is_err());
        assert!(RealityConfig::new("a", [0; 32], "0123456789abcdef00").is_err());
    }
}
