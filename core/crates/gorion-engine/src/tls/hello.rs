//! ClientHello как у Chrome (BoringSSL): набор и порядок шифров, GREASE,
//! перемешанные расширения, ECH GREASE и выравнивание. Сверено с пресетом
//! uTLS `HelloChrome_133`; X25519MLKEM768 не предлагается — так же делает
//! клиент REALITY в sing-box, а сервер REALITY в sing-box его не понимает.

use std::net::IpAddr;

use x25519_dalek::{PublicKey, StaticSecret};

use super::keys::{TLS_AES_128_GCM_SHA256, TLS_AES_256_GCM_SHA384, TLS_CHACHA20_POLY1305_SHA256};
use crate::error::Result;

pub const HANDSHAKE_CLIENT_HELLO: u8 = 1;
pub const GROUP_X25519: u16 = 0x001d;
const GROUP_SECP256R1: u16 = 0x0017;
const GROUP_SECP384R1: u16 = 0x0018;
pub const VERSION_TLS13: u16 = 0x0304;
const VERSION_TLS12: u16 = 0x0303;

/// Смещение session_id в сообщении: заголовок 4 + версия 2 + random 32 + длина 1.
pub const SESSION_ID_OFFSET: usize = 39;

const EXT_SERVER_NAME: u16 = 0;
const EXT_STATUS_REQUEST: u16 = 5;
const EXT_SUPPORTED_GROUPS: u16 = 10;
const EXT_EC_POINT_FORMATS: u16 = 11;
const EXT_SIGNATURE_ALGORITHMS: u16 = 13;
const EXT_ALPN: u16 = 16;
const EXT_SCT: u16 = 18;
const EXT_PADDING: u16 = 21;
const EXT_EXTENDED_MASTER_SECRET: u16 = 23;
const EXT_COMPRESS_CERTIFICATE: u16 = 27;
const EXT_SESSION_TICKET: u16 = 35;
pub const EXT_SUPPORTED_VERSIONS: u16 = 43;
const EXT_PSK_MODES: u16 = 45;
pub const EXT_KEY_SHARE: u16 = 51;
const EXT_APPLICATION_SETTINGS: u16 = 0x44cd;
const EXT_ECH: u16 = 0xfe0d;
const EXT_RENEGOTIATION_INFO: u16 = 0xff01;

const CIPHER_SUITES: [u16; 15] = [
    TLS_AES_128_GCM_SHA256,
    TLS_AES_256_GCM_SHA384,
    TLS_CHACHA20_POLY1305_SHA256,
    0xc02b,
    0xc02f,
    0xc02c,
    0xc030,
    0xcca9,
    0xcca8,
    0xc013,
    0xc014,
    0x009c,
    0x009d,
    0x002f,
    0x0035,
];

const SIGNATURE_ALGORITHMS: [u16; 8] = [
    0x0403, 0x0804, 0x0401, 0x0503, 0x0805, 0x0501, 0x0806, 0x0601,
];

/// Длины полезной нагрузки ECH GREASE у Chrome: 128..224 + тег 16.
const ECH_PAYLOAD_LENS: [usize; 4] = [144, 176, 208, 240];

pub struct HelloParams<'a> {
    pub server_name: &'a str,
    pub alpn: &'a [String],
    pub random: [u8; 32],
    pub session_id: [u8; 32],
    pub x25519_public: [u8; 32],
}

pub fn random_bytes<const N: usize>() -> Result<[u8; N]> {
    let mut out = [0u8; N];
    getrandom::fill(&mut out).map_err(|e| std::io::Error::other(e.to_string()))?;
    Ok(out)
}

/// Значения GREASE (RFC 8701): 0x0A0A, 0x1A1A, … 0xFAFA.
fn grease(seed: u8) -> u16 {
    let byte = (seed & 0xf0) | 0x0a;
    u16::from_be_bytes([byte, byte])
}

fn put_u16(out: &mut Vec<u8>, value: u16) {
    out.extend_from_slice(&value.to_be_bytes());
}

fn put_u8_prefixed(out: &mut Vec<u8>, data: &[u8]) {
    out.push(data.len() as u8);
    out.extend_from_slice(data);
}

fn put_u16_prefixed(out: &mut Vec<u8>, data: &[u8]) {
    put_u16(out, data.len() as u16);
    out.extend_from_slice(data);
}

fn put_extension(out: &mut Vec<u8>, kind: u16, data: &[u8]) {
    put_u16(out, kind);
    put_u16_prefixed(out, data);
}

/// Собирает сообщение ClientHello вместе с заголовком рукопожатия.
pub fn chrome(params: &HelloParams<'_>) -> Result<Vec<u8>> {
    let seeds: [u8; 8] = random_bytes()?;
    let grease_cipher = grease(seeds[0]);
    let grease_group = grease(seeds[1]);
    let grease_version = grease(seeds[2]);
    let grease_ext1 = grease(seeds[3]);
    let mut grease_ext2 = grease(seeds[4]);
    if grease_ext2 == grease_ext1 {
        // Как BoringSSL: два GREASE-расширения не совпадают.
        grease_ext2 ^= 0x1010;
    }

    let mut extensions: Vec<(u16, Vec<u8>)> = Vec::with_capacity(16);
    if params.server_name.parse::<IpAddr>().is_err() && !params.server_name.is_empty() {
        let name = params.server_name.as_bytes();
        let mut entry = vec![0u8];
        put_u16_prefixed(&mut entry, name);
        let mut data = Vec::new();
        put_u16_prefixed(&mut data, &entry);
        extensions.push((EXT_SERVER_NAME, data));
    }
    extensions.push((EXT_EXTENDED_MASTER_SECRET, Vec::new()));
    extensions.push((EXT_RENEGOTIATION_INFO, vec![0]));
    {
        let mut groups = Vec::new();
        for group in [grease_group, GROUP_X25519, GROUP_SECP256R1, GROUP_SECP384R1] {
            put_u16(&mut groups, group);
        }
        let mut data = Vec::new();
        put_u16_prefixed(&mut data, &groups);
        extensions.push((EXT_SUPPORTED_GROUPS, data));
    }
    extensions.push((EXT_EC_POINT_FORMATS, vec![1, 0]));
    extensions.push((EXT_SESSION_TICKET, Vec::new()));
    if !params.alpn.is_empty() {
        let mut list = Vec::new();
        for protocol in params.alpn {
            put_u8_prefixed(&mut list, protocol.as_bytes());
        }
        let mut data = Vec::new();
        put_u16_prefixed(&mut data, &list);
        extensions.push((EXT_ALPN, data));
    }
    extensions.push((EXT_STATUS_REQUEST, vec![1, 0, 0, 0, 0]));
    {
        let mut algorithms = Vec::new();
        for algorithm in SIGNATURE_ALGORITHMS {
            put_u16(&mut algorithms, algorithm);
        }
        let mut data = Vec::new();
        put_u16_prefixed(&mut data, &algorithms);
        extensions.push((EXT_SIGNATURE_ALGORITHMS, data));
    }
    extensions.push((EXT_SCT, Vec::new()));
    {
        let mut shares = Vec::new();
        put_u16(&mut shares, grease_group);
        put_u16_prefixed(&mut shares, &[0]);
        put_u16(&mut shares, GROUP_X25519);
        put_u16_prefixed(&mut shares, &params.x25519_public);
        let mut data = Vec::new();
        put_u16_prefixed(&mut data, &shares);
        extensions.push((EXT_KEY_SHARE, data));
    }
    extensions.push((EXT_PSK_MODES, vec![1, 1]));
    {
        let mut versions = Vec::new();
        for version in [grease_version, VERSION_TLS13, VERSION_TLS12] {
            put_u16(&mut versions, version);
        }
        let mut data = Vec::new();
        put_u8_prefixed(&mut data, &versions);
        extensions.push((EXT_SUPPORTED_VERSIONS, data));
    }
    // brotli
    extensions.push((EXT_COMPRESS_CERTIFICATE, vec![2, 0, 2]));
    if params.alpn.iter().any(|p| p == "h2") {
        let mut list = Vec::new();
        put_u8_prefixed(&mut list, b"h2");
        let mut data = Vec::new();
        put_u16_prefixed(&mut data, &list);
        extensions.push((EXT_APPLICATION_SETTINGS, data));
    }
    extensions.push((EXT_ECH, ech_grease(seeds[5], seeds[6])?));

    shuffle(&mut extensions)?;

    let mut body = Vec::with_capacity(640);
    put_u16(&mut body, VERSION_TLS12);
    body.extend_from_slice(&params.random);
    put_u8_prefixed(&mut body, &params.session_id);
    let mut ciphers = Vec::with_capacity(32);
    put_u16(&mut ciphers, grease_cipher);
    for suite in CIPHER_SUITES {
        put_u16(&mut ciphers, suite);
    }
    put_u16_prefixed(&mut body, &ciphers);
    put_u8_prefixed(&mut body, &[0]);

    let mut ext_bytes = Vec::with_capacity(600);
    put_extension(&mut ext_bytes, grease_ext1, &[]);
    for (kind, data) in &extensions {
        put_extension(&mut ext_bytes, *kind, data);
    }
    put_extension(&mut ext_bytes, grease_ext2, &[0]);
    // Выравнивание BoringSSL: сообщение длиной 256..511 добивается до 512.
    let unpadded = 4 + body.len() + 2 + ext_bytes.len();
    if unpadded > 0xff && unpadded < 0x200 {
        let mut padding = 0x200 - unpadded;
        if padding >= 5 {
            padding -= 4;
        } else {
            padding = 1;
        }
        put_extension(&mut ext_bytes, EXT_PADDING, &vec![0; padding]);
    }
    put_u16_prefixed(&mut body, &ext_bytes);

    let mut message = Vec::with_capacity(4 + body.len());
    message.push(HANDSHAKE_CLIENT_HELLO);
    message.extend_from_slice(&(body.len() as u32).to_be_bytes()[1..]);
    message.extend_from_slice(&body);
    Ok(message)
}

/// Расширение ECH GREASE: правдоподобная внешняя ClientHello без настоящего ECH.
fn ech_grease(config_id: u8, size_seed: u8) -> Result<Vec<u8>> {
    let secret = StaticSecret::from(random_bytes::<32>()?);
    let enc = PublicKey::from(&secret);
    let payload_len = ECH_PAYLOAD_LENS[usize::from(size_seed) % ECH_PAYLOAD_LENS.len()];
    let mut payload = vec![0u8; payload_len];
    getrandom::fill(&mut payload).map_err(|e| std::io::Error::other(e.to_string()))?;
    let mut data = vec![0u8]; // outer
    put_u16(&mut data, 0x0001); // HKDF-SHA256
    put_u16(&mut data, 0x0001); // AES-128-GCM
    data.push(config_id);
    put_u16_prefixed(&mut data, enc.as_bytes());
    put_u16_prefixed(&mut data, &payload);
    Ok(data)
}

/// Случайная перестановка Фишера — Йетса: Chrome перемешивает расширения.
fn shuffle<T>(items: &mut [T]) -> Result<()> {
    let seeds: [u8; 64] = random_bytes()?;
    for i in (1..items.len()).rev() {
        let r = u16::from_be_bytes([seeds[2 * i], seeds[2 * i + 1]]);
        items.swap(i, usize::from(r) % (i + 1));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    fn extensions(message: &[u8]) -> Vec<(u16, Vec<u8>)> {
        let body = &message[4..];
        let mut p = 2 + 32;
        p += 1 + usize::from(body[p]);
        p += 2 + usize::from(u16::from_be_bytes([body[p], body[p + 1]]));
        p += 1 + usize::from(body[p]);
        let total = usize::from(u16::from_be_bytes([body[p], body[p + 1]]));
        p += 2;
        assert_eq!(p + total, body.len());
        let mut out = Vec::new();
        while p < body.len() {
            let kind = u16::from_be_bytes([body[p], body[p + 1]]);
            let len = usize::from(u16::from_be_bytes([body[p + 2], body[p + 3]]));
            out.push((kind, body[p + 4..p + 4 + len].to_vec()));
            p += 4 + len;
        }
        out
    }

    #[test]
    fn chrome_hello_shape() {
        let alpn = vec!["h2".to_owned(), "http/1.1".to_owned()];
        let params = HelloParams {
            server_name: "www.example.com",
            alpn: &alpn,
            random: [7; 32],
            session_id: [9; 32],
            x25519_public: [5; 32],
        };
        let message = chrome(&params).unwrap();
        assert_eq!(message[0], HANDSHAKE_CLIENT_HELLO);
        let len = u32::from_be_bytes([0, message[1], message[2], message[3]]) as usize;
        assert_eq!(len + 4, message.len());
        assert_eq!(message[SESSION_ID_OFFSET - 1], 32);
        assert_eq!(
            &message[SESSION_ID_OFFSET..SESSION_ID_OFFSET + 32],
            &[9; 32]
        );
        // Длина вне окна выравнивания BoringSSL.
        assert!(message.len() >= 0x200 || message.len() <= 0xff);

        let exts = extensions(&message);
        let kinds: Vec<u16> = exts.iter().map(|(k, _)| *k).collect();
        // GREASE первым и последним, ключ X25519 на месте.
        assert_eq!(kinds[0] & 0x0f0f, 0x0a0a);
        let last = kinds.iter().rposition(|k| k & 0x0f0f == 0x0a0a).unwrap();
        assert!(last >= kinds.len() - 2);
        for kind in [
            EXT_SERVER_NAME,
            EXT_KEY_SHARE,
            EXT_SUPPORTED_VERSIONS,
            EXT_ECH,
            EXT_APPLICATION_SETTINGS,
            EXT_ALPN,
        ] {
            assert!(kinds.contains(&kind), "missing {kind:#x}");
        }
        let key_share = &exts.iter().find(|(k, _)| *k == EXT_KEY_SHARE).unwrap().1;
        assert!(key_share.windows(32).any(|w| w == [5; 32]));
    }

    #[test]
    fn extensions_are_shuffled() {
        let alpn = vec!["h2".to_owned()];
        let params = HelloParams {
            server_name: "a.example",
            alpn: &alpn,
            random: [1; 32],
            session_id: [0; 32],
            x25519_public: [2; 32],
        };
        let orders: std::collections::HashSet<Vec<u16>> = (0..8)
            .map(|_| {
                extensions(&chrome(&params).unwrap())
                    .into_iter()
                    .map(|(k, _)| k)
                    .filter(|k| k & 0x0f0f != 0x0a0a)
                    .collect()
            })
            .collect();
        assert!(orders.len() > 1);
    }
}
