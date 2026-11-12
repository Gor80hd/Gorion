//! Клиент Shadowsocks 2022 (SIP022), TCP. Эталон: sing-shadowsocks
//! `shadowaead_2022`.
//!
//! Ключ — base64 (16 или 32 байта), не пароль. Ключ сессии —
//! BLAKE3-derive_key("shadowsocks 2022 session subkey", ключ ‖ соль).
//! Запрос: соль, заголовки личности (только AES, несколько ключей через
//! `:`), затем зашифрованные куски: фиксированный заголовок [тип 0][время
//! u64][длина переменного u16], переменный [адрес SOCKS][длина
//! выравнивания u16][выравнивание][первые данные], дальше
//! `[длина u16][данные]`. Ответ: соль, [тип 1][время][соль запроса][длина
//! первого куска], первый кусок, дальше как в запросе. Nonce — один
//! счётчик на направление, как в AEAD 2017.

use std::fmt;
use std::time::{SystemTime, UNIX_EPOCH};

use aes::cipher::{BlockEncrypt, KeyInit};
use base64::Engine as _;
use subtle::ConstantTimeEq;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};

use crate::address::TargetAddr;
use crate::error::{EngineError, Result};
use crate::relay::{ChunkRead, PayloadWrite};
use crate::shadowsocks::{Crypter, Method as Aead, TAG_LEN, read_exact_or_eof};
use crate::tls::hello::random_bytes;

/// Наибольший кусок данных: длина — u16 без запаса бит, как в AEAD 2017.
pub const MAX_PAYLOAD: usize = 0xFFFF;
const MAX_PADDING: usize = 900;
/// Расхождение часов с сервером, которое он принимает.
const MAX_TIME_DIFF: u64 = 30;
const HEADER_CLIENT: u8 = 0;
const HEADER_SERVER: u8 = 1;
const SESSION_CONTEXT: &str = "shadowsocks 2022 session subkey";
const IDENTITY_CONTEXT: &str = "shadowsocks 2022 identity subkey";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Method {
    Aes128,
    Aes256,
    Chacha20,
}

impl Method {
    pub fn parse(name: &str) -> Result<Self> {
        match name.to_ascii_lowercase().as_str() {
            "2022-blake3-aes-128-gcm" => Ok(Self::Aes128),
            "2022-blake3-aes-256-gcm" => Ok(Self::Aes256),
            "2022-blake3-chacha20-poly1305" => Ok(Self::Chacha20),
            _ => Err(EngineError::UnsupportedCipher(name.to_owned())),
        }
    }

    pub fn is_2022(name: &str) -> bool {
        name.to_ascii_lowercase().starts_with("2022-")
    }

    /// Длина ключа; соль той же длины.
    pub fn key_len(self) -> usize {
        match self {
            Self::Aes128 => 16,
            Self::Aes256 | Self::Chacha20 => 32,
        }
    }

    fn aead(self) -> Aead {
        match self {
            Self::Aes128 => Aead::Aes128Gcm,
            Self::Aes256 => Aead::Aes256Gcm,
            Self::Chacha20 => Aead::Chacha20Poly1305,
        }
    }
}

/// Сервер и ключи. Ключи не попадают в журнал: `Debug` их скрывает (правило 6).
#[derive(Clone)]
pub struct Ss2022Config {
    pub server: TargetAddr,
    pub method: Method,
    /// Ключи по цепочке: ключи личности (iPSK) сервера-посредника, последний —
    /// ключ пользователя (uPSK).
    keys: Vec<Vec<u8>>,
}

impl fmt::Debug for Ss2022Config {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Ss2022Config")
            .field("server", &self.server)
            .field("method", &self.method)
            .finish_non_exhaustive()
    }
}

impl Ss2022Config {
    /// `password` — ключи base64 через `:`.
    pub fn new(server: TargetAddr, method: Method, password: &str) -> Result<Self> {
        let bad = || EngineError::Protocol("ss2022: bad key");
        let keys = password
            .split(':')
            .map(|part| {
                let key = base64::engine::general_purpose::STANDARD
                    .decode(part.trim())
                    .map_err(|_| bad())?;
                if key.len() == method.key_len() {
                    Ok(key)
                } else {
                    Err(bad())
                }
            })
            .collect::<Result<Vec<_>>>()?;
        if keys.len() > 1 && method == Method::Chacha20 {
            // Заголовок личности — блок AES; для ChaCha его нет.
            return Err(EngineError::Protocol("ss2022: multiple keys need AES"));
        }
        Ok(Self {
            server,
            method,
            keys,
        })
    }

    fn user_key(&self) -> &[u8] {
        self.keys.last().map(Vec::as_slice).unwrap_or_default()
    }
}

fn derive(context: &str, key: &[u8], salt: &[u8], len: usize) -> Vec<u8> {
    let mut hasher = blake3::Hasher::new_derive_key(context);
    hasher.update(key);
    hasher.update(salt);
    let mut out = vec![0u8; len];
    hasher.finalize_xof().fill(&mut out);
    out
}

fn session(method: Method, key: &[u8], salt: &[u8]) -> Result<Crypter> {
    Crypter::with_subkey(
        method.aead(),
        &derive(SESSION_CONTEXT, key, salt, method.key_len()),
    )
}

/// Заголовки личности: каждый ключ цепочки шифрует хеш следующего.
fn identity_headers(config: &Ss2022Config, salt: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    for pair in config.keys.windows(2) {
        let subkey = derive(IDENTITY_CONTEXT, &pair[0], salt, pair[0].len());
        let mut block = aes::Block::default();
        block.copy_from_slice(&blake3::hash(&pair[1]).as_bytes()[..16]);
        match subkey.len() {
            16 => aes::Aes128::new(aes::cipher::generic_array::GenericArray::from_slice(
                &subkey,
            ))
            .encrypt_block(&mut block),
            _ => aes::Aes256::new(aes::cipher::generic_array::GenericArray::from_slice(
                &subkey,
            ))
            .encrypt_block(&mut block),
        }
        out.extend_from_slice(&block);
    }
    out
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or_default()
}

fn random_padding() -> Result<usize> {
    let [a, b] = random_bytes::<2>()?;
    Ok(1 + usize::from(u16::from_le_bytes([a, b])) % MAX_PADDING)
}

/// Шифрующая половина потока.
pub struct Ss2022Writer<W> {
    inner: W,
    crypter: Crypter,
    /// Соль, заголовки личности и адрес ждут первых данных.
    pending: Option<(Vec<u8>, Vec<u8>)>,
}

impl<W: AsyncWrite + Unpin> Ss2022Writer<W> {
    fn sealed_chunks(&mut self, data: &[u8], out: &mut Vec<u8>) -> Result<()> {
        for chunk in data.chunks(MAX_PAYLOAD) {
            let mut len = (chunk.len() as u16).to_be_bytes().to_vec();
            self.crypter.seal(&mut len)?;
            out.extend_from_slice(&len);
            let mut payload = chunk.to_vec();
            self.crypter.seal(&mut payload)?;
            out.extend_from_slice(&payload);
        }
        Ok(())
    }

    /// Запрос с первыми данными; пустые данные — со случайным выравниванием.
    fn request(&mut self, prefix: Vec<u8>, address: &[u8], data: &[u8]) -> Result<Vec<u8>> {
        let padding = if data.is_empty() {
            random_padding()?
        } else {
            0
        };
        let room = MAX_PAYLOAD - address.len() - 2 - padding;
        let (first, rest) = data.split_at(data.len().min(room));
        let mut variable = Vec::with_capacity(address.len() + 2 + padding + first.len());
        variable.extend_from_slice(address);
        variable.extend_from_slice(&(padding as u16).to_be_bytes());
        variable.resize(variable.len() + padding, 0);
        variable.extend_from_slice(first);

        let mut fixed = Vec::with_capacity(11 + TAG_LEN);
        fixed.push(HEADER_CLIENT);
        fixed.extend_from_slice(&now().to_be_bytes());
        fixed.extend_from_slice(&(variable.len() as u16).to_be_bytes());

        let mut out = prefix;
        self.crypter.seal(&mut fixed)?;
        out.extend_from_slice(&fixed);
        self.crypter.seal(&mut variable)?;
        out.extend_from_slice(&variable);
        self.sealed_chunks(rest, &mut out)?;
        Ok(out)
    }

    pub async fn write_payload(&mut self, data: &[u8]) -> Result<()> {
        let frame = match self.pending.take() {
            Some((prefix, address)) => self.request(prefix, &address, data)?,
            None => {
                let mut out = Vec::with_capacity(data.len() + 2 * (2 + TAG_LEN));
                self.sealed_chunks(data, &mut out)?;
                out
            }
        };
        self.inner.write_all(&frame).await?;
        Ok(())
    }

    pub async fn flush_header(&mut self) -> Result<()> {
        if self.pending.is_some() {
            self.write_payload(&[]).await?;
        }
        Ok(())
    }
}

/// Расшифровывающая половина потока.
pub struct Ss2022Reader<R> {
    inner: R,
    method: Method,
    key: Vec<u8>,
    request_salt: Vec<u8>,
    crypter: Option<Crypter>,
}

impl<R: AsyncRead + Unpin> Ss2022Reader<R> {
    /// Соль и заголовок ответа; первый кусок данных.
    async fn read_response(&mut self) -> Result<Option<Vec<u8>>> {
        let mut salt = vec![0u8; self.method.key_len()];
        if !read_exact_or_eof(&mut self.inner, &mut salt).await? {
            return Ok(None);
        }
        let mut crypter = session(self.method, &self.key, &salt)?;
        let salt_len = self.method.key_len();
        let mut fixed = vec![0u8; 1 + 8 + salt_len + 2 + TAG_LEN];
        self.inner.read_exact(&mut fixed).await?;
        crypter.open(&mut fixed)?;
        if fixed[0] != HEADER_SERVER {
            return Err(EngineError::Protocol("ss2022: bad response type"));
        }
        let mut time = [0u8; 8];
        time.copy_from_slice(&fixed[1..9]);
        if now().abs_diff(u64::from_be_bytes(time)) > MAX_TIME_DIFF {
            return Err(EngineError::Protocol("ss2022: server clock is off"));
        }
        if !bool::from(fixed[9..9 + salt_len].ct_eq(&self.request_salt)) {
            return Err(EngineError::Protocol("ss2022: response to another request"));
        }
        let len = usize::from(u16::from_be_bytes([
            fixed[9 + salt_len],
            fixed[10 + salt_len],
        ]));
        let mut payload = vec![0u8; len + TAG_LEN];
        self.inner.read_exact(&mut payload).await?;
        let len = crypter.open(&mut payload)?;
        payload.truncate(len);
        self.crypter = Some(crypter);
        Ok(Some(payload))
    }

    /// Следующий кусок данных; `None` — сервер закрыл поток на границе куска.
    pub async fn read_chunk(&mut self) -> Result<Option<Vec<u8>>> {
        loop {
            let chunk = match self.crypter.as_mut() {
                None => self.read_response().await?,
                Some(crypter) => {
                    let mut len = [0u8; 2 + TAG_LEN];
                    if !read_exact_or_eof(&mut self.inner, &mut len).await? {
                        return Ok(None);
                    }
                    crypter.open(&mut len)?;
                    let size = usize::from(u16::from_be_bytes([len[0], len[1]]));
                    let mut payload = vec![0u8; size + TAG_LEN];
                    self.inner.read_exact(&mut payload).await?;
                    let size = crypter.open(&mut payload)?;
                    payload.truncate(size);
                    Some(payload)
                }
            };
            match chunk {
                None => return Ok(None),
                // Пустой первый кусок — сервер ещё ничего не прислал.
                Some(data) if data.is_empty() => {}
                Some(data) => return Ok(Some(data)),
            }
        }
    }
}

fn halves<R, W>(
    config: &Ss2022Config,
    read: R,
    write: W,
    target: &TargetAddr,
) -> Result<(Ss2022Reader<R>, Ss2022Writer<W>)> {
    let mut salt = vec![0u8; config.method.key_len()];
    getrandom::fill(&mut salt).map_err(|_| EngineError::Protocol("random salt"))?;
    let crypter = session(config.method, config.user_key(), &salt)?;
    let mut prefix = salt.clone();
    prefix.extend_from_slice(&identity_headers(config, &salt));
    let mut address = Vec::with_capacity(32);
    target.write_socks(&mut address)?;
    Ok((
        Ss2022Reader {
            inner: read,
            method: config.method,
            key: config.user_key().to_vec(),
            request_salt: salt,
            crypter: None,
        },
        Ss2022Writer {
            inner: write,
            crypter,
            pending: Some((prefix, address)),
        },
    ))
}

/// Открывает поток через сервер. Запрос уходит вместе с первыми данными
/// клиента (или по `flush_header`).
pub async fn connect(
    config: &Ss2022Config,
    target: &TargetAddr,
    initial: &[u8],
) -> Result<(Ss2022Reader<OwnedReadHalf>, Ss2022Writer<OwnedWriteHalf>)> {
    let stream = crate::outbound::dial(&config.server).await?;
    let (read, write) = stream.into_split();
    let (reader, mut writer) = halves(config, read, write, target)?;
    if !initial.is_empty() {
        writer.write_payload(initial).await?;
    }
    Ok((reader, writer))
}

impl ChunkRead for Ss2022Reader<OwnedReadHalf> {
    async fn read_chunk(&mut self) -> Result<Option<Vec<u8>>> {
        Ss2022Reader::read_chunk(self).await
    }
}

impl PayloadWrite for Ss2022Writer<OwnedWriteHalf> {
    async fn write_payload(&mut self, data: &[u8]) -> Result<()> {
        Ss2022Writer::write_payload(self, data).await
    }

    async fn flush_header(&mut self) -> Result<()> {
        Ss2022Writer::flush_header(self).await
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    const KEY16: &str = "AAECAwQFBgcICQoLDA0ODw==";

    fn config(method: Method, password: &str) -> Ss2022Config {
        Ss2022Config::new(TargetAddr::Domain("h".into(), 1), method, password).unwrap()
    }

    #[test]
    fn parses_keys() {
        assert_eq!(config(Method::Aes128, KEY16).keys.len(), 1);
        assert_eq!(
            config(Method::Aes128, &format!("{KEY16}:{KEY16}"))
                .keys
                .len(),
            2
        );
        let server = TargetAddr::Domain("h".into(), 1);
        // Длина ключа должна совпадать с методом; пароль вместо ключа — ошибка.
        assert!(Ss2022Config::new(server.clone(), Method::Aes256, KEY16).is_err());
        assert!(Ss2022Config::new(server.clone(), Method::Aes128, "password").is_err());
        let key32 = base64::engine::general_purpose::STANDARD.encode([7u8; 32]);
        assert!(Ss2022Config::new(server, Method::Chacha20, &format!("{key32}:{key32}")).is_err());
        assert!(!format!("{:?}", config(Method::Aes128, KEY16)).contains("keys"));
    }

    #[test]
    fn identity_header_per_extra_key() {
        let single = config(Method::Aes128, KEY16);
        assert!(identity_headers(&single, &[1; 16]).is_empty());
        let other = base64::engine::general_purpose::STANDARD.encode([9u8; 16]);
        let multi = config(Method::Aes128, &format!("{KEY16}:{other}"));
        let eih = identity_headers(&multi, &[1; 16]);
        assert_eq!(eih.len(), 16);
        assert_ne!(eih, identity_headers(&multi, &[2; 16]));
    }

    /// Сервер для проверки формата: разбирает запрос и отвечает эхом.
    #[tokio::test]
    async fn request_and_response_frames() {
        for (method, password) in [
            (Method::Aes128, KEY16.to_owned()),
            (
                Method::Chacha20,
                base64::engine::general_purpose::STANDARD.encode([3u8; 32]),
            ),
        ] {
            let config = config(method, &password);
            let key = config.user_key().to_vec();
            let (client, mut server) = tokio::io::duplex(1 << 20);
            let (client_read, client_write) = tokio::io::split(client);
            let target = TargetAddr::Domain("example.com".into(), 80);
            let (mut reader, mut writer) =
                halves(&config, client_read, client_write, &target).unwrap();
            let data: Vec<u8> = (0..70_000u32).map(|i| (i % 251) as u8).collect();
            writer.write_payload(&data).await.unwrap();

            // Сторона сервера.
            let n = method.key_len();
            let mut salt = vec![0u8; n];
            server.read_exact(&mut salt).await.unwrap();
            let mut up = session(method, &key, &salt).unwrap();
            let mut fixed = vec![0u8; 11 + TAG_LEN];
            server.read_exact(&mut fixed).await.unwrap();
            up.open(&mut fixed).unwrap();
            assert_eq!(fixed[0], HEADER_CLIENT);
            let var_len = usize::from(u16::from_be_bytes([fixed[9], fixed[10]]));
            let mut variable = vec![0u8; var_len + TAG_LEN];
            server.read_exact(&mut variable).await.unwrap();
            up.open(&mut variable).unwrap();
            assert_eq!(&variable[..2], &[3, 11]);
            let after_addr = 2 + 11 + 2;
            assert_eq!(&variable[after_addr..after_addr + 2], &[0, 0]);
            let mut got = variable[after_addr + 2..var_len].to_vec();
            while got.len() < data.len() {
                let mut len = [0u8; 2 + TAG_LEN];
                server.read_exact(&mut len).await.unwrap();
                up.open(&mut len).unwrap();
                let size = usize::from(u16::from_be_bytes([len[0], len[1]]));
                let mut chunk = vec![0u8; size + TAG_LEN];
                server.read_exact(&mut chunk).await.unwrap();
                up.open(&mut chunk).unwrap();
                got.extend_from_slice(&chunk[..size]);
            }
            assert_eq!(got, data);

            // Ответ: заголовок с солью запроса и два куска.
            let reply_salt = vec![5u8; n];
            let mut down = session(method, &key, &reply_salt).unwrap();
            let mut out = reply_salt.clone();
            let mut header = vec![HEADER_SERVER];
            header.extend_from_slice(&now().to_be_bytes());
            header.extend_from_slice(&salt);
            header.extend_from_slice(&5u16.to_be_bytes());
            down.seal(&mut header).unwrap();
            out.extend_from_slice(&header);
            let mut first = b"hello".to_vec();
            down.seal(&mut first).unwrap();
            out.extend_from_slice(&first);
            let mut len = 5u16.to_be_bytes().to_vec();
            down.seal(&mut len).unwrap();
            out.extend_from_slice(&len);
            let mut second = b"world".to_vec();
            down.seal(&mut second).unwrap();
            out.extend_from_slice(&second);
            server.write_all(&out).await.unwrap();
            drop(server);
            assert_eq!(reader.read_chunk().await.unwrap().unwrap(), b"hello");
            assert_eq!(reader.read_chunk().await.unwrap().unwrap(), b"world");
            assert!(reader.read_chunk().await.unwrap().is_none());
        }
    }

    #[tokio::test]
    async fn empty_request_is_padded() {
        let config = config(Method::Aes128, KEY16);
        let (client, mut server) = tokio::io::duplex(1 << 16);
        let (r, w) = tokio::io::split(client);
        let (reader, mut writer) =
            halves(&config, r, w, &TargetAddr::Domain("a".into(), 1)).unwrap();
        writer.flush_header().await.unwrap();
        // Обе половины клиента закрыты — сервер видит конец потока.
        drop((reader, writer));
        let mut all = Vec::new();
        server.read_to_end(&mut all).await.unwrap();
        // соль 16 + фиксированный 11+16 + переменный (адрес 5 + 2 + ≥1) + 16.
        assert!(all.len() >= 16 + 27 + 8 + 16);
    }
}
