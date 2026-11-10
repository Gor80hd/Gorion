import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gorion_clean/core/windows/privileged_helper_protocol.dart';
import 'package:gorion_clean/features/runtime/data/singbox_runtime_service.dart';
import 'package:gorion_clean/features/runtime/data/singbox_runtime_support.dart';
import 'package:gorion_clean/features/runtime/data/windows_winhttp_proxy_service.dart';
import 'package:gorion_clean/features/settings/model/connection_tuning_settings.dart';
import 'package:gorion_clean/features/zapret/data/zapret_runtime_service.dart';
import 'package:gorion_clean/features/zapret/model/zapret_settings.dart';

Future<void> runPrivilegedHelperServer() async {
  final server = _WindowsPrivilegedHelperServer();
  await server.run();
}

class _WindowsPrivilegedHelperServer {
  _WindowsPrivilegedHelperServer()
    : _runtimeService = SingboxRuntimeService(),
      _zapretRuntimeService = ZapretRuntimeService(
        forceBundledInstallDirectory: true,
      ),
      _winHttpProxyService = const WindowsWinHttpProxyService();

  final SingboxRuntimeService _runtimeService;
  final ZapretRuntimeService _zapretRuntimeService;
  final WindowsWinHttpProxyService _winHttpProxyService;
  HttpServer? _server;
  int? _lastZapretExitCode;
  String? _authToken;
  PrivilegedHelperConnectionInfo? _connectionInfo;
  WindowsWinHttpProxySettings? _previousWinHttpSettings;
  WindowsWinHttpProxySettings? _managedWinHttpSettings;

  Future<void> run() async {
    if (!Platform.isWindows) {
      return;
    }

    final runtimeDir = await ensureGorionRuntimeDirectory(
      subdirectory: 'privileged-helper',
    );
    final bootstrap = await _consumeBootstrapRequest(runtimeDir);
    if (bootstrap == null) {
      await _writeFailureState(
        runtimeDir,
        const PrivilegedHelperConnectionInfo(
          lastError:
              'Privileged helper launch was rejected because no valid bootstrap request was found.',
        ),
      );
      stderr.writeln(
        'Gorion privileged helper aborted: missing or invalid bootstrap request.',
      );
      return;
    }
    _authToken = bootstrap.token;
    _connectionInfo = PrivilegedHelperConnectionInfo(
      token: bootstrap.token,
      launchId: bootstrap.launchId,
    );

    try {
      _server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        _connectionInfo!.port,
      );
    } on SocketException catch (error) {
      await _writeFailureState(
        runtimeDir,
        _connectionInfo!.copyWith(
          lastError:
              'Failed to bind the privileged helper to ${_connectionInfo!.host}:${_connectionInfo!.port}: $error',
        ),
      );
      stderr.writeln(
        'Gorion privileged helper failed to bind to ${_connectionInfo!.host}:${_connectionInfo!.port}: $error',
      );
      return;
    }

    await _writeConnectionInfo(
      runtimeDir,
      _connectionInfo!.copyWith(pid: pid, clearLastError: true),
    );

    await for (final request in _server!) {
      unawaited(_handleRequest(request));
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final token = request.headers.value(gorionPrivilegedHelperAuthHeader);
      final authenticated = token != null && token == _authToken;
      final method = request.method.toUpperCase();
      final path = request.uri.path;
      if (method == 'GET' && path == '/health') {
        await _writeJson(request.response, HttpStatus.ok, {
          'ok': true,
          'authenticated': authenticated,
          'launchId': _connectionInfo?.launchId,
          'pid': pid,
        });
        return;
      }
      if (!authenticated) {
        await _writeJson(request.response, HttpStatus.unauthorized, {
          'error': 'Invalid privileged helper token.',
        });
        return;
      }

      if (method == 'GET' && path == '/runtime/state') {
        await _writeJson(
          request.response,
          HttpStatus.ok,
          _runtimeStateSnapshot().toJson(),
        );
        return;
      }
      if (method == 'POST' && path == '/runtime/start') {
        final body = await _readJsonBody(request);
        final mode = runtimeModeFromJsonValue(body['mode']);
        if (!mode.usesTun) {
          throw StateError('Privileged helper can only start the TUN runtime.');
        }
        await _runtimeService.start(
          profileId: normalizedJsonString(body['profileId']) ?? '',
          templateConfig: normalizedJsonString(body['templateConfig']) ?? '',
          originalTemplateConfig: normalizedJsonString(
            body['originalTemplateConfig'],
          ),
          connectionTuningSettings: ConnectionTuningSettings.fromJson(
            asJsonMap(body['connectionTuningSettings']) ??
                const <String, dynamic>{},
          ),
          urlTestUrl: normalizedJsonString(body['urlTestUrl']) ?? '',
          mode: mode,
          selectedServerTag: normalizedJsonString(body['selectedServerTag']),
        );
        await _writeJson(
          request.response,
          HttpStatus.ok,
          _runtimeStateSnapshot().toJson(),
        );
        return;
      }
      if (method == 'POST' && path == '/runtime/stop') {
        await _runtimeService.stop();
        await _writeJson(
          request.response,
          HttpStatus.ok,
          _runtimeStateSnapshot().toJson(),
        );
        return;
      }
      if (method == 'GET' && path == '/zapret/state') {
        await _writeJson(
          request.response,
          HttpStatus.ok,
          _zapretStateSnapshot().toJson(),
        );
        return;
      }
      if (method == 'POST' && path == '/zapret/start') {
        final body = await _readJsonBody(request);
        final settingsJson =
            asJsonMap(body['settings']) ?? const <String, dynamic>{};
        _lastZapretExitCode = null;
        await _zapretRuntimeService.start(
          settings: ZapretSettings.fromJson(settingsJson),
          preserveLogs: body['preserveLogs'] == true,
          onExit: (exitCode) {
            _lastZapretExitCode = exitCode;
          },
        );
        await _writeJson(
          request.response,
          HttpStatus.ok,
          _zapretStateSnapshot().toJson(),
        );
        return;
      }
      if (method == 'POST' && path == '/zapret/stop') {
        await _zapretRuntimeService.stop();
        await _writeJson(
          request.response,
          HttpStatus.ok,
          _zapretStateSnapshot().toJson(),
        );
        return;
      }
      if (method == 'POST' && path == '/zapret/record-diagnostic') {
        final body = await _readJsonBody(request);
        _zapretRuntimeService.recordDiagnostic(
          normalizedJsonString(body['line']) ?? '',
          isError: body['isError'] == true,
        );
        await _writeJson(
          request.response,
          HttpStatus.ok,
          _zapretStateSnapshot().toJson(),
        );
        return;
      }
      if (method == 'POST' && path == '/windows/winhttp-proxy/managed-enable') {
        final body = await _readJsonBody(request);
        final mixedPort = _parseManagedProxyPort(body['mixedPort']);
        final managedSettings = await _enableManagedWinHttpProxy(
          mixedPort,
          bypassSteam: body['bypassSteam'] == true,
        );
        await _writeJson(request.response, HttpStatus.ok, {
          'ok': true,
          'managedSettings': managedSettings.toJson(),
        });
        return;
      }
      if (method == 'POST' &&
          path == '/windows/winhttp-proxy/managed-restore') {
        final body = await _readJsonBody(request);
        final mixedPort = _parseManagedProxyPort(body['mixedPort']);
        await _restoreManagedWinHttpProxy(
          mixedPort,
          bypassSteam: body['bypassSteam'] == true,
        );
        await _writeJson(request.response, HttpStatus.ok, {'ok': true});
        return;
      }

      await _writeJson(request.response, HttpStatus.notFound, {
        'error': 'Unknown privileged helper route: $path',
      });
    } on Object catch (error) {
      await _writeJson(request.response, HttpStatus.internalServerError, {
        'error': error.toString(),
      });
    }
  }

  PrivilegedHelperRuntimeSnapshot _runtimeStateSnapshot() {
    return PrivilegedHelperRuntimeSnapshot(
      session: _runtimeService.session,
      logs: _runtimeService.logs,
    );
  }

  PrivilegedHelperZapretSnapshot _zapretStateSnapshot() {
    return PrivilegedHelperZapretSnapshot(
      session: _zapretRuntimeService.session,
      logs: _zapretRuntimeService.logs,
      lastExitCode: _lastZapretExitCode,
    );
  }

  Future<WindowsWinHttpProxySettings> _enableManagedWinHttpProxy(
    int mixedPort, {
    required bool bypassSteam,
  }) async {
    final previousSettings = await _winHttpProxyService.readSettings();
    final managedSettings = WindowsWinHttpProxySettings(
      proxyServer: buildManagedWindowsWinHttpProxyServer(mixedPort),
      bypassList: buildManagedWindowsWinHttpBypassList(
        bypassSteam: bypassSteam,
      ),
    );

    try {
      await _winHttpProxyService.applySettings(managedSettings);
    } on Object {
      await _winHttpProxyService.applySettings(previousSettings);
      rethrow;
    }

    _previousWinHttpSettings = previousSettings;
    _managedWinHttpSettings = managedSettings;
    return managedSettings;
  }

  Future<void> _restoreManagedWinHttpProxy(
    int mixedPort, {
    required bool bypassSteam,
  }) async {
    final expectedManagedSettings = WindowsWinHttpProxySettings(
      proxyServer: buildManagedWindowsWinHttpProxyServer(mixedPort),
      bypassList: buildManagedWindowsWinHttpBypassList(
        bypassSteam: bypassSteam,
      ),
    );
    final currentSettings = await _winHttpProxyService.readSettings();
    if (!currentSettings.isManagedBy(expectedManagedSettings)) {
      if (_managedWinHttpSettings?.matches(expectedManagedSettings) ?? false) {
        _previousWinHttpSettings = null;
        _managedWinHttpSettings = null;
      }
      return;
    }

    final previousSettings =
        (_managedWinHttpSettings?.matches(expectedManagedSettings) ?? false)
        ? _previousWinHttpSettings
        : null;
    await _winHttpProxyService.applySettings(
      previousSettings ?? const WindowsWinHttpProxySettings(),
    );
    _previousWinHttpSettings = null;
    _managedWinHttpSettings = null;
  }

  int _parseManagedProxyPort(dynamic value) {
    final port = (value as num?)?.toInt();
    if (port == null || port <= 0 || port > 65535) {
      throw const FormatException('Invalid managed WinHTTP proxy port.');
    }
    return port;
  }

  Future<Map<String, dynamic>> _readJsonBody(HttpRequest request) async {
    final payload = await utf8.decoder.bind(request).join();
    if (payload.trim().isEmpty) {
      return const <String, dynamic>{};
    }

    final decoded = jsonDecode(payload);
    return asJsonMap(decoded) ?? const <String, dynamic>{};
  }

  Future<void> _writeJson(
    HttpResponse response,
    int statusCode,
    Map<String, dynamic> payload,
  ) async {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(payload));
    await response.close();
  }

  Future<PrivilegedHelperBootstrapRequest?> _consumeBootstrapRequest(
    Directory runtimeDir,
  ) async {
    final bootstrapFile = privilegedHelperBootstrapFileForRuntimeDir(
      runtimeDir,
    );
    if (!await bootstrapFile.exists()) {
      return null;
    }

    try {
      final decoded = jsonDecode(await bootstrapFile.readAsString());
      final json = asJsonMap(decoded);
      if (json == null) {
        return null;
      }
      final bootstrap = PrivilegedHelperBootstrapRequest.fromJson(json);
      if (bootstrap.token.trim().isEmpty || bootstrap.launchId.trim().isEmpty) {
        return null;
      }
      if (DateTime.now().difference(bootstrap.createdAt) >
          gorionPrivilegedHelperBootstrapMaxAge) {
        return null;
      }
      return bootstrap;
    } on Object {
      return null;
    } finally {
      try {
        await bootstrapFile.delete();
      } on Object {
        // Best-effort cleanup; a stale bootstrap file should never block startup.
      }
    }
  }

  Future<void> _writeConnectionInfo(
    Directory runtimeDir,
    PrivilegedHelperConnectionInfo info,
  ) async {
    final stateFile = privilegedHelperStateFileForRuntimeDir(runtimeDir);
    await stateFile.writeAsString(
      jsonEncode(info.toJson(includeToken: false)),
      flush: true,
    );
  }

  Future<void> _writeFailureState(
    Directory runtimeDir,
    PrivilegedHelperConnectionInfo info,
  ) {
    return _writeConnectionInfo(runtimeDir, info);
  }
}
