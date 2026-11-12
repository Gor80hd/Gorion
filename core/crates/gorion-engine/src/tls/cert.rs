//! Минимальный разбор сертификата X.509 (DER): ключ Ed25519 и подпись.
//! Большего для REALITY не нужно; полную проверку цепочки сделает webpki,
//! когда появится обычный TLS со своим отпечатком.

use crate::error::{EngineError, Result};

const SEQUENCE: u8 = 0x30;
const BIT_STRING: u8 = 0x03;
const OID: u8 = 0x06;
const ED25519_OID: &[u8] = &[0x2b, 0x65, 0x70];

fn bad() -> EngineError {
    EngineError::Protocol("tls: malformed certificate")
}

/// Один элемент DER: (тег, содержимое, остаток).
fn element(input: &[u8]) -> Result<(u8, &[u8], &[u8])> {
    let (&tag, rest) = input.split_first().ok_or_else(bad)?;
    let (&first, rest) = rest.split_first().ok_or_else(bad)?;
    let (len, rest) = if first < 0x80 {
        (usize::from(first), rest)
    } else {
        let count = usize::from(first & 0x7f);
        if count == 0 || count > 3 || rest.len() < count {
            return Err(bad());
        }
        let len = rest[..count]
            .iter()
            .fold(0usize, |acc, &b| (acc << 8) | usize::from(b));
        (len, &rest[count..])
    };
    if rest.len() < len {
        return Err(bad());
    }
    Ok((tag, &rest[..len], &rest[len..]))
}

fn expect(input: &[u8], tag: u8) -> Result<(&[u8], &[u8])> {
    let (found, content, rest) = element(input)?;
    if found != tag {
        return Err(bad());
    }
    Ok((content, rest))
}

/// Ключ и подпись сертификата Ed25519.
#[derive(Debug, PartialEq, Eq)]
pub struct Ed25519Cert<'a> {
    pub public_key: &'a [u8; 32],
    pub signature: &'a [u8],
}

/// Достаёт ключ Ed25519 и значение подписи. Другой тип ключа — `None`.
pub fn ed25519(der: &[u8]) -> Result<Option<Ed25519Cert<'_>>> {
    let (cert, _) = expect(der, SEQUENCE)?;
    let (tbs, rest) = expect(cert, SEQUENCE)?;
    let (_algorithm, rest) = expect(rest, SEQUENCE)?;
    let (signature, _) = expect(rest, BIT_STRING)?;
    let signature = signature.strip_prefix(&[0]).ok_or_else(bad)?;

    // tbsCertificate: [0] версия, серийный номер, алгоритм, издатель,
    // срок, субъект, ключ.
    let mut rest = tbs;
    let (tag, _, after) = element(rest)?;
    if tag == 0xa0 {
        rest = after;
    }
    for _ in 0..5 {
        rest = element(rest)?.2;
    }
    let (spki, _) = expect(rest, SEQUENCE)?;
    let (algorithm, rest) = expect(spki, SEQUENCE)?;
    let (oid, _) = expect(algorithm, OID)?;
    if oid != ED25519_OID {
        return Ok(None);
    }
    let (key, _) = expect(rest, BIT_STRING)?;
    let key = key.strip_prefix(&[0]).ok_or_else(bad)?;
    let public_key: &[u8; 32] = key.try_into().map_err(|_| bad())?;
    Ok(Some(Ed25519Cert {
        public_key,
        signature,
    }))
}
