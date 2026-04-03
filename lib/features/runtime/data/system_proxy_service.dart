import 'dart:convert';
import 'dart:io';

import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';
import 'package:path/path.dart' as p;

const _systemProxyMarkerFileName = 'system-proxy.json';
const _winInetRefreshScript = r'''
Add-Type -Namespace Gorion -Name WinInet -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("wininet.dll", SetLastError = true)]
public static extern bool InternetSetOption(System.IntPtr hInternet, int dwOption, System.IntPtr lpBuffer, int dwBufferLength);
"@
[Gorion.WinInet]::InternetSetOption([System.IntPtr]::Zero, 39, [System.IntPtr]::Zero, 0) | Out-Null
[Gorion.WinInet]::InternetSetOption([System.IntPtr]::Zero, 37, [System.IntPtr]::Zero, 0) | Out-Null
''';

typedef ProxyLogSink = void Function(String line, {bool isError});

class SystemProxyService {
  const SystemProxyService();

  Future<void> cleanupOrphanedState({
    required Directory runtimeDir,
    required ProxyLogSink onLog,
  }) async {
    final marker = await _readMarker(runtimeDir);
    if (marker == null) {
      return;
    }

    if (!Platform.isWindows) {
      await _deleteMarker(runtimeDir);
      return;
    }

    try {
      final current = await _readWindowsSettings();
      if (current.matches(marker.managedSettings)) {
        await _applyWindowsSettings(marker.previousSettings);
        onLog(
          'Restored Windows system proxy settings left behind by a previous app session.',
        );
      } else {
        onLog(
          'Windows system proxy settings changed outside Gorion; keeping the current values and clearing the stale marker.',
        );
      }
    } on Object catch (error) {
      onLog(
        'Failed to clean up stale Windows system proxy settings: $error',
        isError: true,
      );
    } finally {
      await _deleteMarker(runtimeDir);
    }
  }

  Future<SystemProxyLease?> enable({
    required RuntimeMode mode,
    required Directory runtimeDir,
    required int mixedPort,
    required ProxyLogSink onLog,
  }) async {
    if (!mode.usesSystemProxy) {
      return null;
    }
    if (!Platform.isWindows) {
      throw UnsupportedError(
        'System proxy mode is currently supported only on Windows.',
      );
    }

    final previous = await _readWindowsSettings();
    final managed = previous.copyWith(
      proxyEnable: 1,
      proxyServer: _managedProxyServer(mixedPort),
      proxyOverride: '<local>;localhost;127.*',
      autoConfigUrl: null,
    );

    await _applyWindowsSettings(managed);

    final lease = SystemProxyLease._(
      _SystemProxyMarker(previousSettings: previous, managedSettings: managed),
    );
    await _writeMarker(runtimeDir, lease._marker);
    onLog('Windows system proxy enabled through 127.0.0.1:$mixedPort.');
    return lease;
  }

  Future<void> restore({
    required Directory runtimeDir,
    required SystemProxyLease? lease,
    required ProxyLogSink onLog,
  }) async {
    final marker = lease?._marker ?? await _readMarker(runtimeDir);
    if (marker == null) {
      return;
    }

    try {
      if (!Platform.isWindows) {
        return;
      }

      final current = await _readWindowsSettings();
      if (!current.matches(marker.managedSettings)) {
        onLog(
          'Windows system proxy settings changed outside Gorion; skipping restore to avoid overwriting newer values.',
        );
        return;
      }

      await _applyWindowsSettings(marker.previousSettings);
      onLog('Windows system proxy restored to its previous state.');
    } finally {
      await _deleteMarker(runtimeDir);
    }
  }

  Future<_SystemProxyMarker?> _readMarker(Directory runtimeDir) async {
    final file = _markerFile(runtimeDir);
    if (!await file.exists()) {
      return null;
    }

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        return null;
      }

      return _SystemProxyMarker.fromJson(
        Map<String, dynamic>.from(decoded.cast<String, dynamic>()),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeMarker(
    Directory runtimeDir,
    _SystemProxyMarker marker,
  ) async {
    final file = _markerFile(runtimeDir);
    await file.writeAsString(jsonEncode(marker.toJson()), flush: true);
  }

  Future<void> _deleteMarker(Directory runtimeDir) async {
    final file = _markerFile(runtimeDir);
    if (!await file.exists()) {
      return;
    }

    try {
      await file.delete();
    } on FileSystemException {
      return;
    }
  }

  File _markerFile(Directory runtimeDir) {
    return File(p.join(runtimeDir.path, _systemProxyMarkerFileName));
  }

  Future<_WindowsProxySettings> _readWindowsSettings() async {
    const script = r'''
$path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$props = Get-ItemProperty -Path $path
[pscustomobject]@{
  proxyEnable = [int]($props.ProxyEnable)
  proxyServer = [string]$props.ProxyServer
  proxyOverride = [string]$props.ProxyOverride
  autoConfigUrl = [string]$props.AutoConfigURL
} | ConvertTo-Json -Compress
''';

    final output = await _runPowerShell(script);
    final decoded = jsonDecode(output);
    if (decoded is Map<String, dynamic>) {
      return _WindowsProxySettings.fromJson(decoded);
    }
    if (decoded is Map) {
      return _WindowsProxySettings.fromJson(
        Map<String, dynamic>.from(decoded.cast<String, dynamic>()),
      );
    }

    throw const FormatException(
      'PowerShell returned an unexpected Windows proxy settings payload.',
    );
  }

  Future<void> _applyWindowsSettings(_WindowsProxySettings settings) async {
    final payload = jsonEncode(settings.toJson());
    final script =
        '''
\$settingsJson = @'
$payload
'@
\$settings = \$settingsJson | ConvertFrom-Json
\$path = 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings'
New-ItemProperty -Path \$path -Name ProxyEnable -PropertyType DWord -Value ([int]\$settings.proxyEnable) -Force | Out-Null
if ([string]::IsNullOrWhiteSpace([string]\$settings.proxyServer)) {
  Remove-ItemProperty -Path \$path -Name ProxyServer -ErrorAction SilentlyContinue
} else {
  New-ItemProperty -Path \$path -Name ProxyServer -PropertyType String -Value ([string]\$settings.proxyServer) -Force | Out-Null
}
if ([string]::IsNullOrWhiteSpace([string]\$settings.proxyOverride)) {
  Remove-ItemProperty -Path \$path -Name ProxyOverride -ErrorAction SilentlyContinue
} else {
  New-ItemProperty -Path \$path -Name ProxyOverride -PropertyType String -Value ([string]\$settings.proxyOverride) -Force | Out-Null
}
if ([string]::IsNullOrWhiteSpace([string]\$settings.autoConfigUrl)) {
  Remove-ItemProperty -Path \$path -Name AutoConfigURL -ErrorAction SilentlyContinue
} else {
  New-ItemProperty -Path \$path -Name AutoConfigURL -PropertyType String -Value ([string]\$settings.autoConfigUrl) -Force | Out-Null
}
$_winInetRefreshScript
'''
            .replaceFirst(r'$_winInetRefreshScript', _winInetRefreshScript);

    await _runPowerShell(script);
  }

  Future<String> _runPowerShell(String script) async {
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ]);

    final stdoutText = (result.stdout as String?)?.trim() ?? '';
    final stderrText = (result.stderr as String?)?.trim() ?? '';
    if (result.exitCode != 0) {
      throw ProcessException(
        'powershell.exe',
        const <String>[],
        stderrText.isEmpty ? stdoutText : stderrText,
        result.exitCode,
      );
    }

    return stdoutText;
  }

  String _managedProxyServer(int mixedPort) {
    return 'http=127.0.0.1:$mixedPort;https=127.0.0.1:$mixedPort;socks=127.0.0.1:$mixedPort';
  }
}

class SystemProxyLease {
  const SystemProxyLease._(this._marker);

  final _SystemProxyMarker _marker;
}

class _SystemProxyMarker {
  const _SystemProxyMarker({
    required this.previousSettings,
    required this.managedSettings,
  });

  final _WindowsProxySettings previousSettings;
  final _WindowsProxySettings managedSettings;

  Map<String, dynamic> toJson() {
    return {
      'previousSettings': previousSettings.toJson(),
      'managedSettings': managedSettings.toJson(),
    };
  }

  factory _SystemProxyMarker.fromJson(Map<String, dynamic> json) {
    return _SystemProxyMarker(
      previousSettings: _WindowsProxySettings.fromJson(
        Map<String, dynamic>.from(
          ((json['previousSettings'] as Map?) ?? const <String, dynamic>{})
              .cast<String, dynamic>(),
        ),
      ),
      managedSettings: _WindowsProxySettings.fromJson(
        Map<String, dynamic>.from(
          ((json['managedSettings'] as Map?) ?? const <String, dynamic>{})
              .cast<String, dynamic>(),
        ),
      ),
    );
  }
}

class _WindowsProxySettings {
  const _WindowsProxySettings({
    required this.proxyEnable,
    this.proxyServer,
    this.proxyOverride,
    this.autoConfigUrl,
  });

  final int proxyEnable;
  final String? proxyServer;
  final String? proxyOverride;
  final String? autoConfigUrl;

  _WindowsProxySettings copyWith({
    int? proxyEnable,
    String? proxyServer,
    bool clearProxyServer = false,
    String? proxyOverride,
    bool clearProxyOverride = false,
    String? autoConfigUrl,
    bool clearAutoConfigUrl = false,
  }) {
    return _WindowsProxySettings(
      proxyEnable: proxyEnable ?? this.proxyEnable,
      proxyServer: clearProxyServer ? null : proxyServer ?? this.proxyServer,
      proxyOverride: clearProxyOverride
          ? null
          : proxyOverride ?? this.proxyOverride,
      autoConfigUrl: clearAutoConfigUrl
          ? null
          : autoConfigUrl ?? this.autoConfigUrl,
    );
  }

  bool matches(_WindowsProxySettings other) {
    return proxyEnable == other.proxyEnable &&
        _normalize(proxyServer) == _normalize(other.proxyServer) &&
        _normalize(proxyOverride) == _normalize(other.proxyOverride) &&
        _normalize(autoConfigUrl) == _normalize(other.autoConfigUrl);
  }

  Map<String, dynamic> toJson() {
    return {
      'proxyEnable': proxyEnable,
      'proxyServer': proxyServer,
      'proxyOverride': proxyOverride,
      'autoConfigUrl': autoConfigUrl,
    };
  }

  factory _WindowsProxySettings.fromJson(Map<String, dynamic> json) {
    return _WindowsProxySettings(
      proxyEnable: (json['proxyEnable'] as num?)?.toInt() ?? 0,
      proxyServer: _normalize(json['proxyServer']?.toString()),
      proxyOverride: _normalize(json['proxyOverride']?.toString()),
      autoConfigUrl: _normalize(json['autoConfigUrl']?.toString()),
    );
  }

  static String? _normalize(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed;
  }
}
