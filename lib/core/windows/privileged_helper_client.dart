import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gorion_clean/core/windows/privileged_helper_protocol.dart';
import 'package:gorion_clean/features/runtime/data/singbox_runtime_support.dart';
import 'package:gorion_clean/features/runtime/data/windows_winhttp_proxy_service.dart';
import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';
import 'package:gorion_clean/features/settings/model/connection_tuning_settings.dart';
import 'package:gorion_clean/features/zapret/model/zapret_settings.dart';
import 'package:path/path.dart' as p;

class WindowsPrivilegedHelperClient {
  WindowsPrivilegedHelperClient({
    Duration startupTimeout = const Duration(seconds: 8),
    Duration pollInterval = const Duration(milliseconds: 250),
    Duration requestTimeout = const Duration(seconds: 10),
  }) : _startupTimeout = startupTimeout,
       _pollInterval = pollInterval,
       _requestTimeout = requestTimeout;

  final Duration _startupTimeout;
  final Duration _pollInterval;
  final Duration _requestTimeout;

  static bool isProvisionedSync({String? executablePath}) {
    if (!Platform.isWindows) {
      return false;
    }

    final resolvedExecutable = executablePath ?? Platform.resolvedExecutable;
    return privilegedHelperProvisionMarkerForExecutable(
      resolvedExecutable,
    ).existsSync();
  }

  Future<PrivilegedHelperRuntimeSnapshot> fetchRuntimeState() async {
    final response = await _request('GET', '/runtime/state');
    return PrivilegedHelperRuntimeSnapshot.fromJson(response);
  }

  Future<PrivilegedHelperRuntimeSnapshot> startRuntime({
    required String profileId,
    required String templateConfig,
    String? originalTemplateConfig,
    ConnectionTuningSettings connectionTuningSettings =
        const ConnectionTuningSettings(),
    required String urlTestUrl,
    required RuntimeMode mode,
    String? selectedServerTag,
  }) async {
    final response = await _request(
      'POST',
      '/runtime/start',
      body: {
        'profileId': profileId,
        'templateConfig': templateConfig,
        'originalTemplateConfig': originalTemplateConfig,
        'connectionTuningSettings': connectionTuningSettings.toJson(),
        'urlTestUrl': urlTestUrl,
        'mode': mode.name,
        'selectedServerTag': selectedServerTag,
      },
    );
    return PrivilegedHelperRuntimeSnapshot.fromJson(response);
  }

  Future<PrivilegedHelperRuntimeSnapshot> stopRuntime() async {
    final response = await _request('POST', '/runtime/stop');
    return PrivilegedHelperRuntimeSnapshot.fromJson(response);
  }

  Future<PrivilegedHelperZapretSnapshot> fetchZapretState() async {
    final response = await _request('GET', '/zapret/state');
    return PrivilegedHelperZapretSnapshot.fromJson(response);
  }

  Future<PrivilegedHelperZapretSnapshot> startZapret({
    required ZapretSettings settings,
    bool preserveLogs = false,
  }) async {
    final response = await _request(
      'POST',
      '/zapret/start',
      body: {'settings': settings.toJson(), 'preserveLogs': preserveLogs},
    );
    return PrivilegedHelperZapretSnapshot.fromJson(response);
  }

  Future<PrivilegedHelperZapretSnapshot> stopZapret() async {
    final response = await _request('POST', '/zapret/stop');
    return PrivilegedHelperZapretSnapshot.fromJson(response);
  }

  Future<PrivilegedHelperZapretSnapshot> recordZapretDiagnostic({
    required String line,
    bool isError = false,
  }) async {
    final response = await _request(
      'POST',
      '/zapret/record-diagnostic',
      body: {'line': line, 'isError': isError},
    );
    return PrivilegedHelperZapretSnapshot.fromJson(response);
  }

  Future<WindowsWinHttpProxySettings> readWinHttpProxySettings() async {
    final response = await _request('GET', '/windows/winhttp-proxy');
    return WindowsWinHttpProxySettings.fromJson(response);
  }

  Future<void> applyWinHttpProxySettings(
    WindowsWinHttpProxySettings settings,
  ) async {
    await _request('POST', '/windows/winhttp-proxy', body: settings.toJson());
  }

  Future<void> ensureAvailable() async {
    if (!Platform.isWindows) {
      throw UnsupportedError(
        'The privileged helper is supported only on Windows.',
      );
    }
    if (!isProvisionedSync()) {
      throw StateError(
        'Привилегированный helper Gorion не установлен. Переустановите приложение через Windows installer.',
      );
    }
    if (await _isHealthy()) {
      return;
    }

    await _startHelperTask();
    final deadline = DateTime.now().add(_startupTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await _isHealthy()) {
        return;
      }
      await Future<void>.delayed(_pollInterval);
    }

    throw StateError(
      'Привилегированный helper Gorion не ответил вовремя после запуска задачи Windows.',
    );
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    await ensureAvailable();

    final info = await _loadConnectionInfo();
    final client = HttpClient()..connectionTimeout = _requestTimeout;
    try {
      final request = await client.openUrl(
        method,
        Uri.parse('${info.baseUrl}$path'),
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(gorionPrivilegedHelperAuthHeader, info.token);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }

      final response = await request.close().timeout(_requestTimeout);
      final payload = await utf8.decoder.bind(response).join();
      final parsed = payload.trim().isEmpty ? null : jsonDecode(payload);
      final json = asJsonMap(parsed);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return json ?? const <String, dynamic>{};
      }

      final errorMessage =
          normalizedJsonString(json?['error']) ??
          payload.trim().replaceAll('\r', '').replaceAll('\n', ' ');
      throw StateError(
        errorMessage.isEmpty
            ? 'The privileged helper rejected $path with HTTP ${response.statusCode}.'
            : errorMessage,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _isHealthy() async {
    try {
      final info = await _tryLoadConnectionInfo();
      if (info == null) {
        return false;
      }

      final client = HttpClient()..connectionTimeout = _pollInterval;
      try {
        final request = await client.openUrl(
          'GET',
          Uri.parse('${info.baseUrl}/health'),
        );
        request.headers.set(gorionPrivilegedHelperAuthHeader, info.token);
        final response = await request.close().timeout(_pollInterval);
        if (response.statusCode != HttpStatus.ok) {
          return false;
        }
        final payload = await utf8.decoder.bind(response).join();
        final json = asJsonMap(
          payload.trim().isEmpty ? null : jsonDecode(payload),
        );
        return json?['ok'] == true;
      } finally {
        client.close(force: true);
      }
    } on Object {
      return false;
    }
  }

  Future<PrivilegedHelperConnectionInfo> _loadConnectionInfo() async {
    final info = await _tryLoadConnectionInfo();
    if (info != null) {
      return info;
    }
    throw StateError(
      'Привилегированный helper Gorion ещё не подготовил connection state file.',
    );
  }

  Future<PrivilegedHelperConnectionInfo?> _tryLoadConnectionInfo() async {
    final runtimeDir = await ensureGorionRuntimeDirectory(
      subdirectory: 'privileged-helper',
    );
    final stateFile = File(
      p.join(runtimeDir.path, gorionPrivilegedHelperStateFileName),
    );
    if (!await stateFile.exists()) {
      return null;
    }

    final decoded = jsonDecode(await stateFile.readAsString());
    final json = asJsonMap(decoded);
    if (json == null) {
      throw const FormatException(
        'The privileged helper connection state file is corrupted.',
      );
    }

    final info = PrivilegedHelperConnectionInfo.fromJson(json);
    if (info.token.trim().isEmpty) {
      throw const FormatException(
        'The privileged helper connection state file does not contain a token.',
      );
    }
    return info;
  }

  Future<void> _startHelperTask() async {
    final result = await Process.run('schtasks.exe', [
      '/Run',
      '/TN',
      gorionPrivilegedHelperTaskName,
    ]);
    if (result.exitCode == 0) {
      return;
    }

    final stderr = result.stderr.toString().trim();
    final stdout = result.stdout.toString().trim();
    final details = [
      stderr,
      stdout,
    ].where((entry) => entry.isNotEmpty).join('\n');
    if (details.toLowerCase().contains('running')) {
      return;
    }

    throw ProcessException(
      'schtasks.exe',
      const ['/Run', '/TN', gorionPrivilegedHelperTaskName],
      details.isEmpty
          ? 'Не удалось запустить задачу привилегированного helper.'
          : details,
      result.exitCode,
    );
  }
}
