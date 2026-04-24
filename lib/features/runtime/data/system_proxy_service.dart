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
const managedWindowsSystemProxyOverrideEntries = <String>[
  '<local>',
  'localhost',
  '127.*',
  '10.*',
  '172.16.*',
  '172.17.*',
  '172.18.*',
  '172.19.*',
  '172.20.*',
  '172.21.*',
  '172.22.*',
  '172.23.*',
  '172.24.*',
  '172.25.*',
  '172.26.*',
  '172.27.*',
  '172.28.*',
  '172.29.*',
  '172.30.*',
  '172.31.*',
  '192.168.*',
];

const managedWindowsSteamProxyOverrideEntries = <String>[
  '*.steampowered.com',
  '*.steamcommunity.com',
  '*.steamstatic.com',
  '*.steamcontent.com',
  '*.steamserver.net',
  '*.steamgames.com',
  '*.steamusercontent.com',
  '*.valvesoftware.com',
  'steampowered.com',
  'steamcommunity.com',
  'steamstatic.com',
  'steamcontent.com',
  'steamserver.net',
  'steamgames.com',
  'steamusercontent.com',
  'valvesoftware.com',
];

String buildManagedWindowsSystemProxyOverride({bool bypassSteam = false}) {
  return [
    ...managedWindowsSystemProxyOverrideEntries,
    if (bypassSteam) ...managedWindowsSteamProxyOverrideEntries,
  ].join(';');
}

bool windowsProxyBypassListsMatch({
  required String? currentBypassList,
  required String? managedBypassList,
}) {
  final currentEntries = _parseWindowsProxyBypassEntries(currentBypassList);
  final managedEntries = _parseWindowsProxyBypassEntries(managedBypassList);
  if (currentEntries.length != managedEntries.length) {
    return false;
  }
  return currentEntries.containsAll(managedEntries);
}

String buildManagedWindowsSystemProxyServer(int mixedPort) {
  return '127.0.0.1:$mixedPort';
}

bool windowsProxyServerPointsToManagedEndpoint({
  required String? currentProxyServer,
  required String? managedProxyServer,
}) {
  final currentEndpoints = _parseWindowsProxyServerEndpointKeys(
    currentProxyServer,
  );
  final managedEndpoints = _parseWindowsProxyServerEndpointKeys(
    managedProxyServer,
  );
  if (currentEndpoints.isEmpty || managedEndpoints.isEmpty) {
    return false;
  }
  if (currentEndpoints.length != managedEndpoints.length) {
    return false;
  }
  return currentEndpoints.containsAll(managedEndpoints);
}

Set<String> _parseWindowsProxyServerEndpointKeys(String? proxyServer) {
  final normalized = _normalizeWindowsProxyText(proxyServer);
  if (normalized == null) {
    return const <String>{};
  }

  final endpoints = <String>{};
  for (final entry in normalized.split(';')) {
    final endpoint = _tryParseWindowsProxyEndpointKey(entry);
    if (endpoint != null) {
      endpoints.add(endpoint);
    }
  }
  return endpoints;
}

Set<String> _parseWindowsProxyBypassEntries(String? bypassList) {
  final normalized = _normalizeWindowsProxyText(bypassList);
  if (normalized == null) {
    return const <String>{};
  }

  final entries = <String>{};
  for (final entry in normalized.split(';')) {
    final candidate = _normalizeWindowsProxyText(entry)?.toLowerCase();
    if (candidate == null) {
      continue;
    }
    entries.add(candidate);
  }
  return entries;
}

String? _tryParseWindowsProxyEndpointKey(String value) {
  var candidate = _normalizeWindowsProxyText(value);
  if (candidate == null) {
    return null;
  }

  final equalsIndex = candidate.indexOf('=');
  if (equalsIndex >= 0 && equalsIndex + 1 < candidate.length) {
    candidate = _normalizeWindowsProxyText(
      candidate.substring(equalsIndex + 1),
    );
  }
  if (candidate == null) {
    return null;
  }

  final withScheme = candidate.contains('://')
      ? candidate
      : 'http://$candidate';
  final parsed = Uri.tryParse(withScheme);
  final host = parsed?.host;
  if (host == null || host.isEmpty || parsed == null || !parsed.hasPort) {
    return null;
  }

  return '${_normalizeWindowsProxyHost(host)}:${parsed.port}';
}

String _normalizeWindowsProxyHost(String host) {
  final normalized = host.trim().toLowerCase();
  return switch (normalized) {
    '127.0.0.1' || 'localhost' || '::1' || '0:0:0:0:0:0:0:1' => 'loopback',
    _ => normalized,
  };
}

String? _normalizeWindowsProxyText(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  return trimmed;
}

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

    var shouldDeleteMarker = false;
    try {
      final current = await _readWindowsSettings();
      if (current.isManagedBy(marker.managedSettings)) {
        await _applyWindowsSettings(marker.previousSettings);
        shouldDeleteMarker = true;
        onLog(
          'Restored Windows system proxy settings left behind by a previous app session.',
        );
      } else {
        shouldDeleteMarker = true;
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
      if (shouldDeleteMarker) {
        await _deleteMarker(runtimeDir);
      }
    }
  }

  Future<SystemProxyLease?> enable({
    required RuntimeMode mode,
    required Directory runtimeDir,
    required int mixedPort,
    bool bypassSteam = false,
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
      proxyServer: buildManagedWindowsSystemProxyServer(mixedPort),
      proxyOverride: buildManagedWindowsSystemProxyOverride(
        bypassSteam: bypassSteam,
      ),
      autoConfigUrl: null,
    );
    final lease = SystemProxyLease._(
      _SystemProxyMarker(previousSettings: previous, managedSettings: managed),
    );
    await _writeMarker(runtimeDir, lease._marker);

    try {
      await _applyWindowsSettings(managed);
    } on Object catch (_) {
      try {
        await _applyWindowsSettings(previous);
      } on Object {
        // Keep the marker if rollback fails so the next startup or watchdog
        // still has the data needed to attempt a restore.
        rethrow;
      }
      await _deleteMarker(runtimeDir);
      rethrow;
    }
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

    var shouldDeleteMarker = false;
    try {
      if (!Platform.isWindows) {
        shouldDeleteMarker = true;
        return;
      }

      final current = await _readWindowsSettings();
      if (!current.isManagedBy(marker.managedSettings)) {
        shouldDeleteMarker = true;
        onLog(
          'Windows system proxy settings changed outside Gorion; skipping restore to avoid overwriting newer values.',
        );
        return;
      }

      await _applyWindowsSettings(marker.previousSettings);
      shouldDeleteMarker = true;
      onLog('Windows system proxy restored to its previous state.');
    } finally {
      if (shouldDeleteMarker) {
        await _deleteMarker(runtimeDir);
      }
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
        windowsProxyBypassListsMatch(
          currentBypassList: proxyOverride,
          managedBypassList: other.proxyOverride,
        ) &&
        _normalize(autoConfigUrl) == _normalize(other.autoConfigUrl);
  }

  bool isManagedBy(_WindowsProxySettings managed) {
    if (matches(managed)) {
      return true;
    }
    if (proxyEnable != 1 || managed.proxyEnable != 1) {
      return false;
    }
    if (!windowsProxyBypassListsMatch(
          currentBypassList: proxyOverride,
          managedBypassList: managed.proxyOverride,
        ) ||
        _normalize(autoConfigUrl) != _normalize(managed.autoConfigUrl)) {
      return false;
    }
    return windowsProxyServerPointsToManagedEndpoint(
      currentProxyServer: proxyServer,
      managedProxyServer: managed.proxyServer,
    );
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
    return _normalizeWindowsProxyText(value);
  }
}
