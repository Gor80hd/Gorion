//! Клиент Shadowsocks AEAD (SIP004; формат — shadowsocks.org/doc/aead.html).
//!
//! Поток в каждую сторону: соль, затем куски
//! `[длина u16 BE + тег][данные + тег]`. Ключ куска — HKDF-SHA1(ключ, соль,
//! "ss-subkey"); nonce — 12-байтовый счётчик little-endian, растёт после
//! каждой операции. Первый кусок от клиента начинается с адреса назначения.

use std::fmt;

use aes_gcm::aead::AeadInPlace;
use aes_gcm::aead::generic_array::GenericArray;
use aes_gcm::{Aes128Gcm, Aes256Gcm, KeyInit};
use chacha20poly1305::ChaCha20Poly1305;
use hkdf::Hkdf;
use md5::{Digest, Md5};
use sha1::Sha1;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

use crate::address::TargetAddr;
use crate::error::{EngineError, Result};

/// Наибольшая длина данных в куске по спецификации.
pub const MAX_PAYLOAD: usize = 0x3FFF;
pub(crate) const TAG_LEN: usize = 16;
const NONCE_LEN: usize = 12;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Method {
    Aes128Gcm,
    Aes256Gcm,
    Chacha20Poly1305,
}

impl Method {
    pub fn parse(name: &str) -> Result<Self> {
        match name.to_ascii_lowercase().as_str() {
            "aes-128-gcm" => Ok(Self::Aes128Gcm),
            "aes-256-gcm" => Ok(Self::Aes256Gcm),
            "chacha20-ietf-poly1305" | "chacha20-poly1305" => Ok(Self::Chacha20Poly1305),
            _ => Err(EngineError::UnsupportedCipher(name.to_owned())),
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Aes128Gcm => "aes-128-gcm",
            Self::Aes256Gcm => "aes-256-gcm",
            Self::Chacha20Poly1305 => "chacha20-ietf-poly1305",
        }
    }

    /// Длина ключа; соль той же длины.
    pub fn key_len(self) -> usize {
        match self {
            Self::Aes128Gcm => 16,
            Self::Aes256Gcm | Self::Chacha20Poly1305 => 32,
        }
    }
}

/// Сервер и ключ. Ключ не попадает в журнал: `Debug` его скрывает (правило 6).
#[derive(Clone)]
pub struct ShadowsocksConfig {
    pub server: TargetAddr,
    pub method: Method,
    key: Vec<u8>,
}

impl ShadowsocksConfig {
    pub fn new(server: TargetAddr, method: Method, password: &str) -> Self {
        let key = evp_bytes_to_key(password.as_bytes(), method.key_len());
        Self {
            server,
            method,
            key,
        }
    }
}

impl fmt::Debug for ShadowsocksConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ShadowsocksConfig")
            .field("server", &self.server)
            .field("method", &self.method)
            .finish_non_exhaustive()
    }
}

/// Ключ из пароля, как `EVP_BytesToKey` OpenSSL с MD5 и одним проходом.
pub fn evp_bytes_to_key(password: &[u8], len: usize) -> Vec<u8> {
    let mut key = Vec::with_capacity(len + 16);
    let mut previous: Vec<u8> = Vec::new();
    while key.len() < len {
        let mut hasher = Md5::new();
        hasher.update(&previous);
        hasher.update(password);
        previous = hasher.finalize().to_vec();
        key.extend_from_slice(&previous);
    }
    key.truncate(len);
    key
}

enum Aead {
    Aes128(Box<Aes128Gcm>),
    Aes256(Box<Aes256Gcm>),
    Chacha(Box<ChaCha20Poly1305>),
}

/// Шифр одного направления: ключ куска и счётчик nonce.
pub(crate) struct Crypter {
    aead: Aead,
    nonce: [u8; NONCE_LEN],
}

impl Crypter {
    fn new(method: Method, key: &[u8], salt: &[u8]) -> Result<Self> {
        let mut subkey = vec![0u8; method.key_len()];
        Hkdf::<Sha1>::new(Some(salt), key)
            .expand(b"ss-subkey", &mut subkey)
            .map_err(|_| EngineError::Protocol("hkdf length"))?;
        Self::with_subkey(method, &subkey)
    }

    /// Шифр с готовым ключом сессии (Shadowsocks 2022 выводит его иначе).
    pub(crate) fn with_subkey(method: Method, subkey: &[u8]) -> Result<Self> {
        let invalid = |_| EngineError::Protocol("key length");
        let aead = match method {
            Method::Aes128Gcm => Aead::Aes128(Box::new(
                Aes128Gcm::new_from_slice(subkey).map_err(invalid)?,
            )),
            Method::Aes256Gcm => Aead::Aes256(Box::new(
                Aes256Gcm::new_from_slice(subkey).map_err(invalid)?,
            )),
            Method::Chacha20Poly1305 => Aead::Chacha(Box::new(
                ChaCha20Poly1305::new_from_slice(subkey).map_err(invalid)?,
            )),
        };
        Ok(Self {
            aead,
            nonce: [0; NONCE_LEN],
        })
    }

    /// Шифрует буфер на месте и дописывает тег.
    pub(crate) fn seal(&mut self, buf: &mut Vec<u8>) -> Result<()> {
        let nonce = GenericArray::from_slice(&self.nonce);
        let tag = match &self.aead {
            Aead::Aes128(c) => c.encrypt_in_place_detached(nonce, b"", buf),
            Aead::Aes256(c) => c.encrypt_in_place_detached(nonce, b"", buf),
            Aead::Chacha(c) => c.encrypt_in_place_detached(nonce, b"", buf),
        }
        .map_err(|_| EngineError::Protocol("encrypt"))?;
        buf.extend_from_slice(&tag);
        self.advance();
        Ok(())
    }

    /// Расшифровывает `данные + тег` на месте; возвращает длину данных.
    pub(crate) fn open(&mut self, buf: &mut [u8]) -> Result<usize> {
        let len = buf.len().checked_sub(TAG_LEN).ok_or(EngineError::Decrypt)?;
        let (data, tag) = buf.split_at_mut(len);
        let nonce = GenericArray::from_slice(&self.nonce);
        let tag = GenericArray::from_slice(tag);
        match &self.aead {
            Aead::Aes128(c) => c.decrypt_in_place_detached(nonce, b"", data, tag),
            Aead::Aes256(c) => c.decrypt_in_place_detached(nonce, b"", data, tag),
            Aead::Chacha(c) => c.decrypt_in_place_detached(nonce, b"", data, tag),
        }
        .map_err(|_| EngineError::Decrypt)?;
        self.advance();
        Ok(len)
    }

    fn advance(&mut self) {
        for byte in &mut self.nonce {
            *byte = byte.wrapping_add(1);
            if *byte != 0 {
                break;
            }
        }
    }
}

/// Шифрующая половина потока.
pub struct SsWriter<W> {
    inner: W,
    crypter: Crypter,
    /// Соль уходит вместе с первым куском, а не отдельным пакетом.
    pending_salt: Option<Vec<u8>>,
}

impl<W: AsyncWrite + Unpin> SsWriter<W> {
    pub fn new(inner: W, method: Method, key: &[u8]) -> Result<Self> {
        let mut salt = vec![0u8; method.key_len()];
        getrandom::fill(&mut salt).map_err(|_| EngineError::Protocol("random salt"))?;
        Self::with_salt(inner, method, key, salt)
    }

    fn with_salt(inner: W, method: Method, key: &[u8], salt: Vec<u8>) -> Result<Self> {
        let crypter = Crypter::new(method, key, &salt)?;
        Ok(Self {
            inner,
            crypter,
            pending_salt: Some(salt),
        })
    }

    pub async fn write_payload(&mut self, data: &[u8]) -> Result<()> {
        let mut frame = self.pending_salt.take().unwrap_or_default();
        for chunk in data.chunks(MAX_PAYLOAD) {
            let mut len = u16::try_from(chunk.len())
                .map_err(|_| EngineError::Protocol("chunk length"))?
                .to_be_bytes()
                .to_vec();
            self.crypter.seal(&mut len)?;
            frame.extend_from_slice(&len);
            let mut payload = chunk.to_vec();
            self.crypter.seal(&mut payload)?;
            frame.extend_from_slice(&payload);
        }
        self.inner.write_all(&frame).await?;
        Ok(())
    }

    pub async fn shutdown(&mut self) -> Result<()> {
        // Если данных так и не было, соль всё равно должна дойти: сервер ждёт её.
        if let Some(salt) = self.pending_salt.take() {
            self.inner.write_all(&salt).await?;
        }
        self.inner.shutdown().await?;
        Ok(())
    }
}

/// Расшифровывающая половина потока.
pub struct SsReader<R> {
    inner: R,
    method: Method,
    key: Vec<u8>,
    crypter: Option<Crypter>,
}

impl<R: AsyncRead + Unpin> SsReader<R> {
    pub fn new(inner: R, method: Method, key: &[u8]) -> Self {
        Self {
            inner,
            method,
            key: key.to_vec(),
            crypter: None,
        }
    }

    /// Следующий кусок данных; `None` — собеседник закрыл поток на границе куска.
    pub async fn read_chunk(&mut self) -> Result<Option<Vec<u8>>> {
        if self.crypter.is_none() {
            let mut salt = vec![0u8; self.method.key_len()];
            if !read_exact_or_eof(&mut self.inner, &mut salt).await? {
                return Ok(None);
            }
            self.crypter = Some(Crypter::new(self.method, &self.key, &salt)?);
        }
        let Some(crypter) = self.crypter.as_mut() else {
            return Err(EngineError::Protocol("cipher state"));
        };
        let mut len = [0u8; 2 + TAG_LEN];
        if !read_exact_or_eof(&mut self.inner, &mut len).await? {
            return Ok(None);
        }
        crypter.open(&mut len)?;
        let size = usize::from(u16::from_be_bytes([len[0], len[1]]) & 0x3FFF);
        let mut payload = vec![0u8; size + TAG_LEN];
        self.inner.read_exact(&mut payload).await?;
        let size = crypter.open(&mut payload)?;
        payload.truncate(size);
        Ok(Some(payload))
    }
}

/// Читает буфер целиком. `false` — поток закончился до первого байта;
/// обрыв посередине — ошибка.
pub(crate) async fn read_exact_or_eof<R: AsyncRead + Unpin>(
    reader: &mut R,
    buf: &mut [u8],
) -> Result<bool> {
    let mut filled = 0;
    while filled < buf.len() {
        let n = reader.read(&mut buf[filled..]).await?;
        if n == 0 {
            if filled == 0 {
                return Ok(false);
            }
            return Err(EngineError::Io(std::io::ErrorKind::UnexpectedEof.into()));
        }
        filled += n;
    }
    Ok(true)
}

/// Открывает поток через сервер Shadowsocks: адрес назначения и `initial`
/// уходят первым куском.
pub async fn connect(
    config: &ShadowsocksConfig,
    target: &TargetAddr,
    initial: &[u8],
) -> Result<(
    SsReader<tokio::net::tcp::OwnedReadHalf>,
    SsWriter<tokio::net::tcp::OwnedWriteHalf>,
)> {
    let stream = crate::outbound::dial(&config.server).await?;
    let (read, write) = stream.into_split();
    let mut writer = SsWriter::new(write, config.method, &config.key)?;
    let mut first = Vec::with_capacity(32 + initial.len());
    target.write_socks(&mut first)?;
    first.extend_from_slice(initial);
    writer.write_payload(&first).await?;
    Ok((SsReader::new(read, config.method, &config.key), writer))
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    #[test]
    fn evp_key_matches_openssl() {
        // MD5("password") = 5f4dcc3b5aa765d61d8327deb882cf99.
        let key = evp_bytes_to_key(b"password", 16);
        assert_eq!(
            key,
            [
                0x5f, 0x4d, 0xcc, 0x3b, 0x5a, 0xa7, 0x65, 0xd6, 0x1d, 0x83, 0x27, 0xde, 0xb8, 0x82,
                0xcf, 0x99
            ]
        );
        // Второй блок — MD5(первый блок || пароль).
        let long = evp_bytes_to_key(b"password", 32);
        assert_eq!(&long[..16], &key[..]);
        let mut hasher = Md5::new();
        hasher.update(key);
        hasher.update(b"password");
        assert_eq!(&long[16..], hasher.finalize().as_slice());
    }

    #[test]
    fn nonce_is_little_endian_counter() {
        let mut crypter = Crypter::new(Method::Aes128Gcm, &[7; 16], &[1; 16]).unwrap();
        crypter.nonce[0] = 0xFF;
        crypter.advance();
        assert_eq!(&crypter.nonce[..3], &[0, 1, 0]);
    }

    #[test]
    fn parses_method_names() {
        assert_eq!(Method::parse("AES-256-GCM").unwrap(), Method::Aes256Gcm);
        assert_eq!(
            Method::parse("chacha20-ietf-poly1305").unwrap(),
            Method::Chacha20Poly1305
        );
        assert!(Method::parse("rc4-md5").is_err());
    }

    #[test]
    fn debug_hides_key() {
        let config = ShadowsocksConfig::new(
            TargetAddr::Domain("h".into(), 1),
            Method::Aes128Gcm,
            "secret",
        );
        assert!(!format!("{config:?}").contains("key"));
    }

    #[tokio::test]
    async fn round_trip_all_methods_with_large_payload() {
        for method in [
            Method::Aes128Gcm,
            Method::Aes256Gcm,
            Method::Chacha20Poly1305,
        ] {
            let key = evp_bytes_to_key(b"pw", method.key_len());
            let (client, server) = tokio::io::duplex(1 << 20);
            let mut writer = SsWriter::new(client, method, &key).unwrap();
            let data: Vec<u8> = (0..100_000u32).map(|i| (i % 251) as u8).collect();
            writer.write_payload(&data).await.unwrap();
            writer.shutdown().await.unwrap();
            let mut reader = SsReader::new(server, method, &key);
            let mut got = Vec::new();
            while let Some(chunk) = reader.read_chunk().await.unwrap() {
                assert!(chunk.len() <= MAX_PAYLOAD);
                got.extend_from_slice(&chunk);
            }
            assert_eq!(got, data, "{}", method.name());
        }
    }

    #[tokio::test]
    async fn wrong_key_is_rejected() {
        let (client, server) = tokio::io::duplex(4096);
        let mut writer = SsWriter::new(client, Method::Aes256Gcm, &[1; 32]).unwrap();
        writer.write_payload(b"hello").await.unwrap();
        let mut reader = SsReader::new(server, Method::Aes256Gcm, &[2; 32]);
        assert!(matches!(
            reader.read_chunk().await,
            Err(EngineError::Decrypt)
        ));
    }
}
