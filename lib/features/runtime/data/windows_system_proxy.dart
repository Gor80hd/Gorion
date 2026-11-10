import 'dart:convert';
import 'dart:io';

import 'package:gorion_clean/core/process/process_runner.dart';

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

String buildManagedWindowsSystemProxyServer(int mixedPort) {
  return '127.0.0.1:$mixedPort';
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

/// Current Windows WinINET proxy state, as stored in
/// `HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings`.
class WindowsProxySettings {
  const WindowsProxySettings({
    required this.proxyEnable,
    this.proxyServer,
    this.proxyOverride,
    this.autoConfigUrl,
  });

  final int proxyEnable;
  final String? proxyServer;
  final String? proxyOverride;
  final String? autoConfigUrl;

  WindowsProxySettings copyWith({
    int? proxyEnable,
    String? proxyServer,
    bool clearProxyServer = false,
    String? proxyOverride,
    bool clearProxyOverride = false,
    String? autoConfigUrl,
    bool clearAutoConfigUrl = false,
  }) {
    return WindowsProxySettings(
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

  bool matches(WindowsProxySettings other) {
    return proxyEnable == other.proxyEnable &&
        _normalizeWindowsProxyText(proxyServer) ==
            _normalizeWindowsProxyText(other.proxyServer) &&
        windowsProxyBypassListsMatch(
          currentBypassList: proxyOverride,
          managedBypassList: other.proxyOverride,
        ) &&
        _normalizeWindowsProxyText(autoConfigUrl) ==
            _normalizeWindowsProxyText(other.autoConfigUrl);
  }

  bool isManagedBy(WindowsProxySettings managed) {
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
        _normalizeWindowsProxyText(autoConfigUrl) !=
            _normalizeWindowsProxyText(managed.autoConfigUrl)) {
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

  factory WindowsProxySettings.fromJson(Map<String, dynamic> json) {
    return WindowsProxySettings(
      proxyEnable: (json['proxyEnable'] as num?)?.toInt() ?? 0,
      proxyServer: _normalizeWindowsProxyText(json['proxyServer']?.toString()),
      proxyOverride: _normalizeWindowsProxyText(
        json['proxyOverride']?.toString(),
      ),
      autoConfigUrl: _normalizeWindowsProxyText(
        json['autoConfigUrl']?.toString(),
      ),
    );
  }
}

/// Windows system proxy backend. Talks to WinINET through PowerShell; all
/// process invocations carry a hard timeout so a stuck WMI/registry call can
/// never deadlock the runtime lifecycle.
class WindowsSystemProxyBackend {
  const WindowsSystemProxyBackend({
    Future<ProcessResult> Function(
          String executable,
          List<String> arguments, {
          Duration timeout,
        })
        processRunner =
        _defaultProcessRunner,
  }) : _processRunner = processRunner;

  final Future<ProcessResult> Function(
    String executable,
    List<String> arguments, {
    Duration timeout,
  })
  _processRunner;

  static const _commandTimeout = Duration(seconds: 15);

  static Future<ProcessResult> _defaultProcessRunner(
    String executable,
    List<String> arguments, {
    Duration timeout = _commandTimeout,
  }) {
    return runProcessWithTimeout(executable, arguments, timeout: timeout);
  }

  Future<WindowsProxySettings> readSettings() async {
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
      return WindowsProxySettings.fromJson(decoded);
    }
    if (decoded is Map) {
      return WindowsProxySettings.fromJson(
        Map<String, dynamic>.from(decoded.cast<String, dynamic>()),
      );
    }

    throw const FormatException(
      'PowerShell returned an unexpected Windows proxy settings payload.',
    );
  }

  Future<void> applySettings(WindowsProxySettings settings) async {
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
    final result = await _processRunner('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ], timeout: _commandTimeout);

    final stdoutText = result.stdout.toString().trim();
    final stderrText = result.stderr.toString().trim();
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
