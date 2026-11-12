//! Терпимое декодирование base64 (стандартный и URL-safe алфавит,
//! с выравниванием и без), как `_tryDecodeBase64` эталона.

use base64::Engine;
use base64::alphabet::STANDARD;
use base64::engine::{DecodePaddingMode, GeneralPurpose, GeneralPurposeConfig};

const LENIENT: GeneralPurpose = GeneralPurpose::new(
    &STANDARD,
    GeneralPurposeConfig::new()
        .with_decode_padding_mode(DecodePaddingMode::Indifferent)
        .with_decode_allow_trailing_bits(true),
);

pub fn try_decode_base64(value: &str) -> Option<String> {
    let compact: String = value.chars().filter(|c| !c.is_whitespace()).collect();
    if compact.is_empty() || compact.len() % 4 == 1 {
        return None;
    }
    if !compact
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '/' | '=' | '_' | '-'))
    {
        return None;
    }
    let normalized: String = compact
        .chars()
        .map(|c| match c {
            '-' => '+',
            '_' => '/',
            other => other,
        })
        .collect();
    let body = normalized.trim_end_matches('=');
    if body.contains('=') {
        return None;
    }
    let bytes = LENIENT.decode(body).ok()?;
    Some(String::from_utf8_lossy(&bytes).trim().to_owned())
}

#[cfg(test)]
mod tests {
    use super::try_decode_base64;

    #[test]
    fn decodes_padded_unpadded_and_url_safe() {
        assert_eq!(try_decode_base64("aGVsbG8=").as_deref(), Some("hello"));
        assert_eq!(try_decode_base64("aGVsbG8").as_deref(), Some("hello"));
        assert_eq!(try_decode_base64("Pz8_").as_deref(), Some("???"));
        assert_eq!(try_decode_base64("a"), None);
        assert_eq!(try_decode_base64("not base64!"), None);
    }
}
