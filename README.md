# gorion_clean

Flutter client under active migration from the older Gorion project onto upstream `sing-box`.

## Current Scope

- Supported target platforms in this phase: Android, Windows, Linux, macOS.
- iOS is intentionally deferred because upstream `sing-box v1.13.5` does not provide a direct embeddable iOS CLI/runtime artifact for this app shape.
- Current subscription scope: sing-box JSON remote configs, plus base64 or plain remote subscriptions that expand into share links such as `vless://`, `vmess://`, `trojan://`, and `ss://`.

## Implemented Foundation

- Local `sing-box v1.13.5` binaries are vendored into `assets/singbox/`.
- The app extracts the correct local binary at runtime and launches `sing-box` as a local process.
- Runtime control is built around the local Clash API instead of the legacy custom core gRPC surface from the previous Gorion app.
- Subscriptions are stored locally as profile template configs.
- Parsed server inventory is derived from selectable sing-box outbounds.
- Manual server switching is performed through the local Clash API selector.
- The migrated auto-selector is exposed as a dedicated `Auto-select best` server entry. When that server is selected, the app starts the runtime, chooses the best real server, and keeps monitoring it using:
	- `URLTest`
	- domain-based proxy probing
	- IP-based proxy probing

## Important Connectivity Rule

This project targets censored networks. Do not treat raw TCP success as server health. Health and auto-selection must prefer end-to-end signals through the local proxy or TUN, such as `URLTest`, HTTP or HTTPS through the proxy, egress checks, and real destination access.

## Vendoring sing-box

To re-download or refresh the vendored runtime assets:

```powershell
./tool/vendor_singbox.ps1
```

The script downloads the selected `v1.13.5` release archives for:

- Windows: `x64`, `arm64`, `x86`
- Linux: `x64`, `arm64`
- macOS: `x64`, `arm64`
- Android: `armeabi-v7a`, `arm64-v8a`, `x86`, `x86_64`

It then extracts the runtime binary into `assets/singbox/` and writes `assets/singbox/manifest.json`.

## Development Checks

```powershell
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```

## Windows Installer

`flutter build windows --release` creates a runnable folder, not a single installer.

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
