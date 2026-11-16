# Gorion

Desktop VPN and proxy client for censored networks. Native apps on top of a
shared Rust core and Gorion's own connection engine.

## Platform status

| Platform | Status |
| --- | --- |
| macOS 26+ | In progress. SwiftUI + Liquid Glass. Manual proxy, system proxy, and whole-computer VPN (TUN through a root launchd helper). |
| Windows 11 | Planned. Rust UI with acrylic, same core. |

The previous Flutter app (built on sing-box) has been removed from the tree.
It is still the behaviour reference, kept in git history at commit `166ab89`
([ADR-0006](docs/adr/0006-remove-flutter-and-sing-box.md)).

## Layout

| Path | What |
| --- | --- |
| `core/crates/gorion-core` | Subscriptions, profiles, config building, auto-select, probes, runtime lifecycle, system proxy |
| `core/crates/gorion-engine` | Own connection engine: Shadowsocks (AEAD, 2022), Trojan, VLESS (TLS, REALITY, Vision), Hysteria2; WebSocket, HTTPUpgrade, gRPC, XHTTP; TUN on macOS |
| `core/crates/gorion-helper` | Root helper for TUN (launchd) |
| `core/crates/gorion-ffi` | UniFFI bindings for Swift |
| `apps/macos` | SwiftUI app (XcodeGen), `GorionDesign`, `GorionKit` |
| `design/tokens.json` | Single source of design tokens |
| `docs/` | Migration plan, parity table, ADRs, runtime audit |

Subscriptions: share links (`vless://`, `vmess://`, `trojan://`, `ss://`,
`hysteria2://`, `tuic://`, `anytls://`) as a plain or base64 list, and Xray
JSON configs. Profiles the engine cannot run yet (VMess, TUIC, AnyTLS) fail
with a clear error instead of silently falling back.

## Important connectivity rule

Do not treat raw TCP success as server health. Health checks and
auto-selection use end-to-end signals through the local proxy or TUN:
URL tests, HTTP(S) through the proxy, egress checks.

## Build and test

Commands, including live tests and how to run the app with test data, are in
[AGENTS.md](AGENTS.md#команды). The short version:

```bash
cargo test --workspace --manifest-path core/Cargo.toml
core/scripts/build-xcframework.sh debug
(cd apps/macos && xcodegen generate)
xcodebuild -project apps/macos/Gorion.xcodeproj -scheme Gorion -destination 'platform=macOS' build
```

Where the work stands: [docs/migration/PLAN.md](docs/migration/PLAN.md) and
[docs/migration/engine-next.md](docs/migration/engine-next.md).
