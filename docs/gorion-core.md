# Gorion Core: protocol expansion

Status: discovery and importer implementation, 2026-09-21. The shipped engine is
still upstream sing-box 1.13.5. No Xray or AmneziaWG runtime has been integrated.

## Verified changes

The importer now accepts `hysteria2://`, `hy2://`, `tuic://`, and `anytls://`.
Existing VLESS, VMess, Trojan and Shadowsocks import remains supported.
Hysteria2 imports salamander and port hopping; TUIC preserves UUID, password,
congestion control, UDP relay mode and ALPN. TLS verification remains enabled
unless explicitly disabled by the profile. Unsupported certificate pin import
fails explicitly rather than silently losing the pin.

`modern_protocol_import_test.dart` exercises the full link → normalized profile →
runtime configuration → bundled binary `check` path in every desktop mode.
This checks configuration acceptance, not connectivity or interoperability.

## Target architecture

Gorion Core should own protocol capability detection, profile normalization,
routing, DNS, lifecycle, diagnostics and versioned dependency packaging.
Use sing-box as the default networking engine. Integrate Xray and AmneziaWG through
explicit adapters, with a decision still pending on in-process libraries versus
separate managed executables. Mobile requires library-based adapters and native
VPN services rather than the desktop child-process mechanism.

V2Ray and Xray are implementations/ecosystems, not individual wire protocols.
Compatibility must be specified by protocol, transport, security mode and version.
Do not advertise “all protocols” based on a type name or successful JSON parsing.

| Capability | Current evidence | Required work |
| --- | --- | --- |
| VLESS / VMess | Existing import and bundled configuration tests | Transport/security interoperability fixtures |
| VLESS REALITY / Vision | Existing importer fields | Real client/server handshake and routing tests |
| Xray XHTTP / other Xray-specific features | XHTTP import explicitly rejected | Actual Xray adapter, lossless conversion, lifecycle and network tests |
| Hysteria2 | Import and bundled config checks pass | Auth, obfuscation and port-hopping interoperability tests |
| TUIC | Import and bundled config checks pass | TCP/UDP interoperability tests |
| AnyTLS | Import and bundled config checks pass | Session reuse and interoperability tests |
| Trojan / Shadowsocks | Existing import and bundled config tests | Variant-specific interoperability matrix |
| WireGuard | Upstream endpoint architecture available | Endpoint discovery, INI import, probe and selection integration |
| AmneziaWG | No shipped implementation | Versioned AWG backend, INI import, parameter preservation and interoperability |
| SOCKS / HTTP and other sing-box protocols | JSON path, capability varies | Verify individual shipped build capabilities before advertising |

The existing selectable type list contains `awg`, `xvless`, and other extension
names. These are not evidence that the bundled upstream binary supports them.
The existing probe/extraction code only reads `outbounds`; modern WireGuard/AWG
endpoint support also requires changes in discovery, selection and probe configs.

## Upstream investigation

- sing-box 1.13.5 option schemas were read directly from upstream:
  https://github.com/SagerNet/sing-box/tree/v1.13.5/option
- Hiddify's extended sing-box revision
  `8d94f445c72dfb704f2ed4d2984dcefc79362e66` contains an AWG endpoint adapter.
  https://github.com/hiddify/hiddify-sing-box/tree/8d94f445c72dfb704f2ed4d2984dcefc79362e66/protocol/awg
- Its Xray outbound is a stub returning `Xray is not implemented yet`:
  https://github.com/hiddify/hiddify-sing-box/blob/8d94f445c72dfb704f2ed4d2984dcefc79362e66/protocol/hiddify/xray/outbound.go
  Therefore simply replacing the current binary with this fork would not satisfy
  the Xray requirement.

## Release acceptance

1. Pin every upstream revision and verify downloaded artifact hashes.
2. Preserve upstream license texts, attribution and source provenance alongside
   Gorion's own modifications; branding does not replace dependency attribution.
3. Prove each advertised protocol against a controlled server with TCP and UDP
   where applicable. Include failure cases for invalid credentials and certificates.
4. Check TUN routing, DNS, interface changes, disconnect/crash cleanup and process
   ownership on every supported desktop OS.
5. Package and sign the actual binaries; separately validate native mobile VPN
   extensions before claiming mobile support.
6. Publish a generated capability manifest reflecting what is actually shipped.

No production connection, installed application, or server was changed in this
implementation step. Xray and AmneziaWG remain outstanding work.
