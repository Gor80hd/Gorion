import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gorion_clean/core/windows/privileged_helper_client.dart';
import 'package:gorion_clean/core/constants/singbox_assets.dart';
import 'package:gorion_clean/core/logging/gorion_console_log.dart';
import 'package:gorion_clean/features/runtime/data/clash_api_client.dart';
import 'package:gorion_clean/features/runtime/data/singbox_config_builder.dart';
import 'package:gorion_clean/features/runtime/data/singbox_runtime_support.dart';
import 'package:gorion_clean/features/runtime/data/system_proxy_service.dart';
import 'package:gorion_clean/features/runtime/data/windows_winhttp_proxy_service.dart';
import 'package:gorion_clean/features/runtime/data/windows_runtime_cleanup_watchdog.dart';
import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';
import 'package:gorion_clean/features/settings/data/connection_tuning_config_overrides.dart';
import 'package:gorion_clean/features/settings/model/connection_tuning_settings.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

const _runtimeProcessMarkerFileName = 'runtime-process.json';
const _winHttpProxyMarkerFileName = 'winhttp-proxy.json';

enum SingboxRuntimeBackend { local, privilegedHelper }

SingboxRuntimeBackend selectSingboxRuntimeBackend({
  required RuntimeMode mode,
  required bool privilegedHelperProvisioned,
}) {
  if (privilegedHelperProvisioned && mode.usesTun) {
    return SingboxRuntimeBackend.privilegedHelper;
  }

  return SingboxRuntimeBackend.local;
}

SingboxRuntimeService buildSingboxRuntimeService({
  bool? privilegedHelperProvisioned,
  WindowsPrivilegedHelperClient? helperClient,
}) {
  final helperAvailable =
      Platform.isWindows &&
      (privilegedHelperProvisioned ??
          WindowsPrivilegedHelperClient.isProvisionedSync());
  if (helperAvailable) {
    return _AdaptiveSingboxRuntimeService(
      localService: SingboxRuntimeService(
        privilegedHelperClient: helperClient ?? WindowsPrivilegedHelperClient(),
      ),
      helperService: _PrivilegedHelperSingboxRuntimeService(
        helperClient: helperClient ?? WindowsPrivilegedHelperClient(),
      ),
    );
  }

  return SingboxRuntimeService();
}

class SingboxRuntimeService {
  SingboxRuntimeService({
    SystemProxyService? systemProxyService,
    WindowsRuntimeCleanupWatchdog? windowsRuntimeCleanupWatchdog,
    WindowsPrivilegedHelperClient? privilegedHelperClient,
  }) : _systemProxyService = systemProxyService ?? const SystemProxyService(),
       _windowsRuntimeCleanupWatchdog =
           windowsRuntimeCleanupWatchdog ??
           const WindowsRuntimeCleanupWatchdog(),
       _privilegedHelperClient = privilegedHelperClient;

  Process? _process;
  RuntimeSession? _session;
  final List<String> _logs = <String>[];
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  final SystemProxyService _systemProxyService;
  final WindowsRuntimeCleanupWatchdog _windowsRuntimeCleanupWatchdog;
  final WindowsPrivilegedHelperClient? _privilegedHelperClient;
  SystemProxyLease? _systemProxyLease;
  _WinHttpProxyLease? _winHttpProxyLease;

  RuntimeSession? get session => _session;
  List<String> get logs => List.unmodifiable(_logs);
  bool get launchesWithEmbeddedPrivilegeBroker => false;

  Future<RuntimeSession> start({
    required String profileId,
    required String templateConfig,
    String? originalTemplateConfig,
    ConnectionTuningSettings connectionTuningSettings =
        const ConnectionTuningSettings(),
    required String urlTestUrl,
    required RuntimeMode mode,
    String? selectedServerTag,
  }) async {
    final runtimeDir = await _runtimeDirectory();
    await stop();
    await _cleanupOrphanedProcess(runtimeDir);
    await _systemProxyService.cleanupOrphanedState(
      runtimeDir: runtimeDir,
      onLog: _pushLog,
    );
    await _cleanupOrphanedWinHttpProxyState(runtimeDir);

    final binaryFile = await _prepareBinary(runtimeDir);
    final controllerPort = await _findFreePort();
    final mixedPort = await _findFreePort();
    final secret = const Uuid().v4();

    final built = SingboxConfigBuilder.build(
      templateConfig: templateConfig,
      splitTunnelSettings: connectionTuningSettings.splitTunnel,
      mode: mode,
      mixedPort: mixedPort,
      controllerPort: controllerPort,
      controllerSecret: secret,
      urlTestUrl: urlTestUrl,
      selectedServerTag: selectedServerTag,
    );

    final configFile = File(p.join(runtimeDir.path, 'current-config.json'));
    await configFile.writeAsString(built.configJson);

    _pushLog('Preparing sing-box runtime for profile $profileId.');
    _pushLog(
      'Runtime config written to ${configFile.path}. controllerPort=$controllerPort mixedPort=$mixedPort mode=${mode.name} selectedServer=${selectedServerTag ?? '<default>'}.',
    );
    for (final line in describeConnectionTuningDiagnostics(
      originalTemplateConfig: originalTemplateConfig ?? templateConfig,
      effectiveTemplateConfig: templateConfig,
      settings: connectionTuningSettings,
      selectedServerTag: selectedServerTag,
    )) {
      _pushLog(line);
    }
    _pushLog(
      'Launching sing-box $singboxVersion: ${binaryFile.path} run -c ${configFile.path}',
    );

    late final Process process;
    try {
      process = await Process.start(
        binaryFile.path,
        ['run', '-c', configFile.path],
        workingDirectory: runtimeDir.path,
        mode: ProcessStartMode.normal,
      );
    } on Object catch (error, stackTrace) {
      _pushLog('Failed to start sing-box process: $error', isError: true);
      Error.throwWithStackTrace(error, stackTrace);
    }

    _process = process;
    _pushLog('sing-box process started with PID ${process.pid}.');
    await _writeProcessMarker(
      runtimeDir,
      pid: process.pid,
      binaryPath: binaryFile.path,
      configPath: configFile.path,
    );
    await _windowsRuntimeCleanupWatchdog.arm(
      runtimeDir: runtimeDir,
      parentPid: pid,
      childPid: process.pid,
      onLog: _pushLog,
    );

    int? startupExitCode;
    _stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _pushLog('STDOUT $line'));
    _stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _pushLog('STDERR $line', isError: true));

    process.exitCode.then((code) {
      startupExitCode = code;
      unawaited(_deleteProcessMarker(runtimeDir, expectedPid: process.pid));
      if (identical(_process, process)) {
        final lease = _systemProxyLease;
        final winHttpLease = _winHttpProxyLease;
        _systemProxyLease = null;
        _winHttpProxyLease = null;
        if (lease != null) {
          unawaited(
            _systemProxyService.restore(
              runtimeDir: runtimeDir,
              lease: lease,
              onLog: _pushLog,
            ),
          );
        }
        if (winHttpLease != null) {
          unawaited(
            _restoreWinHttpProxy(runtimeDir: runtimeDir, lease: winHttpLease),
          );
        }
        _pushLog('sing-box exited with code $code.');
        _process = null;
        _session = null;
      }
    });

    final session = RuntimeSession(
      profileId: profileId,
      mode: mode,
      binaryPath: binaryFile.path,
      configPath: configFile.path,
      controllerPort: controllerPort,
      mixedPort: mixedPort,
      secret: secret,
      manualSelectorTag: built.manualSelectorTag,
      autoGroupTag: built.autoGroupTag,
    );

    final clashClient = ClashApiClient.fromSession(session);
    try {
      await clashClient.waitUntilReady(
        onLog: _pushLog,
        abortReason: () {
          final exitCode = startupExitCode;
          if (exitCode == null) {
            return null;
          }

          return 'sing-box exited before the local controller became ready. Exit code: $exitCode. Check runtime logs for stderr details.';
        },
      );
    } on Object catch (error, stackTrace) {
      _pushLog('The Clash API did not start: $error', isError: true);
      _pushLog('Stopping sing-box after startup failure.');
      await stop();
      Error.throwWithStackTrace(error, stackTrace);
    }

    if (mode.usesSystemProxy) {
      try {
        _systemProxyLease = await _systemProxyService.enable(
          mode: mode,
          runtimeDir: runtimeDir,
          mixedPort: mixedPort,
          onLog: _pushLog,
        );
      } on Object catch (error, stackTrace) {
        _pushLog('Failed to enable the system proxy: $error', isError: true);
        await stop();
        Error.throwWithStackTrace(error, stackTrace);
      }
      await _enableWinHttpProxy(runtimeDir: runtimeDir, mixedPort: mixedPort);
    }

    _pushLog('Clash API is ready on ${session.controllerBaseUrl}.');
    _session = session;
    return session;
  }

  Future<void> stop() async {
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription = null;

    final runtimeDir = await _runtimeDirectory();
    final session = _session;
    final process = _process;
    final systemProxyLease = _systemProxyLease;
    final winHttpProxyLease = _winHttpProxyLease;
    _process = null;
    _session = null;
    _systemProxyLease = null;
    _winHttpProxyLease = null;

    Object? restoreError;
    StackTrace? restoreStackTrace;
    if (systemProxyLease != null || session?.mode.usesSystemProxy == true) {
      try {
        await _systemProxyService.restore(
          runtimeDir: runtimeDir,
          lease: systemProxyLease,
          onLog: _pushLog,
        );
      } on Object catch (error, stackTrace) {
        restoreError = error;
        restoreStackTrace = stackTrace;
        _pushLog('Failed to restore the system proxy: $error', isError: true);
      }
    }
    if (winHttpProxyLease != null || session?.mode.usesSystemProxy == true) {
      try {
        await _restoreWinHttpProxy(
          runtimeDir: runtimeDir,
          lease: winHttpProxyLease,
        );
      } on Object catch (error) {
        _pushLog('Failed to restore the WinHTTP proxy: $error', isError: true);
      }
    }

    if (process == null) {
      if (restoreError != null && restoreStackTrace != null) {
        Error.throwWithStackTrace(restoreError, restoreStackTrace);
      }
      return;
    }

    _pushLog('Stopping sing-box PID ${process.pid}.');
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 4));
    } on TimeoutException {
      _pushLog(
        'sing-box did not exit gracefully, forcing termination.',
        isError: true,
      );
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () => -1,
      );
    }

    await _deleteProcessMarker(runtimeDir, expectedPid: process.pid);

    if (restoreError != null && restoreStackTrace != null) {
      Error.throwWithStackTrace(restoreError, restoreStackTrace);
    }
  }

  void dispose() {
    unawaited(stop());
  }

  Future<File> _prepareBinary(Directory runtimeDir) async {
    return prepareSingboxBinary(runtimeDir);
  }

  Future<Directory> _runtimeDirectory() async {
    return ensureGorionRuntimeDirectory();
  }

  Future<int> _findFreePort() async {
    return findFreePort();
  }

  Future<void> _cleanupOrphanedProcess(Directory runtimeDir) async {
    final marker = await _readProcessMarker(runtimeDir);
    if (marker == null) {
      return;
    }

    final killed = Process.killPid(marker.pid);
    if (killed) {
      _pushLog(
        'Stopped orphaned sing-box PID ${marker.pid} from a previous app session.',
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    } else {
      _pushLog('Removing stale sing-box PID marker for ${marker.pid}.');
    }

    await _deleteProcessMarker(runtimeDir, expectedPid: marker.pid);
  }

  Future<void> _writeProcessMarker(
    Directory runtimeDir, {
    required int pid,
    required String binaryPath,
    required String configPath,
  }) async {
    final markerFile = _processMarkerFile(runtimeDir);
    final payload = <String, Object>{
      'pid': pid,
      'binaryPath': binaryPath,
      'configPath': configPath,
      'updatedAt': DateTime.now().toIso8601String(),
    };
    await markerFile.writeAsString(jsonEncode(payload), flush: true);
  }

  Future<_RuntimeProcessMarker?> _readProcessMarker(
    Directory runtimeDir,
  ) async {
    final markerFile = _processMarkerFile(runtimeDir);
    if (!await markerFile.exists()) {
      return null;
    }

    try {
      final decoded = jsonDecode(await markerFile.readAsString());
      if (decoded is! Map) {
        return null;
      }

      final pid = _tryParseInt(decoded['pid']);
      if (pid == null || pid <= 0) {
        return null;
      }

      return _RuntimeProcessMarker(pid: pid);
    } catch (_) {
      return null;
    }
  }

  Future<void> _deleteProcessMarker(
    Directory runtimeDir, {
    int? expectedPid,
  }) async {
    final markerFile = _processMarkerFile(runtimeDir);
    if (!await markerFile.exists()) {
      return;
    }

    if (expectedPid != null) {
      final marker = await _readProcessMarker(runtimeDir);
      if (marker != null && marker.pid != expectedPid) {
        return;
      }
    }

    try {
      await markerFile.delete();
    } on FileSystemException {
      return;
    }
  }

  Future<void> _cleanupOrphanedWinHttpProxyState(Directory runtimeDir) async {
    final marker = await _readWinHttpProxyMarker(runtimeDir);
    if (marker == null) {
      return;
    }

    final helperClient = _privilegedHelperClient;
    if (helperClient == null) {
      return;
    }

    try {
      final current = await helperClient.readWinHttpProxySettings();
      if (current.matches(marker.managedSettings)) {
        await helperClient.applyWinHttpProxySettings(marker.previousSettings);
        _pushLog(
          'Restored WinHTTP proxy settings left behind by a previous app session.',
        );
      } else {
        _pushLog(
          'WinHTTP proxy settings changed outside Gorion; keeping the current values and clearing the stale marker.',
        );
      }
    } on Object catch (error) {
      _pushLog(
        'Failed to clean up stale WinHTTP proxy settings: $error',
        isError: true,
      );
      return;
    }

    await _deleteWinHttpProxyMarker(runtimeDir);
  }

  Future<void> _enableWinHttpProxy({
    required Directory runtimeDir,
    required int mixedPort,
  }) async {
    final helperClient = _privilegedHelperClient;
    if (helperClient == null) {
      return;
    }

    try {
      final previousSettings = await helperClient.readWinHttpProxySettings();
      final managedSettings = previousSettings.copyWith(
        proxyServer: buildManagedWindowsWinHttpProxyServer(mixedPort),
        bypassList: buildManagedWindowsWinHttpBypassList(),
      );
      final lease = _WinHttpProxyLease._(
        _WinHttpProxyMarker(
          previousSettings: previousSettings,
          managedSettings: managedSettings,
        ),
      );
      await _writeWinHttpProxyMarker(runtimeDir, lease._marker);
      try {
        await helperClient.applyWinHttpProxySettings(managedSettings);
      } on Object {
        try {
          await helperClient.applyWinHttpProxySettings(previousSettings);
        } on Object {
          rethrow;
        }
        await _deleteWinHttpProxyMarker(runtimeDir);
        rethrow;
      }
      _winHttpProxyLease = lease;
      _pushLog(
        'WinHTTP proxy enabled through 127.0.0.1:$mixedPort for apps that bypass WinINET.',
      );
    } on Object catch (error) {
      _pushLog('Failed to sync the WinHTTP proxy: $error', isError: true);
    }
  }

  Future<void> _restoreWinHttpProxy({
    required Directory runtimeDir,
    _WinHttpProxyLease? lease,
  }) async {
    final helperClient = _privilegedHelperClient;
    final marker = lease?._marker ?? await _readWinHttpProxyMarker(runtimeDir);
    if (helperClient == null || marker == null) {
      return;
    }

    try {
      final current = await helperClient.readWinHttpProxySettings();
      if (!current.matches(marker.managedSettings)) {
        _pushLog(
          'WinHTTP proxy settings changed outside Gorion; skipping restore to avoid overwriting newer values.',
        );
        return;
      }

      await helperClient.applyWinHttpProxySettings(marker.previousSettings);
      _pushLog('WinHTTP proxy restored to its previous state.');
    } finally {
      await _deleteWinHttpProxyMarker(runtimeDir);
    }
  }

  Future<_WinHttpProxyMarker?> _readWinHttpProxyMarker(
    Directory runtimeDir,
  ) async {
    final markerFile = _winHttpProxyMarkerFile(runtimeDir);
    if (!await markerFile.exists()) {
      return null;
    }

    try {
      final decoded = jsonDecode(await markerFile.readAsString());
      if (decoded is! Map) {
        return null;
      }

      return _WinHttpProxyMarker.fromJson(
        Map<String, dynamic>.from(decoded.cast<String, dynamic>()),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeWinHttpProxyMarker(
    Directory runtimeDir,
    _WinHttpProxyMarker marker,
  ) async {
    final markerFile = _winHttpProxyMarkerFile(runtimeDir);
    await markerFile.writeAsString(jsonEncode(marker.toJson()), flush: true);
  }

  Future<void> _deleteWinHttpProxyMarker(Directory runtimeDir) async {
    final markerFile = _winHttpProxyMarkerFile(runtimeDir);
    if (!await markerFile.exists()) {
      return;
    }

    try {
      await markerFile.delete();
    } on FileSystemException {
      return;
    }
  }

  File _processMarkerFile(Directory runtimeDir) {
    return File(p.join(runtimeDir.path, _runtimeProcessMarkerFileName));
  }

  File _winHttpProxyMarkerFile(Directory runtimeDir) {
    return File(p.join(runtimeDir.path, _winHttpProxyMarkerFileName));
  }

  int? _tryParseInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '');
  }

  void _pushLog(String line, {bool isError = false}) {
    final timestamp = DateTime.now().toIso8601String();
    final entry = '[$timestamp] $line';
    _logs.add(entry);
    GorionConsoleLog.connect(line, isError: isError);
    if (_logs.length > 200) {
      _logs.removeRange(0, _logs.length - 200);
    }
  }
}

class _RuntimeProcessMarker {
  const _RuntimeProcessMarker({required this.pid});

  final int pid;
}

class _WinHttpProxyLease {
  const _WinHttpProxyLease._(this._marker);

  final _WinHttpProxyMarker _marker;
}

class _WinHttpProxyMarker {
  const _WinHttpProxyMarker({
    required this.previousSettings,
    required this.managedSettings,
  });

  final WindowsWinHttpProxySettings previousSettings;
  final WindowsWinHttpProxySettings managedSettings;

  Map<String, dynamic> toJson() {
    return {
      'previousSettings': previousSettings.toJson(),
      'managedSettings': managedSettings.toJson(),
    };
  }

  factory _WinHttpProxyMarker.fromJson(Map<String, dynamic> json) {
    return _WinHttpProxyMarker(
      previousSettings: WindowsWinHttpProxySettings.fromJson(
        Map<String, dynamic>.from(
          ((json['previousSettings'] as Map?) ?? const <String, dynamic>{})
              .cast<String, dynamic>(),
        ),
      ),
      managedSettings: WindowsWinHttpProxySettings.fromJson(
        Map<String, dynamic>.from(
          ((json['managedSettings'] as Map?) ?? const <String, dynamic>{})
              .cast<String, dynamic>(),
        ),
      ),
    );
  }
}

class _PrivilegedHelperSingboxRuntimeService extends SingboxRuntimeService {
  _PrivilegedHelperSingboxRuntimeService({
    required WindowsPrivilegedHelperClient helperClient,
  }) : _helperClient = helperClient;

  final WindowsPrivilegedHelperClient _helperClient;
  RuntimeSession? _remoteSession;
  final List<String> _remoteLogs = <String>[];

  @override
  RuntimeSession? get session => _remoteSession;

  @override
  List<String> get logs => List.unmodifiable(_remoteLogs);

  @override
  bool get launchesWithEmbeddedPrivilegeBroker => true;

  @override
  Future<RuntimeSession> start({
    required String profileId,
    required String templateConfig,
    String? originalTemplateConfig,
    ConnectionTuningSettings connectionTuningSettings =
        const ConnectionTuningSettings(),
    required String urlTestUrl,
    required RuntimeMode mode,
    String? selectedServerTag,
  }) async {
    final snapshot = await _helperClient.startRuntime(
      profileId: profileId,
      templateConfig: templateConfig,
      originalTemplateConfig: originalTemplateConfig,
      connectionTuningSettings: connectionTuningSettings,
      urlTestUrl: urlTestUrl,
      mode: mode,
      selectedServerTag: selectedServerTag,
    );
    _remoteSession = snapshot.session;
    _replaceLogs(snapshot.logs);
    final session = _remoteSession;
    if (session == null) {
      throw StateError(
        'Privileged helper did not return a running sing-box session.',
      );
    }
    return session;
  }

  @override
  Future<void> stop() async {
    final snapshot = await _helperClient.stopRuntime();
    _remoteSession = snapshot.session;
    _replaceLogs(snapshot.logs);
  }

  @override
  void dispose() {
    unawaited(stop());
  }

  void _replaceLogs(List<String> nextLogs) {
    _remoteLogs
      ..clear()
      ..addAll(nextLogs);
  }
}

class _AdaptiveSingboxRuntimeService extends SingboxRuntimeService {
  _AdaptiveSingboxRuntimeService({
    required SingboxRuntimeService localService,
    required SingboxRuntimeService helperService,
  }) : _localService = localService,
       _helperService = helperService;

  final SingboxRuntimeService _localService;
  final SingboxRuntimeService _helperService;
  SingboxRuntimeService? _activeService;

  @override
  RuntimeSession? get session => _activeService?.session;

  @override
  List<String> get logs => _activeService?.logs ?? const <String>[];

  @override
  bool get launchesWithEmbeddedPrivilegeBroker => true;

  @override
  Future<RuntimeSession> start({
    required String profileId,
    required String templateConfig,
    String? originalTemplateConfig,
    ConnectionTuningSettings connectionTuningSettings =
        const ConnectionTuningSettings(),
    required String urlTestUrl,
    required RuntimeMode mode,
    String? selectedServerTag,
  }) async {
    final nextService = _serviceForMode(mode);
    final previousService = _activeService;
    if (previousService != null && !identical(previousService, nextService)) {
      await previousService.stop();
    }

    final session = await nextService.start(
      profileId: profileId,
      templateConfig: templateConfig,
      originalTemplateConfig: originalTemplateConfig,
      connectionTuningSettings: connectionTuningSettings,
      urlTestUrl: urlTestUrl,
      mode: mode,
      selectedServerTag: selectedServerTag,
    );
    _activeService = nextService;
    return session;
  }

  @override
  Future<void> stop() async {
    final activeService = _activeService;
    _activeService = null;
    if (activeService != null) {
      await activeService.stop();
      return;
    }

    if (_localService.session != null) {
      await _localService.stop();
    }
    if (_helperService.session != null) {
      await _helperService.stop();
    }
  }

  @override
  void dispose() {
    unawaited(stop());
  }

  SingboxRuntimeService _serviceForMode(RuntimeMode mode) {
    return switch (selectSingboxRuntimeBackend(
      mode: mode,
      privilegedHelperProvisioned: true,
    )) {
      SingboxRuntimeBackend.local => _localService,
      SingboxRuntimeBackend.privilegedHelper => _helperService,
    };
  }
}
