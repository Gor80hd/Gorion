import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gorion_clean/core/process/running_process_lookup.dart';
import 'package:gorion_clean/core/windows/privileged_helper_protocol.dart';
import 'package:gorion_clean/features/runtime/data/singbox_runtime_support.dart';
import 'package:gorion_clean/features/runtime/data/windows_winhttp_proxy_service.dart';
import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';
import 'package:gorion_clean/features/settings/model/connection_tuning_settings.dart';
import 'package:gorion_clean/features/zapret/model/zapret_settings.dart';
import 'package:uuid/uuid.dart';

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
  static String? _cachedToken;
  static String? _cachedLaunchId;
  static Future<void>? _ensureAvailableInFlight;

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

  Future<PrivilegedHelperRuntimeSnapshot?> stopRuntimeIfAvailable() async {
    final response = await _requestIfAvailable('POST', '/runtime/stop');
    if (response == null) {
      return null;
    }
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

  Future<PrivilegedHelperZapretSnapshot?> stopZapretIfAvailable() async {
    final response = await _requestIfAvailable('POST', '/zapret/stop');
    if (response == null) {
      return null;
    }
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

  Future<void> ensureAvailable() {
    final inFlight = _ensureAvailableInFlight;
    if (inFlight != null) {
      return inFlight;
    }

    final completer = Completer<void>();
    _ensureAvailableInFlight = completer.future;
    unawaited(() async {
      try {
        await _ensureAvailableInternal();
        completer.complete();
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      } finally {
        if (identical(_ensureAvailableInFlight, completer.future)) {
          _ensureAvailableInFlight = null;
        }
      }
    }());
    return completer.future;
  }

  Future<void> _ensureAvailableInternal() async {
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
    await _withStartupLock(() async {
      final cachedToken = _cachedToken;
      final cachedLaunchId = _cachedLaunchId;
      if (cachedToken != null &&
          cachedLaunchId != null &&
          await _isHealthy(
            token: cachedToken,
            expectedLaunchId: cachedLaunchId,
            requireAuthenticated: true,
          )) {
        return;
      }
      if (await _tryReusePersistedSession()) {
        return;
      }

      await _stopHelperTaskIfRunning();
      await _deletePersistedConnectionInfo();
      final bootstrap = await _writeBootstrapRequest();
      _cachedToken = bootstrap.token;
      _cachedLaunchId = bootstrap.launchId;
      await _startHelperTask();
      final deadline = DateTime.now().add(_startupTimeout);
      Object? startupError;
      while (DateTime.now().isBefore(deadline)) {
        try {
          final connectionInfo = await _tryLoadConnectionInfo(
            expectedLaunchId: bootstrap.launchId,
          );
          if (connectionInfo?.lastError case final String lastError
              when lastError.trim().isNotEmpty) {
            throw StateError(lastError);
          }
          if (await _isHealthy(
            token: bootstrap.token,
            expectedLaunchId: bootstrap.launchId,
            requireAuthenticated: true,
          )) {
            return;
          }
        } on Object catch (error) {
          startupError = error;
        }
        await Future<void>.delayed(_pollInterval);
      }

      final launchId = bootstrap.launchId;
      var stateDetails = await _tryLoadConnectionInfo(
        expectedLaunchId: launchId,
      );
      stateDetails ??= await _tryLoadConnectionInfo();
      final detailedError = stateDetails?.lastError ?? startupError?.toString();
      if (detailedError != null && detailedError.trim().isNotEmpty) {
        throw StateError(detailedError);
      }

      throw StateError(
        'Привилегированный helper Gorion не ответил вовремя после запуска задачи Windows.',
      );
    });
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    await ensureAvailable();
    return _sendRequest(method, path, body: body);
  }

  Future<Map<String, dynamic>?> _requestIfAvailable(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    if (!Platform.isWindows || !isProvisionedSync()) {
      return null;
    }
    if (!await _tryReuseCachedSession()) {
      return null;
    }

    try {
      return await _sendRequest(method, path, body: body);
    } on Object {
      return null;
    }
  }

  Future<Map<String, dynamic>> _sendRequest(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final info = await _loadConnectionInfo(expectedLaunchId: _cachedLaunchId);
    final token = _cachedToken;
    if (token == null || token.trim().isEmpty) {
      throw StateError(
        'Привилегированный helper Gorion не инициализировал текущую сессию аутентификации.',
      );
    }
    final client = HttpClient()..connectionTimeout = _requestTimeout;
    try {
      final request = await client.openUrl(
        method,
        Uri.parse('${info.baseUrl}$path'),
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(gorionPrivilegedHelperAuthHeader, token);
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

  Future<bool> _isHealthy({
    String? token,
    String? expectedLaunchId,
    bool requireAuthenticated = false,
  }) async {
    try {
      final info = await _tryLoadConnectionInfo(
        expectedLaunchId: expectedLaunchId,
      );
      if (info == null) {
        return false;
      }
      if (info.lastError case final String lastError
          when lastError.trim().isNotEmpty) {
        return false;
      }

      final client = HttpClient()..connectionTimeout = _pollInterval;
      try {
        final request = await client.openUrl(
          'GET',
          Uri.parse('${info.baseUrl}/health'),
        );
        if (token != null && token.trim().isNotEmpty) {
          request.headers.set(gorionPrivilegedHelperAuthHeader, token);
        }
        final response = await request.close().timeout(_pollInterval);
        if (response.statusCode != HttpStatus.ok) {
          return false;
        }
        final payload = await utf8.decoder.bind(response).join();
        final json = asJsonMap(
          payload.trim().isEmpty ? null : jsonDecode(payload),
        );
        if (json?['ok'] != true) {
          return false;
        }
        final launchId = normalizedJsonString(json?['launchId']);
        if (expectedLaunchId != null && launchId != expectedLaunchId) {
          return false;
        }
        if (requireAuthenticated && json?['authenticated'] != true) {
          return false;
        }
        return true;
      } finally {
        client.close(force: true);
      }
    } on Object {
      return false;
    }
  }

  Future<bool> _tryReuseCachedSession() async {
    final cachedToken = _cachedToken;
    final cachedLaunchId = _cachedLaunchId;
    if (cachedToken != null &&
        cachedLaunchId != null &&
        await _isHealthy(
          token: cachedToken,
          expectedLaunchId: cachedLaunchId,
          requireAuthenticated: true,
        )) {
      return true;
    }
    return _tryReusePersistedSession();
  }

  Future<bool> _tryReusePersistedSession() async {
    final info = await _tryLoadConnectionInfo();
    final token = info?.token;
    final launchId = info?.launchId;
    if (token == null ||
        token.trim().isEmpty ||
        launchId == null ||
        launchId.trim().isEmpty) {
      return false;
    }
    if (!await _isHealthy(
      token: token,
      expectedLaunchId: launchId,
      requireAuthenticated: true,
    )) {
      return false;
    }
    _cachedToken = token;
    _cachedLaunchId = launchId;
    return true;
  }

  Future<PrivilegedHelperConnectionInfo> _loadConnectionInfo({
    String? expectedLaunchId,
  }) async {
    final info = await _tryLoadConnectionInfo(
      expectedLaunchId: expectedLaunchId,
    );
    if (info != null) {
      if (info.lastError case final String lastError
          when lastError.trim().isNotEmpty) {
        throw StateError(lastError);
      }
      return info;
    }
    throw StateError(
      'Привилегированный helper Gorion ещё не подготовил connection state file.',
    );
  }

  Future<PrivilegedHelperConnectionInfo?> _tryLoadConnectionInfo({
    String? expectedLaunchId,
  }) async {
    final runtimeDir = await ensureGorionRuntimeDirectory(
      subdirectory: 'privileged-helper',
    );
    final stateFile = privilegedHelperStateFileForRuntimeDir(runtimeDir);
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
    if (expectedLaunchId != null && info.launchId != expectedLaunchId) {
      return null;
    }
    return info;
  }

  Future<void> _deletePersistedConnectionInfo() async {
    final runtimeDir = await ensureGorionRuntimeDirectory(
      subdirectory: 'privileged-helper',
    );
    final stateFile = privilegedHelperStateFileForRuntimeDir(runtimeDir);
    if (!await stateFile.exists()) {
      return;
    }

    try {
      await stateFile.delete();
    } on FileSystemException {
      // Best-effort cleanup; the helper can still overwrite a stale state file.
    }
  }

  Future<PrivilegedHelperBootstrapRequest> _writeBootstrapRequest() async {
    final runtimeDir = await ensureGorionRuntimeDirectory(
      subdirectory: 'privileged-helper',
    );
    final bootstrap = PrivilegedHelperBootstrapRequest(
      token: const Uuid().v4(),
      launchId: const Uuid().v4(),
      createdAt: DateTime.now(),
      clientPid: pid,
    );
    final bootstrapFile = privilegedHelperBootstrapFileForRuntimeDir(
      runtimeDir,
    );
    await bootstrapFile.writeAsString(
      jsonEncode(bootstrap.toJson()),
      flush: true,
    );
    return bootstrap;
  }

  Future<T> _withStartupLock<T>(Future<T> Function() action) async {
    final runtimeDir = await ensureGorionRuntimeDirectory(
      subdirectory: 'privileged-helper',
    );
    final lockFile = privilegedHelperStartupLockFileForRuntimeDir(runtimeDir);
    if (!await lockFile.exists()) {
      await lockFile.create(recursive: true);
    }

    final handle = await lockFile.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
      return await action();
    } finally {
      try {
        await handle.unlock();
      } on FileSystemException {
        // The OS releases the lock if the handle is already gone.
      }
      await handle.close();
    }
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

  Future<void> _stopHelperTaskIfRunning() async {
    final currentInfo = await _tryLoadConnectionInfo();
    final result = await Process.run('schtasks.exe', [
      '/End',
      '/TN',
      gorionPrivilegedHelperTaskName,
    ]);
    if (result.exitCode == 0) {
      await _waitForHelperShutdown(currentInfo);
      return;
    }

    final stderr = result.stderr.toString().trim().toLowerCase();
    final stdout = result.stdout.toString().trim().toLowerCase();
    final details = '$stderr\n$stdout';
    if (details.contains('there are no running instances') ||
        details.contains('is not currently running') ||
        details.contains('не запущ') ||
        details.contains('не выполня')) {
      return;
    }
  }

  Future<void> _waitForHelperShutdown(
    PrivilegedHelperConnectionInfo? currentInfo,
  ) async {
    final knownPid = currentInfo?.pid;
    if (knownPid == null || knownPid <= 0) {
      await Future<void>.delayed(_pollInterval);
      return;
    }

    final deadline = DateTime.now().add(_startupTimeout);
    while (DateTime.now().isBefore(deadline)) {
      final lookup = await _lookupRunningProcess(knownPid);
      if (lookup.isMissing) {
        return;
      }
      await Future<void>.delayed(_pollInterval);
    }
  }

  static Future<RunningProcessLookup> _lookupRunningProcess(int pid) async {
    if (pid <= 0) {
      return const RunningProcessLookup.missing();
    }

    final script =
        '''
\$process = Get-CimInstance Win32_Process -Filter "ProcessId = $pid" -ErrorAction SilentlyContinue
if (\$null -eq \$process) {
  exit 3
}
[pscustomobject]@{
  executablePath = [string]\$process.ExecutablePath
  commandLine = [string]\$process.CommandLine
} | ConvertTo-Json -Compress
''';
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ]);
    if (result.exitCode == 3) {
      return const RunningProcessLookup.missing();
    }
    if (result.exitCode != 0) {
      return const RunningProcessLookup.unavailable();
    }

    try {
      final decoded = jsonDecode(result.stdout.toString());
      final json = decoded is Map
          ? Map<String, dynamic>.from(decoded.cast<String, dynamic>())
          : null;
      if (json == null) {
        return const RunningProcessLookup.unavailable();
      }
      return RunningProcessLookup.found(
        executablePath: json['executablePath']?.toString(),
        commandLine: json['commandLine']?.toString() ?? '',
      );
    } on Object {
      return const RunningProcessLookup.unavailable();
    }
  }
}
