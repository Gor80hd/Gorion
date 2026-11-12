//! XTLS Vision (`xtls-rprx-vision`) для VLESS поверх TLS.
//!
//! Первые пакеты внутреннего потока обёрнуты в кадры с выравниванием, чтобы
//! длины рукопожатия внутреннего TLS не выдавали «TLS внутри TLS». Когда
//! внутри идёт TLS 1.3 и начались данные приложения, стороны переходят на
//! прямое копирование: внешний TLS больше не шифрует уже зашифрованное.
//! Эталон: sing-vmess `vless/vision.go` (сервер sing-box) и Xray `proxy.go`.
//!
//! Кадр: [UUID 16 — только первый] [команда] [длина данных u16]
//! [длина выравнивания u16] [данные] [нули].

use std::sync::{Arc, Mutex, MutexGuard};

use crate::error::{EngineError, Result};
use crate::tls::hello::random_bytes;

pub const COMMAND_CONTINUE: u8 = 0;
pub const COMMAND_END: u8 = 1;
pub const COMMAND_DIRECT: u8 = 2;

const TLS13_SUPPORTED_VERSIONS: [u8; 6] = [0x00, 0x2b, 0x00, 0x02, 0x03, 0x04];
const TLS_APPLICATION_DATA_START: [u8; 3] = [0x17, 0x03, 0x03];
/// Размер буфера Xray: кадр с заголовком в него помещается.
const XRAY_BUFFER: usize = 8192;
const RESHAPE_LIMIT: usize = XRAY_BUFFER - 21;
/// Сколько пакетов смотреть, пока не стало ясно, что внутри.
const PACKETS_TO_FILTER: i32 = 8;

/// Наблюдение за внутренним потоком; общее для чтения и записи.
#[derive(Debug)]
pub struct Filter {
    remaining: i32,
    is_tls: bool,
    is_tls12_or_above: bool,
    remaining_server_hello: i32,
    cipher: u16,
    enable_xtls: bool,
}

impl Default for Filter {
    fn default() -> Self {
        Self {
            remaining: PACKETS_TO_FILTER,
            is_tls: false,
            is_tls12_or_above: false,
            remaining_server_hello: -1,
            cipher: 0,
            enable_xtls: false,
        }
    }
}

impl Filter {
    fn observe(&mut self, b: &[u8]) {
        self.remaining -= 1;
        if b.len() > 6 {
            if b[0] == 22 && b[1] == 3 && b[2] == 3 {
                self.is_tls = true;
                if b[5] == 2 {
                    self.is_tls12_or_above = true;
                    self.remaining_server_hello = ((i32::from(b[3]) << 8) | i32::from(b[4])) + 5;
                    if b.len() >= 79 && self.remaining_server_hello >= 79 {
                        let session_id_len = usize::from(b[43]);
                        if b.len() >= 43 + session_id_len + 3 {
                            let at = 43 + session_id_len + 1;
                            self.cipher = u16::from_be_bytes([b[at], b[at + 1]]);
                        }
                    }
                }
            } else if b[0] == 22 && b[1] == 3 && b[5] == 1 {
                self.is_tls = true;
            }
        }
        if self.remaining_server_hello > 0 {
            let end = (self.remaining_server_hello as usize).min(b.len());
            self.remaining_server_hello -= end as i32;
            if b[..end]
                .windows(TLS13_SUPPORTED_VERSIONS.len())
                .any(|w| w == TLS13_SUPPORTED_VERSIONS)
            {
                // TLS_AES_128_CCM_8_SHA256 (0x1305) Vision не пропускает напрямую.
                if (0x1301..=0x1304).contains(&self.cipher) {
                    self.enable_xtls = true;
                }
                self.remaining = 0;
            } else if self.remaining_server_hello == 0 {
                // TLS 1.2: прямого копирования не будет.
                self.remaining = 0;
            }
        }
    }
}

pub type SharedFilter = Arc<Mutex<Filter>>;

fn lock(filter: &SharedFilter) -> MutexGuard<'_, Filter> {
    filter
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn random_below(bound: u16) -> Result<usize> {
    let bytes: [u8; 2] = random_bytes()?;
    Ok(usize::from(u16::from_be_bytes(bytes) % bound))
}

/// Что отправить: сначала `tls` через внешний TLS, затем `raw` — напрямую.
#[derive(Debug, Default)]
pub struct Encoded {
    pub tls: Vec<u8>,
    pub raw: Vec<u8>,
    /// После `tls` запись переходит на прямое копирование.
    pub switch_to_raw: bool,
}

pub struct VisionWriter {
    uuid: [u8; 16],
    write_uuid: bool,
    is_padding: bool,
    direct: bool,
    filter: SharedFilter,
}

impl VisionWriter {
    pub fn new(uuid: [u8; 16], filter: SharedFilter) -> Self {
        Self {
            uuid,
            write_uuid: true,
            is_padding: true,
            direct: false,
            filter,
        }
    }

    /// Кадр без данных: клиент молчит, а запрос уже пора отправить (Xray).
    pub fn empty_frame(&mut self) -> Result<Vec<u8>> {
        let mut out = Vec::new();
        self.frame(&[], COMMAND_CONTINUE, true, &mut out)?;
        Ok(out)
    }

    pub fn encode(&mut self, data: &[u8]) -> Result<Encoded> {
        let (is_tls, is_tls12_or_above, enable_xtls, remaining) = {
            let mut filter = lock(&self.filter);
            if filter.remaining > 0 {
                filter.observe(data);
            }
            (
                filter.is_tls,
                filter.is_tls12_or_above,
                filter.enable_xtls,
                filter.remaining,
            )
        };
        let mut out = Encoded::default();
        if !self.is_padding {
            if self.direct {
                out.raw = data.to_vec();
            } else {
                out.tls = data.to_vec();
            }
            return Ok(out);
        }
        let chunks = reshape(data);
        for (i, chunk) in chunks.iter().enumerate() {
            if is_tls && chunk.len() > 6 && chunk[..3] == TLS_APPLICATION_DATA_START {
                let mut command = COMMAND_END;
                if enable_xtls {
                    self.direct = true;
                    out.switch_to_raw = true;
                    command = COMMAND_DIRECT;
                }
                self.is_padding = false;
                self.frame(chunk, command, is_tls, &mut out.tls)?;
                let rest = if self.direct {
                    &mut out.raw
                } else {
                    &mut out.tls
                };
                for chunk in &chunks[i + 1..] {
                    rest.extend_from_slice(chunk);
                }
                return Ok(out);
            } else if !is_tls12_or_above && remaining <= 1 {
                // Внутри не TLS: выравнивание заканчивается.
                self.is_padding = false;
                self.frame(chunk, COMMAND_END, is_tls, &mut out.tls)?;
                for chunk in &chunks[i + 1..] {
                    out.tls.extend_from_slice(chunk);
                }
                return Ok(out);
            }
            self.frame(chunk, COMMAND_CONTINUE, is_tls, &mut out.tls)?;
        }
        Ok(out)
    }

    fn frame(&mut self, content: &[u8], command: u8, long: bool, out: &mut Vec<u8>) -> Result<()> {
        let len = content.len();
        let mut padding = if len < 900 && long {
            random_below(500)? + 900 - len
        } else {
            random_below(256)?
        };
        // Кадр с заголовком помещается в буфер Xray.
        padding = padding.min(XRAY_BUFFER.saturating_sub(21 + len));
        if self.write_uuid {
            out.extend_from_slice(&self.uuid);
            self.write_uuid = false;
        }
        out.push(command);
        out.extend_from_slice(&(len as u16).to_be_bytes());
        out.extend_from_slice(&(padding as u16).to_be_bytes());
        out.extend_from_slice(content);
        out.resize(out.len() + padding, 0);
        Ok(())
    }
}

/// Делит большой кусок по границе записи TLS, как sing-box.
fn reshape(data: &[u8]) -> Vec<&[u8]> {
    if data.len() < RESHAPE_LIMIT {
        return vec![data];
    }
    let mut out = Vec::new();
    let mut rest = data;
    while rest.len() >= RESHAPE_LIMIT {
        let index = rest
            .windows(3)
            .rposition(|w| w == TLS_APPLICATION_DATA_START)
            .filter(|&i| (32..=RESHAPE_LIMIT).contains(&i))
            .unwrap_or(XRAY_BUFFER / 2);
        let (head, tail) = rest.split_at(index);
        out.push(head);
        rest = tail;
    }
    out.push(rest);
    out
}

pub struct VisionReader {
    uuid: [u8; 16],
    within_padding: bool,
    remaining_content: i32,
    remaining_padding: i32,
    command: u8,
    header: [u8; 5],
    header_len: usize,
    filter: SharedFilter,
}

impl VisionReader {
    pub fn new(uuid: [u8; 16], filter: SharedFilter) -> Self {
        Self {
            uuid,
            within_padding: true,
            remaining_content: -1,
            remaining_padding: -1,
            command: COMMAND_CONTINUE,
            header: [0; 5],
            header_len: 0,
            filter,
        }
    }

    /// Снимает кадры с куска. `true` — сервер перешёл на прямое копирование:
    /// дальше байты идут мимо внешнего TLS.
    pub fn decode(&mut self, chunk: &[u8]) -> Result<(Vec<u8>, bool)> {
        let filtering = lock(&self.filter).remaining > 0;
        let mut direct = false;
        let out = if self.within_padding || filtering {
            let out = self.unpad(chunk);
            if self.remaining_content == 0 && self.remaining_padding == 0 {
                match self.command {
                    COMMAND_CONTINUE => self.within_padding = true,
                    COMMAND_END | COMMAND_DIRECT => {
                        self.within_padding = false;
                        direct = self.command == COMMAND_DIRECT;
                        self.remaining_content = -1;
                        self.remaining_padding = -1;
                    }
                    _ => return Err(EngineError::Protocol("vision: unknown command")),
                }
            } else {
                self.within_padding = self.remaining_content > 0 || self.remaining_padding > 0;
            }
            out
        } else {
            chunk.to_vec()
        };
        if filtering && !out.is_empty() {
            lock(&self.filter).observe(&out);
        }
        Ok((out, direct))
    }

    fn unpad(&mut self, chunk: &[u8]) -> Vec<u8> {
        let mut i = 0;
        if self.remaining_content == -1 && self.remaining_padding == -1 {
            if chunk.len() >= 21 && chunk[..16] == self.uuid {
                i = 16;
                self.remaining_content = 0;
                self.remaining_padding = 0;
                self.command = COMMAND_CONTINUE;
            } else {
                return chunk.to_vec();
            }
        }
        let mut out = Vec::with_capacity(chunk.len());
        while i < chunk.len() {
            if self.remaining_content <= 0 && self.remaining_padding <= 0 {
                if self.command != COMMAND_CONTINUE {
                    // После последнего кадра остаток — уже без обёртки.
                    out.extend_from_slice(&chunk[i..]);
                    break;
                }
                let n = (5 - self.header_len).min(chunk.len() - i);
                self.header[self.header_len..self.header_len + n].copy_from_slice(&chunk[i..i + n]);
                self.header_len += n;
                i += n;
                if self.header_len < 5 {
                    break;
                }
                self.header_len = 0;
                self.command = self.header[0];
                self.remaining_content =
                    i32::from(u16::from_be_bytes([self.header[1], self.header[2]]));
                self.remaining_padding =
                    i32::from(u16::from_be_bytes([self.header[3], self.header[4]]));
            } else if self.remaining_content > 0 {
                let n = (self.remaining_content as usize).min(chunk.len() - i);
                out.extend_from_slice(&chunk[i..i + n]);
                self.remaining_content -= n as i32;
                i += n;
            } else {
                let n = (self.remaining_padding as usize).min(chunk.len() - i);
                self.remaining_padding -= n as i32;
                i += n;
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    const UUID: [u8; 16] = [0x11; 16];

    fn pair() -> (VisionWriter, VisionReader) {
        (
            VisionWriter::new(UUID, SharedFilter::default()),
            VisionReader::new(UUID, SharedFilter::default()),
        )
    }

    /// Запись TLS: заголовок и тело.
    fn record(kind: u8, body: &[u8]) -> Vec<u8> {
        let mut out = vec![kind, 3, 3];
        out.extend_from_slice(&(body.len() as u16).to_be_bytes());
        out.extend_from_slice(body);
        out
    }

    #[test]
    fn plain_payload_round_trips_and_ends_padding() {
        let (mut writer, mut reader) = pair();
        let mut sent = Vec::new();
        let mut received = Vec::new();
        for i in 0..10u8 {
            let data = vec![i; 100 + usize::from(i) * 1000];
            let encoded = writer.encode(&data).unwrap();
            assert!(encoded.raw.is_empty() && !encoded.switch_to_raw);
            // Кадры могут прийти кусками любой длины.
            for piece in encoded.tls.chunks(777) {
                let (out, direct) = reader.decode(piece).unwrap();
                assert!(!direct);
                received.extend_from_slice(&out);
            }
            sent.extend_from_slice(&data);
        }
        assert_eq!(sent, received);
        assert!(!writer.is_padding, "padding ends for non-TLS traffic");
    }

    #[test]
    fn inner_tls13_switches_to_direct() {
        let filter = SharedFilter::default();
        let mut writer = VisionWriter::new(UUID, filter.clone());
        let mut client_hello = vec![1, 0, 1, 0];
        client_hello.resize(300, 0);
        let hello = record(22, &client_hello);
        let first = writer.encode(&hello).unwrap();
        assert!(first.tls.len() >= 16 + 5 + hello.len() + 900 - hello.len());

        // Ответ сервера: ServerHello TLS 1.3 с шифром 0x1301 — его видит чтение.
        let mut server_hello = vec![2, 0, 0, 0x50, 3, 3];
        server_hello.extend_from_slice(&[0; 32]);
        server_hello.push(0); // session_id
        server_hello.extend_from_slice(&[0x13, 0x01, 0]);
        server_hello.extend_from_slice(&[0, 6]);
        server_hello.extend_from_slice(&TLS13_SUPPORTED_VERSIONS);
        server_hello.resize(84, 0);
        lock(&filter).observe(&record(22, &server_hello));
        assert!(lock(&filter).enable_xtls);

        // Кусок с данными приложения — последний кадр с командой «напрямую»;
        // всё, что пишется после, идёт мимо внешнего TLS.
        let app = [record(23, &[7; 50]), record(23, &[8; 50])].concat();
        let encoded = writer.encode(&app).unwrap();
        assert!(encoded.switch_to_raw);
        assert_eq!(encoded.tls[0], COMMAND_DIRECT);
        assert!(encoded.raw.is_empty());
        let after = writer.encode(b"later").unwrap();
        assert_eq!(after.raw, b"later");
        assert!(after.tls.is_empty() && !after.switch_to_raw);

        let mut reader = VisionReader::new(UUID, SharedFilter::default());
        let (out, direct) = reader.decode(&first.tls).unwrap();
        assert_eq!(out, hello);
        assert!(!direct);
        let (out, direct) = reader.decode(&encoded.tls).unwrap();
        assert_eq!(out, app);
        assert!(direct);
    }

    #[test]
    fn reshape_splits_at_record_boundary() {
        let mut data = vec![0u8; 5000];
        data.extend_from_slice(&record(23, &[1; 6000]));
        let parts = reshape(&data);
        assert_eq!(parts.len(), 2);
        assert_eq!(parts[0].len(), 5000);
        assert_eq!(parts.concat(), data);
    }
}
