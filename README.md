# Gorion

Desktop VPN and proxy client built on upstream `sing-box`, written in Flutter.

## Platform status

| Platform | Status |
| --- | --- |
| macOS | Primary target. Local proxy, system proxy and TUN (through a root launchd helper). |
| Windows | Supported. TUN and the managed WinHTTP proxy go through an elevated helper. |
| Linux | Local proxy mode only. |
| Android, iOS | Not implemented. They need a native VPN service (`VpnService` / `NetworkExtension`) with `libbox`; the desktop child-process model cannot work there. |

Subscriptions: sing-box JSON configs, and base64 or plain lists of share links
(`vless://`, `vmess://`, `trojan://`, `ss://`, `hysteria2://`, `tuic://`, `anytls://`).

## Architecture

- `lib/features/runtime/data/runtime_engine.dart` defines `RuntimeEngine`, the only
  contract the UI and controllers use to run the core.
  - `SingboxRuntimeService` runs `sing-box` as a local child process.
  - `PrivilegedHelperRuntimeEngine` drives a core inside the privileged helper (TUN).
  - `AdaptiveRuntimeEngine` picks between the two per start.
  A mobile engine would be a fourth implementation behind the same interface.
- The running core is controlled through its local Clash API.
- `SingboxConfigBuilder` turns a stored subscription template into the runtime
  config. Templates are untrusted: file targets and extra listeners are stripped.
- `DashboardController` owns the connect / select / auto-select flow.

## Important connectivity rule

This project targets censored networks. Do not treat raw TCP success as server
health. Health checks and auto-selection must prefer end-to-end signals through
the local proxy or TUN: `URLTest`, HTTP(S) through the proxy, egress checks.

## sing-box binaries

The binaries are not stored in git. Fetch them before the first build or test run:

```bash
dart run tool/vendor_singbox.dart          # this host OS only
dart run tool/vendor_singbox.dart --all    # every desktop platform
```

The version and a SHA-256 for every binary are pinned in
`tool/singbox.lock.json`; a download that does not match is rejected. To move to
a new sing-box release, update the version and hashes in that file.

Each build bundles only the binaries for its own platform.

## Development checks

```bash
flutter pub get
dart run tool/vendor_singbox.dart
flutter analyze
flutter test
```

## macOS runtime verification

See [the runtime audit](docs/runtime-audit.md) for fixes, verified cases, and outstanding live checks.
The bundled sing-box 1.13.5 does not support XHTTP; those links require an Xray backend and are rejected explicitly.
The local mixed-mode lifecycle tests do not change system routes or proxy settings.
Do not enable TUN while another VPN is required for the current development session.

## Windows Installer

`flutter build windows --release` creates a runnable folder, not a single installer.

The Windows executable now starts with normal user rights (`asInvoker`), so the
desktop shortcut does not show the UAC shield overlay.

The Windows installer provisions a privileged background helper through an
elevated Scheduled Task. The regular GUI talks to that helper over localhost
for Windows-only elevated flows such as TUN mode and the managed WinHTTP
proxy, so day-to-day
manual launches no longer need a fresh UAC prompt.

The existing Windows autostart option still uses an elevated Scheduled Task,
which keeps the logon flow compatible with the previous behavior.

To produce one Windows installer `.exe`, this repository now includes:

- `installer/windows/gorion_windows_installer.iss`
- `tool/build_windows_installer.ps1`

One-time requirement:

```text
Install Inno Setup 6
https://jrsoftware.org/isdl.php
```

Build command:

```powershell
./tool/build_windows_installer.ps1
```

Result:

- release app files: `build/windows/x64/runner/Release/`
- installer `.exe`: `dist/windows-installer/`

Optional parameters:

```powershell
./tool/build_windows_installer.ps1 -AppName "Gorion" -Publisher "Gorion"
./tool/build_windows_installer.ps1 -SkipFlutterBuild
```
