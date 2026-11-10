import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gorion/core/privileged_helper/privileged_helper_protocol.dart';
import 'package:gorion/core/process/process_runner.dart';
import 'package:gorion/features/runtime/data/singbox_runtime_service.dart';
import 'package:gorion/features/runtime/data/singbox_runtime_support.dart';
import 'package:gorion/features/runtime/data/windows_winhttp_proxy_service.dart';
import 'package:gorion/features/settings/model/connection_tuning_settings.dart';
import 'package:uuid/uuid.dart';

/// Entry point of the privileged helper process (`--gorion-privileged-helper`).
///
/// Windows: the GUI starts the helper on demand through an elevated Scheduled
/// Task and hands over a one-time bootstrap file with the auth token.
///
/// macOS: the helper is a root launchd daemon installed once by the user. It
/// generates a token per launch and publishes it in a root:admin-readable
/// state file; the GUI reads it from the shared support directory.
Future<void> runPrivilegedHelperServer() async {
  if (!isPrivilegedHelperSupported()) {
    return;
  }
  if (Platform.isMacOS) {
    // The daemon runs as root: keep every runtime artifact in the shared
    // root-owned location instead of /var/root's Application Support.
    overrideGorionRuntimeRoot(gorionPrivilegedHelperMacosRuntimeDir);
  }
  final server = PrivilegedHelperServer();
  await server.run();
}

class PrivilegedHelperServer {
  PrivilegedHelperServer()
    : _runtimeService = SingboxRuntimeService(),
      _winHttpProxyService = const WindowsWinHttpProxyService();

  final SingboxRuntimeService _runtimeService;
  final WindowsWinHttpProxyService _winHttpProxyService;
  HttpServer? _server;
  Timer? _ownerTimer;
  bool _checkingOwner = false;
  Future<void> _mutations = Future<void>.value();
  int _ownerGeneration = 0;
  String? _authToken;
  PrivilegedHelperConnectionInfo? _connectionInfo;
  WindowsWinHttpProxySettings? _previousWinHttpSettings;
  WindowsWinHttpProxySettings? _managedWinHttpSettings;

  Future<void> run() async {
    if (Platform.isMacOS) {
      await _runMacosDaemon();
      return;
    }
    if (Platform.isWindows) {
      await _runWindowsHelper();
      return;
    }
  }

  Future<void> _runMacosDaemon() async {
    // Ensures the shared runtime directory exists before the core starts.
    await ensureGorionRuntimeDirectory();
    _authToken = const Uuid().v4();
    _connectionInfo = PrivilegedHelperConnectionInfo(
      token: _authToken,
      launchId: const Uuid().v4(),
    );

    if (!await _bindServer()) {
      return;
    }

    await _writeMacosStateFile();

    // A previous daemon instance may have left a sing-box core behind.
    await _runtimeService.recoverFromPreviousSession();

    await _serve();
  }

  Future<void> _runWindowsHelper() async {
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

    if (!await _bindServer()) {
      await _writeFailureState(
        runtimeDir,
        _connectionInfo!.copyWith(
          lastError:
              'Failed to bind the privileged helper to ${_connectionInfo!.host}:${_connectionInfo!.port}.',
        ),
      );
      return;
    }

    await _writeConnectionInfo(
      runtimeDir,
      _connectionInfo!.copyWith(pid: pid, clearLastError: true),
    );

    await _serve();
  }

  Future<bool> _bindServer() async {
    try {
      _server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        _connectionInfo!.port,
      );
      return true;
    } on SocketException catch (error) {
      stderr.writeln(
        'Gorion privileged helper failed to bind to ${_connectionInfo!.host}:${_connectionInfo!.port}: $error',
      );
      return false;
    }
  }

  Future<void> _serve() async {
    await for (final request in _server!) {
      if (request.method == 'POST') {
        _mutations = _mutations.then((_) => _handleRequest(request)).catchError(
          (Object error) {
            stderr.writeln('Helper request failed: $error');
          },
        );
      } else {
        unawaited(
          _handleRequest(request).catchError((Object error) {
            stderr.writeln('Helper request failed: $error');
          }),
        );
      }
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final token = request.headers.value(gorionPrivilegedHelperAuthHeader);
      final authenticated = _isValidToken(token);
      final method = request.method.toUpperCase();
      final path = request.uri.path;
      if (method == 'GET' && path == '/health') {
        await _writeJson(request.response, HttpStatus.ok, {
          'ok': true,
          'protocolVersion': gorionPrivilegedHelperProtocolVersion,
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
        final ownerPid = (body['ownerPid'] as num?)?.toInt();
        if (Platform.isMacOS) {
          if (ownerPid == null || ownerPid <= 1) {
            throw const FormatException('Missing runtime owner PID.');
          }
          final identity = await _ownerIdentity(ownerPid);
          if (identity.isEmpty) throw StateError('Runtime owner has exited.');
          _watchOwner(ownerPid, identity);
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
        _ownerTimer?.cancel();
        _ownerGeneration++;
        await _runtimeService.stop();
        await _writeJson(
          request.response,
          HttpStatus.ok,
          _runtimeStateSnapshot().toJson(),
        );
        return;
      }
      if (Platform.isWindows &&
          method == 'POST' &&
          path == '/windows/winhttp-proxy/managed-enable') {
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
      if (Platform.isWindows &&
          method == 'POST' &&
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

  Future<String> _ownerIdentity(int ownerPid) async {
    final result = await runProcessWithTimeout('/bin/ps', [
      '-p',
      '$ownerPid',
      '-o',
      'lstart=',
      '-o',
      'comm=',
    ], timeout: const Duration(seconds: 2));
    return result.exitCode == 0 ? result.stdout.toString().trim() : '';
  }

  void _watchOwner(int ownerPid, String identity) {
    _ownerTimer?.cancel();
    final generation = ++_ownerGeneration;
    _ownerTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_checkingOwner) return;
      _checkingOwner = true;
      try {
        final current = await _ownerIdentity(ownerPid);
        if (generation != _ownerGeneration || current == identity) return;
        _ownerTimer?.cancel();
        await _runtimeService.stop();
      } on Object catch (error) {
        stderr.writeln('Runtime owner check failed: $error');
      } finally {
        _checkingOwner = false;
      }
    });
  }

  PrivilegedHelperRuntimeSnapshot _runtimeStateSnapshot() {
    return PrivilegedHelperRuntimeSnapshot(
      session: _runtimeService.session,
      logs: _runtimeService.logs,
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

  /// Compares in constant time so response timing does not leak the token.
  bool _isValidToken(String? candidate) {
    final expected = _authToken;
    if (candidate == null ||
        expected == null ||
        candidate.length != expected.length) {
      return false;
    }
    var difference = 0;
    for (var i = 0; i < expected.length; i += 1) {
      difference |= candidate.codeUnitAt(i) ^ expected.codeUnitAt(i);
    }
    return difference == 0;
  }

  /// Large enough for a subscription with thousands of servers, small enough
  /// that a local process cannot exhaust the root daemon's memory.
  static const _maxRequestBodyBytes = 16 * 1024 * 1024;

  Future<Map<String, dynamic>> _readJsonBody(HttpRequest request) async {
    if (request.contentLength > _maxRequestBodyBytes) {
      throw const FormatException('Request body is too large.');
    }
    var received = 0;
    final payload = await utf8.decoder
        .bind(
          request.map((chunk) {
            received += chunk.length;
            if (received > _maxRequestBodyBytes) {
              throw const FormatException('Request body is too large.');
            }
            return chunk;
          }),
        )
        .join()
        .timeout(const Duration(seconds: 15));
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

  /// macOS: publishes the connection state (token included) into the shared
  /// support directory. The file is root:admin 0640 — only admin users (the
  /// ones allowed to install the daemon) can read the token.
  Future<void> _writeMacosStateFile() async {
    final stateFile = File(gorionPrivilegedHelperMacosStatePath);
    await stateFile.parent.create(recursive: true);
    final pending = File('${stateFile.path}.tmp');
    await pending.writeAsString(
      jsonEncode(
        _connectionInfo!
            .copyWith(pid: pid, clearLastError: true)
            .toJson(includeToken: true),
      ),
      flush: true,
    );
    for (final command in [
      ['/usr/sbin/chown', 'root:admin', pending.path],
      ['/bin/chmod', '640', pending.path],
    ]) {
      final result = await runProcessWithTimeout(
        command.first,
        command.sublist(1),
      );
      if (result.exitCode != 0) {
        throw StateError('Cannot secure helper state file.');
      }
    }
    await pending.rename(stateFile.path);
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
