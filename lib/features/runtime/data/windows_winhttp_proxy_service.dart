import 'dart:io';

import 'package:gorion_clean/features/runtime/data/system_proxy_service.dart';

class WindowsWinHttpProxySettings {
  const WindowsWinHttpProxySettings({this.proxyServer, this.bypassList});

  final String? proxyServer;
  final String? bypassList;

  bool get isDirect => _normalize(proxyServer) == null;

  WindowsWinHttpProxySettings copyWith({
    String? proxyServer,
    bool clearProxyServer = false,
    String? bypassList,
    bool clearBypassList = false,
  }) {
    return WindowsWinHttpProxySettings(
      proxyServer: clearProxyServer ? null : proxyServer ?? this.proxyServer,
      bypassList: clearBypassList ? null : bypassList ?? this.bypassList,
    );
  }

  bool matches(WindowsWinHttpProxySettings other) {
    return _normalize(proxyServer) == _normalize(other.proxyServer) &&
        windowsProxyBypassListsMatch(
          currentBypassList: bypassList,
          managedBypassList: other.bypassList,
        );
  }

  bool isManagedBy(WindowsWinHttpProxySettings managed) {
    if (matches(managed)) {
      return true;
    }
    if (!windowsProxyBypassListsMatch(
      currentBypassList: bypassList,
      managedBypassList: managed.bypassList,
    )) {
      return false;
    }
    return windowsProxyServerPointsToManagedEndpoint(
      currentProxyServer: proxyServer,
      managedProxyServer: managed.proxyServer,
    );
  }

  Map<String, dynamic> toJson() {
    return {'proxyServer': proxyServer, 'bypassList': bypassList};
  }

  factory WindowsWinHttpProxySettings.fromJson(Map<String, dynamic> json) {
    return WindowsWinHttpProxySettings(
      proxyServer: _normalize(json['proxyServer']?.toString()),
      bypassList: _normalize(json['bypassList']?.toString()),
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

WindowsWinHttpProxySettings parseWinHttpShowProxyOutput(String output) {
  final normalized = output.replaceAll('\r', '');

  if (normalized.contains('Direct access (no proxy server).') ||
      normalized.contains('Прямой доступ (без прокси-сервера).')) {
    return const WindowsWinHttpProxySettings();
  }

  final proxyMatch = RegExp(
    r'^\s*Proxy Server\(s\)\s*:\s*(.+?)\s*$',
    caseSensitive: false,
    multiLine: true,
  ).firstMatch(normalized);
  final bypassMatch = RegExp(
    r'^\s*Bypass List\s*:\s*(.*?)\s*$',
    caseSensitive: false,
    multiLine: true,
  ).firstMatch(normalized);
  String? proxyServer = proxyMatch?.group(1)?.trim();
  String? bypassList = bypassMatch?.group(1)?.trim();
  if (proxyServer == null && bypassList == null) {
    final genericMatches = RegExp(
      r'^\s+\S.*?:\s*(.*?)\s*$',
      caseSensitive: false,
      multiLine: true,
    ).allMatches(normalized).toList(growable: false);
    if (genericMatches.isNotEmpty) {
      proxyServer = genericMatches.first.group(1)?.trim();
    }
    if (genericMatches.length > 1) {
      bypassList = genericMatches[1].group(1)?.trim();
    }
  }

  return WindowsWinHttpProxySettings(
    proxyServer: proxyServer,
    bypassList: bypassList,
  );
}

String buildManagedWindowsWinHttpProxyServer(int mixedPort) {
  return buildManagedWindowsSystemProxyServer(mixedPort);
}

String buildManagedWindowsWinHttpBypassList() {
  return buildManagedWindowsSystemProxyOverride();
}

class WindowsWinHttpProxyService {
  const WindowsWinHttpProxyService();

  Future<WindowsWinHttpProxySettings> readSettings() async {
    if (!Platform.isWindows) {
      throw UnsupportedError('WinHTTP proxy is supported only on Windows.');
    }

    final output = await _runNetsh(['winhttp', 'show', 'proxy']);
    return parseWinHttpShowProxyOutput(output);
  }

  Future<void> applySettings(WindowsWinHttpProxySettings settings) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('WinHTTP proxy is supported only on Windows.');
    }

    if (settings.isDirect) {
      await _runNetsh(['winhttp', 'reset', 'proxy']);
      return;
    }

    final proxyServer = settings.proxyServer?.trim();
    if (proxyServer == null || proxyServer.isEmpty) {
      throw const FormatException('WinHTTP proxy server is empty.');
    }

    final arguments = <String>[
      'winhttp',
      'set',
      'proxy',
      'proxy-server=$proxyServer',
    ];
    final bypassList = settings.bypassList?.trim();
    if (bypassList != null && bypassList.isNotEmpty) {
      arguments.add('bypass-list=$bypassList');
    }

    await _runNetsh(arguments);
  }

  Future<String> _runNetsh(List<String> arguments) async {
    final result = await Process.run('netsh.exe', arguments);
    final stdoutText = (result.stdout as String?)?.trim() ?? '';
    final stderrText = (result.stderr as String?)?.trim() ?? '';
    if (result.exitCode != 0) {
      throw ProcessException(
        'netsh.exe',
        arguments,
        stderrText.isEmpty ? stdoutText : stderrText,
        result.exitCode,
      );
    }

    return stdoutText.isEmpty ? stderrText : stdoutText;
  }
}
