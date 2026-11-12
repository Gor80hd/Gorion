//! Проверка сервера в обычном TLS: цепочка сертификатов до доверенного
//! корня, имя сервера и подпись CertificateVerify. Разбор X.509 и
//! проверку подписей делает webpki (как у rustls) — это криптография, а
//! не формат протокола (ADR-0005).

use std::fmt;
use std::sync::Arc;

use rustls::RootCertStore;
use rustls::client::WebPkiServerVerifier;
use rustls::client::danger::ServerCertVerifier;
use rustls::crypto::{CryptoProvider, WebPkiSupportedAlgorithms};
use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};

use crate::error::{EngineError, Result};

/// Схемы подписи, которые TLS 1.3 разрешает в CertificateVerify и которые
/// предлагает ClientHello Chrome (RSA PKCS#1 в TLS 1.3 запрещён).
const TLS13_SCHEMES: [u16; 6] = [0x0403, 0x0503, 0x0603, 0x0804, 0x0805, 0x0806];

fn provider() -> Arc<CryptoProvider> {
    Arc::new(rustls::crypto::aws_lc_rs::default_provider())
}

fn algorithms() -> WebPkiSupportedAlgorithms {
    rustls::crypto::aws_lc_rs::default_provider().signature_verification_algorithms
}

/// Настройки TLS сервера: имя, доверие к сертификату.
#[derive(Clone)]
pub struct TlsConfig {
    /// Имя для SNI и проверки сертификата.
    pub server_name: String,
    /// Не проверять цепочку и имя (`insecure` в sing-box). Подпись
    /// рукопожатия ключом сертификата проверяется всё равно, как в Go.
    pub insecure: bool,
    /// Свои корни (`certificate` в sing-box) вместо общих.
    pinned: Option<Arc<RootCertStore>>,
}

impl fmt::Debug for TlsConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("TlsConfig")
            .field("server_name", &self.server_name)
            .field("insecure", &self.insecure)
            .field("pinned", &self.pinned.is_some())
            .finish()
    }
}

impl TlsConfig {
    /// `certificate` — сертификаты в PEM, которым доверять вместо общих корней.
    pub fn new(
        server_name: impl Into<String>,
        insecure: bool,
        certificate: Option<&str>,
    ) -> Result<Self> {
        let pinned = match certificate {
            None => None,
            Some(pem) => {
                let mut roots = RootCertStore::empty();
                for cert in CertificateDer::pem_slice_iter(pem.as_bytes()) {
                    let cert = cert.map_err(|_| EngineError::Protocol("tls: bad certificate"))?;
                    roots
                        .add(cert)
                        .map_err(|_| EngineError::Protocol("tls: bad certificate"))?;
                }
                if roots.is_empty() {
                    return Err(EngineError::Protocol("tls: bad certificate"));
                }
                Some(Arc::new(roots))
            }
        };
        Ok(Self {
            server_name: server_name.into(),
            insecure,
            pinned,
        })
    }

    /// Цепочка `certificates` (первый — сертификат сервера) ведёт к
    /// доверенному корню и выписана на имя сервера.
    pub(crate) fn verify_chain(&self, certificates: &[Vec<u8>]) -> Result<()> {
        if self.insecure {
            return Ok(());
        }
        let Some((leaf, intermediates)) = certificates.split_first() else {
            return Err(EngineError::UntrustedCertificate("no certificate".into()));
        };
        let roots = self.pinned.clone().unwrap_or_else(|| {
            Arc::new(RootCertStore {
                roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
            })
        });
        let verifier = WebPkiServerVerifier::builder_with_provider(roots, provider())
            .build()
            .map_err(|e| EngineError::UntrustedCertificate(e.to_string()))?;
        let name = ServerName::try_from(self.server_name.clone())
            .map_err(|_| EngineError::UntrustedCertificate("bad server name".into()))?;
        let intermediates: Vec<CertificateDer<'_>> = intermediates
            .iter()
            .map(|c| CertificateDer::from(c.as_slice()))
            .collect();
        verifier
            .verify_server_cert(
                &CertificateDer::from(leaf.as_slice()),
                &intermediates,
                &name,
                &[],
                UnixTime::now(),
            )
            .map(|_| ())
            .map_err(|e| EngineError::UntrustedCertificate(e.to_string()))
    }
}

/// Подпись CertificateVerify ключом сертификата сервера.
pub(crate) fn verify_signature(
    leaf: &[u8],
    scheme: u16,
    message: &[u8],
    signature: &[u8],
) -> Result<()> {
    let invalid = || EngineError::Protocol("tls: CertificateVerify signature is invalid");
    if !TLS13_SCHEMES.contains(&scheme) {
        return Err(EngineError::Protocol("tls: unexpected signature scheme"));
    }
    let scheme = rustls::SignatureScheme::from(scheme);
    let algorithm = algorithms()
        .mapping
        .iter()
        .find(|(s, _)| *s == scheme)
        .and_then(|(_, algs)| algs.first().copied())
        .ok_or(EngineError::Protocol("tls: unexpected signature scheme"))?;
    let der = CertificateDer::from(leaf);
    let cert = webpki::EndEntityCert::try_from(&der).map_err(|_| invalid())?;
    cert.verify_signature(algorithm, message, signature)
        .map_err(|_| invalid())
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    #[test]
    fn rejects_garbage_certificates() {
        assert!(TlsConfig::new("example.com", false, Some("not a pem")).is_err());
        let config = TlsConfig::new("example.com", false, None).unwrap();
        assert!(matches!(
            config.verify_chain(&[vec![1, 2, 3]]),
            Err(EngineError::UntrustedCertificate(_))
        ));
        assert!(config.verify_chain(&[]).is_err());
        // Без проверки цепочки любые байты проходят этот шаг.
        let insecure = TlsConfig::new("example.com", true, None).unwrap();
        assert!(insecure.verify_chain(&[vec![1, 2, 3]]).is_ok());
    }

    #[test]
    fn refuses_pkcs1_in_tls13() {
        assert!(verify_signature(&[], 0x0401, b"m", b"s").is_err());
    }
}
