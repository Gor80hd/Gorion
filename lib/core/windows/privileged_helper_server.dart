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
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

Future<void> runPrivilegedHelperServer() async {
  final server = _WindowsPrivilegedHelperServer();
  await server.run();
}

class _WindowsPrivilegedHelperServer {
  _WindowsPrivilegedHelperServer()
    : _runtimeService = SingboxRuntimeService(),
      _zapretRuntimeService = ZapretRuntimeService(),
      _winHttpProxyService = const WindowsWinHttpProxyService();

  final SingboxRuntimeService _runtimeService;
  final ZapretRuntimeService _zapretRuntimeService;
  final WindowsWinHttpProxyService _winHttpProxyService;
  HttpServer? _server;
  int? _lastZapretExitCode;

  Future<void> run() async {
    if (!Platform.isWindows) {
      return;
    }

    final runtimeDir = await ensureGorionRuntimeDirectory(
      subdirectory: 'privileged-helper',
    );
    final connectionInfo = await _loadOrCreateConnectionInfo(runtimeDir);

    try {
      _server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        connectionInfo.port,
      );
    } on SocketException {
      return;
    }

    await _writeConnectionInfo(runtimeDir, connectionInfo.copyWith(pid: pid));

    await for (final request in _server!) {
      unawaited(_handleRequest(request));
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final connectionInfo = await _loadOrCreateConnectionInfo(
        await ensureGorionRuntimeDirectory(subdirectory: 'privileged-helper'),
      );
      final token = request.headers.value(gorionPrivilegedHelperAuthHeader);
      if (token != connectionInfo.token) {
        await _writeJson(request.response, HttpStatus.unauthorized, {
          'error': 'Invalid privileged helper token.',
        });
        return;
      }

      final method = request.method.toUpperCase();
      final path = request.uri.path;
      if (method == 'GET' && path == '/health') {
        await _writeJson(request.response, HttpStatus.ok, {'ok': true});
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
          mode: runtimeModeFromJsonValue(body['mode']),
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
      if (method == 'GET' && path == '/windows/winhttp-proxy') {
        final settings = await _winHttpProxyService.readSettings();
        await _writeJson(request.response, HttpStatus.ok, settings.toJson());
        return;
      }
      if (method == 'POST' && path == '/windows/winhttp-proxy') {
        final body = await _readJsonBody(request);
        await _winHttpProxyService.applySettings(
          WindowsWinHttpProxySettings.fromJson(body),
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

  Future<PrivilegedHelperConnectionInfo> _loadOrCreateConnectionInfo(
    Directory runtimeDir,
  ) async {
    final stateFile = File(
      p.join(runtimeDir.path, gorionPrivilegedHelperStateFileName),
    );
    if (await stateFile.exists()) {
      try {
        final decoded = jsonDecode(await stateFile.readAsString());
        final json = asJsonMap(decoded);
        if (json != null) {
          final info = PrivilegedHelperConnectionInfo.fromJson(json);
          if (info.token.trim().isNotEmpty) {
            return info;
          }
        }
      } on Object {
        // Ignore broken files and replace them with a fresh token.
      }
    }

    return PrivilegedHelperConnectionInfo(token: const Uuid().v4());
  }

  Future<void> _writeConnectionInfo(
    Directory runtimeDir,
    PrivilegedHelperConnectionInfo info,
  ) async {
    final stateFile = File(
      p.join(runtimeDir.path, gorionPrivilegedHelperStateFileName),
    );
    await stateFile.writeAsString(jsonEncode(info.toJson()), flush: true);
  }
}
