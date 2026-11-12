//! Свой клиент TLS 1.3 (RFC 8446) с отпечатком Chrome.
//!
//! Готовые библиотеки не дают ни отпечатка браузера, ни вмешательства в
//! рукопожатие, которого требует REALITY (подпись session_id ключом обмена).
//! Поэтому рукопожатие — своё, а примитивы — из RustCrypto (ADR-0005).
//! Поддержано то, что нужно клиенту: X25519, AES-GCM и ChaCha20-Poly1305,
//! сертификат Ed25519 сервера REALITY или обычная цепочка сертификатов
//! (`verify`). HelloRetryRequest, TLS 1.2, вход по сертификату клиента и
//! 0-RTT не поддерживаются.

pub mod cert;
pub mod hello;
pub mod keys;
pub mod verify;

use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use subtle::ConstantTimeEq;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use x25519_dalek::{PublicKey, StaticSecret};

use self::hello::{
    EXT_KEY_SHARE, EXT_SUPPORTED_VERSIONS, GROUP_X25519, HelloParams, SESSION_ID_OFFSET,
    VERSION_TLS13, random_bytes,
};
use self::keys::{RecordKey, Schedule, Suite, TAG_LEN};
use crate::error::{EngineError, Result};
use crate::reality::RealityConfig;

pub use self::verify::TlsConfig;

pub const CONTENT_CHANGE_CIPHER_SPEC: u8 = 20;
pub const CONTENT_ALERT: u8 = 21;
pub const CONTENT_HANDSHAKE: u8 = 22;
pub const CONTENT_APPLICATION_DATA: u8 = 23;

const HANDSHAKE_SERVER_HELLO: u8 = 2;
const HANDSHAKE_NEW_SESSION_TICKET: u8 = 4;
const HANDSHAKE_ENCRYPTED_EXTENSIONS: u8 = 8;
const HANDSHAKE_CERTIFICATE: u8 = 11;
const HANDSHAKE_CERTIFICATE_REQUEST: u8 = 13;
const HANDSHAKE_CERTIFICATE_VERIFY: u8 = 15;
const HANDSHAKE_FINISHED: u8 = 20;
const HANDSHAKE_KEY_UPDATE: u8 = 24;
const HANDSHAKE_COMPRESSED_CERTIFICATE: u8 = 25;
/// Сжатие сертификата brotli — единственное, что предлагает ClientHello.
const CERT_COMPRESSION_BROTLI: u16 = 2;

const SIGNATURE_ED25519: u16 = 0x0807;
const ALERT_CLOSE_NOTIFY: u8 = 0;

/// Предел открытого текста записи.
pub const MAX_PLAINTEXT: usize = 16 * 1024;
const MAX_CIPHERTEXT: usize = MAX_PLAINTEXT + 256;
/// Предел сообщения рукопожатия (цепочка сертификатов).
const MAX_HANDSHAKE_MESSAGE: usize = 64 * 1024;

/// SHA-256("HelloRetryRequest") — так сервер помечает повтор приветствия.
const HELLO_RETRY_RANDOM: [u8; 32] = [
    0xcf, 0x21, 0xad, 0x74, 0xe5, 0x9a, 0x61, 0x11, 0xbe, 0x1d, 0x8c, 0x02, 0x1e, 0x65, 0xb8, 0x91,
    0xc2, 0xa2, 0x11, 0x16, 0x7a, 0xbb, 0x8c, 0x5e, 0x07, 0x9e, 0x09, 0xe2, 0xc8, 0xa8, 0x33, 0x9c,
];

fn protocol(message: &'static str) -> EngineError {
    EngineError::Protocol(message)
}

/// Чтение записей с буфером: байты после текущей записи не теряются —
/// Vision забирает их при переходе на прямое копирование.
struct RecordIo<R> {
    inner: R,
    buf: Vec<u8>,
}

impl<R: AsyncRead + Unpin> RecordIo<R> {
    fn new(inner: R) -> Self {
        Self {
            inner,
            buf: Vec::with_capacity(2 * MAX_CIPHERTEXT),
        }
    }

    /// Дочитывает буфер до `len` байт; `false` — поток кончился до них.
    async fn fill(&mut self, len: usize) -> Result<bool> {
        while self.buf.len() < len {
            self.buf.reserve(MAX_CIPHERTEXT);
            if self.inner.read_buf(&mut self.buf).await? == 0 {
                return Ok(false);
            }
        }
        Ok(true)
    }

    async fn read_record(&mut self) -> Result<Option<([u8; 5], Vec<u8>)>> {
        if !self.fill(5).await? {
            if self.buf.is_empty() {
                return Ok(None);
            }
            return Err(std::io::Error::from(std::io::ErrorKind::UnexpectedEof).into());
        }
        let mut header = [0u8; 5];
        header.copy_from_slice(&self.buf[..5]);
        let len = usize::from(u16::from_be_bytes([header[3], header[4]]));
        if len > MAX_CIPHERTEXT {
            return Err(protocol("tls: record too large"));
        }
        if !self.fill(5 + len).await? {
            return Err(std::io::Error::from(std::io::ErrorKind::UnexpectedEof).into());
        }
        let body = self.buf[5..5 + len].to_vec();
        self.buf.drain(..5 + len);
        Ok(Some((header, body)))
    }
}

/// Сборка сообщений рукопожатия из записей (сообщение может занимать
/// несколько записей, запись — нести несколько сообщений).
#[derive(Default)]
struct Messages {
    buf: Vec<u8>,
}

impl Messages {
    fn push(&mut self, data: &[u8]) {
        self.buf.extend_from_slice(data);
    }

    fn next(&mut self) -> Result<Option<Vec<u8>>> {
        if self.buf.len() < 4 {
            return Ok(None);
        }
        let len = u32::from_be_bytes([0, self.buf[1], self.buf[2], self.buf[3]]) as usize;
        if len > MAX_HANDSHAKE_MESSAGE {
            return Err(protocol("tls: handshake message too large"));
        }
        if self.buf.len() < 4 + len {
            return Ok(None);
        }
        Ok(Some(self.buf.drain(..4 + len).collect()))
    }

    fn is_empty(&self) -> bool {
        self.buf.is_empty()
    }
}

fn alert(body: &[u8]) -> Result<()> {
    match body.get(1) {
        Some(&ALERT_CLOSE_NOTIFY) => Ok(()),
        Some(&code) => Err(EngineError::TlsAlert(code)),
        None => Err(protocol("tls: malformed alert")),
    }
}

/// Простой разборщик длин с проверкой границ.
struct Cursor<'a> {
    data: &'a [u8],
}

impl<'a> Cursor<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        if self.data.len() < n {
            return Err(protocol("tls: truncated message"));
        }
        let (head, rest) = self.data.split_at(n);
        self.data = rest;
        Ok(head)
    }

    fn u8(&mut self) -> Result<u8> {
        Ok(self.take(1)?[0])
    }

    fn u16(&mut self) -> Result<u16> {
        let b = self.take(2)?;
        Ok(u16::from_be_bytes([b[0], b[1]]))
    }

    fn u24(&mut self) -> Result<usize> {
        let b = self.take(3)?;
        Ok(u32::from_be_bytes([0, b[0], b[1], b[2]]) as usize)
    }
}

struct ServerHello {
    suite: Suite,
    key: [u8; 32],
}

fn parse_server_hello(message: &[u8], session_id: &[u8]) -> Result<ServerHello> {
    if message.first() != Some(&HANDSHAKE_SERVER_HELLO) {
        return Err(protocol("tls: expected ServerHello"));
    }
    let mut c = Cursor {
        data: &message[4..],
    };
    c.u16()?;
    if c.take(32)? == HELLO_RETRY_RANDOM {
        return Err(protocol("tls: HelloRetryRequest is not supported"));
    }
    let echoed_len = usize::from(c.u8()?);
    let echoed = c.take(echoed_len)?;
    if echoed != session_id {
        return Err(protocol("tls: session id mismatch"));
    }
    let suite = Suite::from_id(c.u16()?).ok_or(protocol("tls: unexpected cipher suite"))?;
    if c.u8()? != 0 {
        return Err(protocol("tls: unexpected compression"));
    }
    let len = usize::from(c.u16()?);
    let mut ext = Cursor { data: c.take(len)? };
    let mut version = None;
    let mut key = None;
    while !ext.data.is_empty() {
        let kind = ext.u16()?;
        let len = usize::from(ext.u16()?);
        let mut data = Cursor {
            data: ext.take(len)?,
        };
        match kind {
            EXT_SUPPORTED_VERSIONS => version = Some(data.u16()?),
            EXT_KEY_SHARE => {
                if data.u16()? != GROUP_X25519 {
                    return Err(protocol("tls: unexpected key share group"));
                }
                let share_len = usize::from(data.u16()?);
                let share = data.take(share_len)?;
                key = Some(
                    <[u8; 32]>::try_from(share)
                        .map_err(|_| protocol("tls: bad X25519 key share"))?,
                );
            }
            _ => {}
        }
    }
    if version != Some(VERSION_TLS13) {
        return Err(protocol("tls: server does not speak TLS 1.3"));
    }
    Ok(ServerHello {
        suite,
        key: key.ok_or(protocol("tls: missing key share"))?,
    })
}

/// Сертификаты из сообщения Certificate: первый — сервера, дальше цепочка.
fn certificates(message: &[u8]) -> Result<Vec<Vec<u8>>> {
    let mut c = Cursor {
        data: &message[4..],
    };
    let context = usize::from(c.u8()?);
    c.take(context)?;
    let list_len = c.u24()?;
    let mut list = Cursor {
        data: c.take(list_len)?,
    };
    let mut out = Vec::new();
    while !list.data.is_empty() {
        let len = list.u24()?;
        out.push(list.take(len)?.to_vec());
        let extensions = usize::from(list.u16()?);
        list.take(extensions)?;
    }
    if out.is_empty() {
        return Err(protocol("tls: empty certificate list"));
    }
    Ok(out)
}

/// Сообщение Certificate из CompressedCertificate (RFC 8879).
fn decompress_certificate(message: &[u8]) -> Result<Vec<u8>> {
    use std::io::Read;
    let mut c = Cursor {
        data: &message[4..],
    };
    if c.u16()? != CERT_COMPRESSION_BROTLI {
        return Err(protocol("tls: unexpected certificate compression"));
    }
    let size = c.u24()?;
    if size > MAX_HANDSHAKE_MESSAGE {
        return Err(protocol("tls: certificate too large"));
    }
    let compressed_len = c.u24()?;
    let compressed = c.take(compressed_len)?;
    let mut body = Vec::with_capacity(size);
    brotli_decompressor::Decompressor::new(compressed, 4096)
        .take(size as u64 + 1)
        .read_to_end(&mut body)
        .map_err(|_| protocol("tls: bad compressed certificate"))?;
    if body.len() != size {
        return Err(protocol("tls: bad compressed certificate"));
    }
    Ok(handshake_message(HANDSHAKE_CERTIFICATE, &body))
}

/// Схема и подпись из CertificateVerify.
fn certificate_verify(message: &[u8]) -> Result<(u16, &[u8])> {
    let mut c = Cursor {
        data: &message[4..],
    };
    let scheme = c.u16()?;
    let len = usize::from(c.u16()?);
    Ok((scheme, c.take(len)?))
}

/// Что подписывает сервер в CertificateVerify (RFC 8446, 4.4.3).
fn signed_content(transcript_hash: &[u8]) -> Vec<u8> {
    let mut signed = vec![0x20u8; 64];
    signed.extend_from_slice(b"TLS 1.3, server CertificateVerify\0");
    signed.extend_from_slice(transcript_hash);
    signed
}

/// Как клиент убеждается, что говорит с нужным сервером.
pub enum Auth<'a> {
    /// Метка в session_id и временный сертификат сервера REALITY.
    Reality(&'a RealityConfig),
    /// Обычный TLS: цепочка сертификатов до корня.
    Certificate(&'a TlsConfig),
}

enum ServerKey {
    Ed25519(VerifyingKey),
    Certificate(Vec<u8>),
}

fn handshake_message(kind: u8, body: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(4 + body.len());
    out.push(kind);
    out.extend_from_slice(&(body.len() as u32).to_be_bytes()[1..]);
    out.extend_from_slice(body);
    out
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Stage {
    EncryptedExtensions,
    Certificate,
    CertificateVerify,
    Finished,
}

/// Рукопожатие TLS 1.3 поверх TCP с ClientHello Chrome. Для REALITY
/// session_id несёт подписанную метку, а сертификат сервера временный;
/// для обычного TLS session_id случайный, а цепочка проверяется до корня.
pub async fn connect(
    stream: TcpStream,
    auth: &Auth<'_>,
    alpn: &[String],
) -> Result<(TlsReader<OwnedReadHalf>, TlsWriter<OwnedWriteHalf>)> {
    let (read, mut write) = stream.into_split();
    let mut io = RecordIo::new(read);

    let secret = StaticSecret::from(random_bytes::<32>()?);
    let public = PublicKey::from(&secret);
    let random = random_bytes::<32>()?;
    let server_name = match auth {
        Auth::Reality(config) => config.server_name.as_str(),
        Auth::Certificate(config) => config.server_name.as_str(),
    };
    let mut client_hello = hello::chrome(&HelloParams {
        server_name,
        alpn,
        random,
        session_id: match auth {
            Auth::Reality(_) => [0; 32],
            Auth::Certificate(_) => random_bytes::<32>()?,
        },
        x25519_public: public.to_bytes(),
    })?;
    let auth_key = match auth {
        Auth::Reality(config) => {
            Some(config.seal_session_id(&mut client_hello, &random, &secret)?)
        }
        Auth::Certificate(_) => None,
    };
    let session_id = client_hello[SESSION_ID_OFFSET..SESSION_ID_OFFSET + 32].to_vec();

    // Первая запись — с версией 0x0301, как у браузеров.
    let len = client_hello.len() as u16;
    let mut record = vec![CONTENT_HANDSHAKE, 0x03, 0x01];
    record.extend_from_slice(&len.to_be_bytes());
    record.extend_from_slice(&client_hello);
    write.write_all(&record).await?;
    let mut transcript = client_hello;

    let mut messages = Messages::default();
    let server_hello = loop {
        if let Some(message) = messages.next()? {
            break message;
        }
        let (header, body) = io
            .read_record()
            .await?
            .ok_or(protocol("tls: closed during handshake"))?;
        match header[0] {
            CONTENT_HANDSHAKE => messages.push(&body),
            CONTENT_ALERT => {
                alert(&body)?;
                return Err(protocol("tls: closed during handshake"));
            }
            _ => return Err(protocol("tls: unexpected record before ServerHello")),
        }
    };
    let hello = parse_server_hello(&server_hello, &session_id)?;
    if !messages.is_empty() {
        // Дальше сообщения идут только зашифрованными.
        return Err(protocol("tls: unexpected plaintext handshake data"));
    }
    transcript.extend_from_slice(&server_hello);

    let shared = secret.diffie_hellman(&PublicKey::from(hello.key));
    if !shared.was_contributory() {
        return Err(protocol("tls: degenerate key share"));
    }
    let suite = hello.suite;
    let schedule = Schedule::new(suite, shared.as_bytes());
    let (client_hs, server_hs) = schedule.handshake(&transcript);
    let mut read_key = RecordKey::new(suite, server_hs.clone());

    let mut stage = Stage::EncryptedExtensions;
    let mut server_key: Option<ServerKey> = None;
    loop {
        let message = loop {
            if let Some(message) = messages.next()? {
                break message;
            }
            let (header, mut body) = io
                .read_record()
                .await?
                .ok_or(protocol("tls: closed during handshake"))?;
            match header[0] {
                // Совместимость с промежуточными узлами: CCS пропускаем.
                CONTENT_CHANGE_CIPHER_SPEC => {}
                CONTENT_APPLICATION_DATA => match read_key.open(&header, &mut body)? {
                    CONTENT_HANDSHAKE => messages.push(&body),
                    CONTENT_ALERT => {
                        alert(&body)?;
                        return Err(protocol("tls: closed during handshake"));
                    }
                    _ => return Err(protocol("tls: unexpected record during handshake")),
                },
                CONTENT_ALERT => {
                    alert(&body)?;
                    return Err(protocol("tls: closed during handshake"));
                }
                _ => return Err(protocol("tls: unexpected record during handshake")),
            }
        };
        match (stage, message[0]) {
            (Stage::EncryptedExtensions, HANDSHAKE_ENCRYPTED_EXTENSIONS) => {
                stage = Stage::Certificate;
            }
            (Stage::Certificate, HANDSHAKE_CERTIFICATE | HANDSHAKE_COMPRESSED_CERTIFICATE) => {
                // В журнал рукопожатия идёт сообщение как есть, сжатое тоже.
                let mut chain = if message[0] == HANDSHAKE_COMPRESSED_CERTIFICATE {
                    certificates(&decompress_certificate(&message)?)?
                } else {
                    certificates(&message)?
                };
                server_key = Some(match (auth, &auth_key) {
                    (Auth::Reality(_), Some(auth_key)) => {
                        let key = RealityConfig::verify_certificate(auth_key, &chain[0])?;
                        ServerKey::Ed25519(
                            VerifyingKey::from_bytes(&key)
                                .map_err(|_| protocol("tls: bad server key"))?,
                        )
                    }
                    (Auth::Certificate(config), _) => {
                        config.verify_chain(&chain)?;
                        ServerKey::Certificate(chain.swap_remove(0))
                    }
                    (Auth::Reality(_), None) => return Err(protocol("tls: reality state")),
                });
                stage = Stage::CertificateVerify;
            }
            (Stage::Certificate, HANDSHAKE_CERTIFICATE_REQUEST) => {
                return Err(protocol("tls: client certificates are not supported"));
            }
            (Stage::CertificateVerify, HANDSHAKE_CERTIFICATE_VERIFY) => {
                let (scheme, signature) = certificate_verify(&message)?;
                let signed = signed_content(&suite.hash(&transcript));
                match server_key
                    .as_ref()
                    .ok_or(protocol("tls: missing certificate"))?
                {
                    ServerKey::Ed25519(key) => {
                        if scheme != SIGNATURE_ED25519 {
                            return Err(protocol("tls: unexpected signature scheme"));
                        }
                        let signature = Signature::from_slice(signature)
                            .map_err(|_| protocol("tls: bad signature"))?;
                        key.verify(&signed, &signature)
                            .map_err(|_| protocol("tls: CertificateVerify signature is invalid"))?;
                    }
                    ServerKey::Certificate(leaf) => {
                        verify::verify_signature(leaf, scheme, &signed, signature)?;
                    }
                }
                stage = Stage::Finished;
            }
            (Stage::Finished, HANDSHAKE_FINISHED) => {
                let expected = suite.finished(&server_hs, &transcript);
                if !bool::from(expected.ct_eq(&message[4..])) {
                    return Err(protocol("tls: server Finished is invalid"));
                }
                transcript.extend_from_slice(&message);
                break;
            }
            _ => return Err(protocol("tls: unexpected handshake message")),
        }
        transcript.extend_from_slice(&message);
    }
    if !messages.is_empty() {
        return Err(protocol("tls: data after server Finished"));
    }

    let (client_ap, server_ap) = schedule.application(&transcript);
    let finished = handshake_message(HANDSHAKE_FINISHED, &suite.finished(&client_hs, &transcript));
    // CCS для совместимости (session_id не пустой), затем Finished.
    let mut flight = vec![CONTENT_CHANGE_CIPHER_SPEC, 0x03, 0x03, 0x00, 0x01, 0x01];
    RecordKey::new(suite, client_hs).seal(CONTENT_HANDSHAKE, &finished, &mut flight)?;
    write.write_all(&flight).await?;

    Ok((
        TlsReader {
            io,
            key: RecordKey::new(suite, server_ap),
            messages: Messages::default(),
        },
        TlsWriter {
            inner: write,
            key: RecordKey::new(suite, client_ap),
        },
    ))
}

/// Чтение данных приложения после рукопожатия.
pub struct TlsReader<R> {
    io: RecordIo<R>,
    key: RecordKey,
    messages: Messages,
}

impl<R: AsyncRead + Unpin> TlsReader<R> {
    /// Открытый текст следующей записи с данными; `None` — конец потока.
    pub async fn read_record(&mut self) -> Result<Option<Vec<u8>>> {
        loop {
            let Some((header, mut body)) = self.io.read_record().await? else {
                return Ok(None);
            };
            match header[0] {
                CONTENT_APPLICATION_DATA => match self.key.open(&header, &mut body)? {
                    CONTENT_APPLICATION_DATA => {
                        if !body.is_empty() {
                            return Ok(Some(body));
                        }
                    }
                    CONTENT_HANDSHAKE => self.post_handshake(&body)?,
                    CONTENT_ALERT => {
                        alert(&body)?;
                        return Ok(None);
                    }
                    _ => return Err(protocol("tls: unexpected record type")),
                },
                CONTENT_ALERT => {
                    alert(&body)?;
                    return Ok(None);
                }
                _ => return Err(protocol("tls: unexpected record type")),
            }
        }
    }

    fn post_handshake(&mut self, data: &[u8]) -> Result<()> {
        self.messages.push(data);
        while let Some(message) = self.messages.next()? {
            match message[0] {
                HANDSHAKE_NEW_SESSION_TICKET => {}
                HANDSHAKE_KEY_UPDATE => {
                    self.key = self.key.updated();
                    if message.get(4) == Some(&1) {
                        // Ответный KeyUpdate требует записи; серверы на Go
                        // их не запрашивают.
                        tracing::debug!("tls: peer requested a key update");
                    }
                }
                _ => return Err(protocol("tls: unexpected post-handshake message")),
            }
        }
        Ok(())
    }

    /// Нижний поток и уже прочитанные, но не разобранные байты.
    pub fn into_raw(self) -> (R, Vec<u8>) {
        (self.io.inner, self.io.buf)
    }
}

/// Запись данных приложения.
pub struct TlsWriter<W> {
    inner: W,
    key: RecordKey,
}

impl<W: AsyncWrite + Unpin> TlsWriter<W> {
    pub async fn write_all(&mut self, data: &[u8]) -> Result<()> {
        if data.is_empty() {
            return Ok(());
        }
        let records = data.len().div_ceil(MAX_PLAINTEXT);
        let mut out = Vec::with_capacity(data.len() + records * (5 + 1 + TAG_LEN));
        for chunk in data.chunks(MAX_PLAINTEXT) {
            self.key.seal(CONTENT_APPLICATION_DATA, chunk, &mut out)?;
        }
        self.inner.write_all(&out).await?;
        Ok(())
    }

    pub fn into_inner(self) -> W {
        self.inner
    }
}
