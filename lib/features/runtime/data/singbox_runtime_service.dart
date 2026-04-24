import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:gorion_clean/core/process/current_process.dart';
import 'package:gorion_clean/core/process/running_process_lookup.dart';
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

typedef RuntimeExitCallback =
    void Function(RuntimeSession session, int exitCode);

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
  SingboxRuntimeService? localService,
  SingboxRuntimeService? helperService,
}) {
  final resolvedLocalService =
      localService ??
      SingboxRuntimeService(
        privilegedHelperClient: helperClient ?? WindowsPrivilegedHelperClient(),
      );
  final helperAvailable =
      Platform.isWindows &&
      (privilegedHelperProvisioned ??
          WindowsPrivilegedHelperClient.isProvisionedSync());
  if (helperAvailable) {
    return _AdaptiveSingboxRuntimeService(
      localService: resolvedLocalService,
      helperService:
          helperService ??
          _PrivilegedHelperSingboxRuntimeService(
            helperClient: helperClient ?? WindowsPrivilegedHelperClient(),
          ),
    );
  }

  return resolvedLocalService;
}

class SingboxRuntimeService {
  static const _maxStartupAttempts = 3;

  SingboxRuntimeService({
    SystemProxyService? systemProxyService,
    WindowsRuntimeCleanupWatchdog? windowsRuntimeCleanupWatchdog,
    WindowsPrivilegedHelperClient? privilegedHelperClient,
    Future<RunningProcessLookup> Function(int pid)? runningProcessLookupReader,
  }) : _systemProxyService = systemProxyService ?? const SystemProxyService(),
       _windowsRuntimeCleanupWatchdog =
           windowsRuntimeCleanupWatchdog ??
           const WindowsRuntimeCleanupWatchdog(),
       _privilegedHelperClient = privilegedHelperClient,
       _runningProcessLookupReader =
           runningProcessLookupReader ?? _lookupRunningProcess;

  Process? _process;
  RuntimeSession? _session;
  final List<String> _logs = <String>[];
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  final SystemProxyService _systemProxyService;
  final WindowsRuntimeCleanupWatchdog _windowsRuntimeCleanupWatchdog;
  final WindowsPrivilegedHelperClient? _privilegedHelperClient;
  final Future<RunningProcessLookup> Function(int pid)
  _runningProcessLookupReader;
  SystemProxyLease? _systemProxyLease;
  _WinHttpProxyLease? _winHttpProxyLease;
  Future<void> _lifecycleOperation = Future<void>.value();
  Process? _stoppingProcess;

  RuntimeSession? get session => _session;
  List<String> get logs => List.unmodifiable(_logs);
  bool get launchesWithEmbeddedPrivilegeBroker => false;

  Future<bool> canLaunchWithEmbeddedPrivilegeBroker({
    required RuntimeMode mode,
  }) async {
    return false;
  }

  Future<RuntimeSession> start({
    required String profileId,
    required String templateConfig,
    String? originalTemplateConfig,
    ConnectionTuningSettings connectionTuningSettings =
        const ConnectionTuningSettings(),
    required String urlTestUrl,
    required RuntimeMode mode,
    String? selectedServerTag,
    RuntimeExitCallback? onExit,
  }) {
    return _serializeLifecycle(
      () => _startImpl(
        profileId: profileId,
        templateConfig: templateConfig,
        originalTemplateConfig: originalTemplateConfig,
        connectionTuningSettings: connectionTuningSettings,
        urlTestUrl: urlTestUrl,
        mode: mode,
        selectedServerTag: selectedServerTag,
        onExit: onExit,
      ),
    );
  }

  Future<RuntimeSession> _startImpl({
    required String profileId,
    required String templateConfig,
    String? originalTemplateConfig,
    ConnectionTuningSettings connectionTuningSettings =
        const ConnectionTuningSettings(),
    required String urlTestUrl,
    required RuntimeMode mode,
    String? selectedServerTag,
    RuntimeExitCallback? onExit,
  }) async {
    final runtimeDir = await _runtimeDirectory();
    await _stopImpl();
    await _cleanupOrphanedProcess(runtimeDir);
    await _throwIfOrphanedProcessMarkerStillPresent(runtimeDir);
    await _systemProxyService.cleanupOrphanedState(
      runtimeDir: runtimeDir,
      onLog: _pushLog,
    );
    await _cleanupOrphanedWinHttpProxyState(runtimeDir);

    final binaryFile = await _prepareBinary(runtimeDir);

    Object? startupError;
    StackTrace? startupStackTrace;
    for (var attempt = 1; attempt <= _maxStartupAttempts; attempt += 1) {
      ReservedLoopbackPort? controllerReservation;
      ReservedLoopbackPort? mixedReservation;
      try {
        controllerReservation = await reserveLoopbackPort();
        mixedReservation = await reserveLoopbackPort();
        final controllerPort = controllerReservation.port;
        final mixedPort = mixedReservation.port;
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

        await controllerReservation.close();
        controllerReservation = null;
        await mixedReservation.close();
        mixedReservation = null;

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
          parentPid: currentProcessPid,
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

        process.exitCode.then((code) {
          startupExitCode = code;
          unawaited(_deleteProcessMarker(runtimeDir, expectedPid: process.pid));
          _pushLog('sing-box exited with code $code.');
          if (identical(_stoppingProcess, process)) {
            return;
          }
          if (identical(_process, process)) {
            final activeSession = _session;
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
                _restoreWinHttpProxy(
                  runtimeDir: runtimeDir,
                  lease: winHttpLease,
                ),
              );
            }
            _process = null;
            _session = null;
            if (activeSession != null) {
              onExit?.call(activeSession, code);
            }
          }
        });

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
          await _stopImpl();
          Error.throwWithStackTrace(error, stackTrace);
        }

        if (mode.usesSystemProxy) {
          try {
            _systemProxyLease = await _systemProxyService.enable(
              mode: mode,
              runtimeDir: runtimeDir,
              mixedPort: mixedPort,
              bypassSteam: connectionTuningSettings.bypassSteamForSystemProxy,
              onLog: _pushLog,
            );
          } on Object catch (error, stackTrace) {
            _pushLog(
              'Failed to enable the system proxy: $error',
              isError: true,
            );
            await _stopImpl();
            Error.throwWithStackTrace(error, stackTrace);
          }
          await _enableWinHttpProxy(
            runtimeDir: runtimeDir,
            mixedPort: mixedPort,
            bypassSteam: connectionTuningSettings.bypassSteamForSystemProxy,
          );
        }

        _pushLog('Clash API is ready on ${session.controllerBaseUrl}.');
        _session = session;
        return session;
      } on Object catch (error, stackTrace) {
        startupError = error;
        startupStackTrace = stackTrace;
        if (controllerReservation != null) {
          await controllerReservation.close();
        }
        if (mixedReservation != null) {
          await mixedReservation.close();
        }
        if (attempt >= _maxStartupAttempts ||
            !_shouldRetryStartupAfterError(error)) {
          break;
        }

        _pushLog(
          'Retrying sing-box startup with a fresh local port reservation (attempt ${attempt + 1}/$_maxStartupAttempts).',
          isError: true,
        );
        await _stopImpl();
      }
    }

    if (startupError != null && startupStackTrace != null) {
      Error.throwWithStackTrace(startupError, startupStackTrace);
    }
    throw StateError('Failed to start sing-box for an unknown reason.');
  }

  Future<void> stop() {
    return _serializeLifecycle(_stopImpl);
  }

  Future<void> _stopImpl() async {
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription = null;

    final runtimeDir = await _runtimeDirectory();
    final session = _session;
    final process = _process;
    final systemProxyLease = _systemProxyLease;
    final winHttpProxyLease = _winHttpProxyLease;

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
      } on Object catch (error, stackTrace) {
        restoreError ??= error;
        restoreStackTrace ??= stackTrace;
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
    _stoppingProcess = process;
    try {
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
    } finally {
      if (identical(_stoppingProcess, process)) {
        _stoppingProcess = null;
      }
    }

    if (identical(_process, process)) {
      _process = null;
      _session = null;
    }
    if (identical(_systemProxyLease, systemProxyLease)) {
      _systemProxyLease = null;
    }
    if (identical(_winHttpProxyLease, winHttpProxyLease)) {
      _winHttpProxyLease = null;
    }

    if (restoreError != null && restoreStackTrace != null) {
      Error.throwWithStackTrace(restoreError, restoreStackTrace);
    }
  }

  Future<void> stopForAppExit() async {
    await stop();
  }

  void dispose() {
    unawaited(stopForAppExit());
  }

  Future<T> _serializeLifecycle<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _lifecycleOperation = _lifecycleOperation.catchError((_) {}).then((
      _,
    ) async {
      try {
        completer.complete(await action());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<File> _prepareBinary(Directory runtimeDir) async {
    return prepareSingboxBinary(runtimeDir);
  }

  Future<Directory> _runtimeDirectory() async {
    return ensureGorionRuntimeDirectory();
  }

  @visibleForTesting
  Future<void> cleanupOrphanedProcessForTesting(Directory runtimeDir) {
    return _cleanupOrphanedProcess(runtimeDir);
  }

  @visibleForTesting
  Future<void> ensureNoOrphanedProcessConflictForTesting(Directory runtimeDir) {
    return _throwIfOrphanedProcessMarkerStillPresent(runtimeDir);
  }

  Future<void> _cleanupOrphanedProcess(Directory runtimeDir) async {
    final marker = await _readProcessMarker(runtimeDir);
    if (marker == null) {
      return;
    }

    final matchStatus = await _inspectOrphanedProcessMarker(marker);
    switch (matchStatus) {
      case _OrphanedProcessMatch.matches:
        break;
      case _OrphanedProcessMatch.mismatches:
        _pushLog(
          'Skipping orphaned sing-box cleanup for PID ${marker.pid} because the running process no longer matches the saved runtime marker.',
        );
        await _deleteProcessMarker(runtimeDir, expectedPid: marker.pid);
        return;
      case _OrphanedProcessMatch.missingProcess:
        _pushLog('Removing stale sing-box PID marker for ${marker.pid}.');
        await _deleteProcessMarker(runtimeDir, expectedPid: marker.pid);
        return;
      case _OrphanedProcessMatch.inconclusive:
        _pushLog(
          'Could not verify orphaned sing-box PID ${marker.pid} safely; keeping the runtime marker for a later cleanup attempt.',
          isError: true,
        );
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

  Future<void> _throwIfOrphanedProcessMarkerStillPresent(
    Directory runtimeDir,
  ) async {
    final marker = await _readProcessMarker(runtimeDir);
    if (marker == null) {
      return;
    }

    throw StateError(
      'Gorion could not safely verify whether a previous sing-box runtime with PID ${marker.pid} is still active. Starting a second runtime is blocked to avoid proxy and port conflicts. Close the previous app instance or reboot, then try again.',
    );
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

      final binaryPath = decoded['binaryPath']?.toString().trim();
      final configPath = decoded['configPath']?.toString().trim();

      return _RuntimeProcessMarker(
        pid: pid,
        binaryPath: binaryPath == null || binaryPath.isEmpty
            ? p.join(runtimeDir.path, resolveSingboxAsset().fileName)
            : binaryPath,
        configPath: configPath == null || configPath.isEmpty
            ? p.join(runtimeDir.path, 'current-config.json')
            : configPath,
        updatedAt: DateTime.tryParse(decoded['updatedAt']?.toString() ?? ''),
      );
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
    if (marker.mixedPort <= 0) {
      _pushLog(
        'Skipping stale WinHTTP proxy cleanup because the saved managed port is invalid.',
        isError: true,
      );
      await _deleteWinHttpProxyMarker(runtimeDir);
      return;
    }

    try {
      await helperClient.restoreManagedWinHttpProxy(
        mixedPort: marker.mixedPort,
        bypassSteam: _winHttpProxyMarkerBypassesSteam(marker),
      );
      _pushLog(
        'Asked privileged helper to clean up stale managed WinHTTP proxy settings.',
      );
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
    required bool bypassSteam,
  }) async {
    final helperClient = _privilegedHelperClient;
    if (helperClient == null) {
      return;
    }

    try {
      final managedSettings = await helperClient.enableManagedWinHttpProxy(
        mixedPort: mixedPort,
        bypassSteam: bypassSteam,
      );
      final lease = _WinHttpProxyLease._(
        _WinHttpProxyMarker(
          mixedPort: mixedPort,
          managedSettings: managedSettings,
        ),
      );
      await _writeWinHttpProxyMarker(runtimeDir, lease._marker);
      _winHttpProxyLease = lease;
      _pushLog(
        'WinHTTP proxy enabled through 127.0.0.1:$mixedPort for apps that bypass WinINET.',
      );
    } on Object catch (error, stackTrace) {
      _pushLog('Failed to sync the WinHTTP proxy: $error', isError: true);
      Error.throwWithStackTrace(error, stackTrace);
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
    if (marker.mixedPort <= 0) {
      await _deleteWinHttpProxyMarker(runtimeDir);
      return;
    }

    var shouldDeleteMarker = false;
    try {
      await helperClient.restoreManagedWinHttpProxy(
        mixedPort: marker.mixedPort,
        bypassSteam: _winHttpProxyMarkerBypassesSteam(marker),
      );
      _pushLog('WinHTTP proxy restored to its previous state.');
      shouldDeleteMarker = true;
    } finally {
      if (shouldDeleteMarker) {
        await _deleteWinHttpProxyMarker(runtimeDir);
      }
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

  bool _winHttpProxyMarkerBypassesSteam(_WinHttpProxyMarker marker) {
    final bypassList = marker.managedSettings.bypassList?.toLowerCase() ?? '';
    return bypassList.contains('steampowered.com') ||
        bypassList.contains('steamcommunity.com');
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

  bool _shouldRetryStartupAfterError(Object error) {
    if (error is TimeoutException) {
      return true;
    }

    final message = error.toString().toLowerCase();
    return message.contains('controller became ready') ||
        message.contains('clash api did not start') ||
        message.contains('did not become ready in time') ||
        message.contains('timed out') ||
        message.contains('address already in use') ||
        message.contains('listen tcp') ||
        message.contains('bind');
  }

  Future<_OrphanedProcessMatch> _inspectOrphanedProcessMarker(
    _RuntimeProcessMarker marker,
  ) async {
    final binaryPath = marker.binaryPath?.trim();
    if (binaryPath == null || binaryPath.isEmpty) {
      return _OrphanedProcessMatch.inconclusive;
    }

    final lookup = await _runningProcessLookupReader(marker.pid);
    if (lookup.isMissing) {
      return _OrphanedProcessMatch.missingProcess;
    }
    if (!lookup.isFound) {
      return _OrphanedProcessMatch.inconclusive;
    }

    final expectedBinary = _normalizeComparablePath(binaryPath);
    final currentBinary = lookup.executablePath == null
        ? null
        : _normalizeComparablePath(lookup.executablePath!);
    if (currentBinary != null &&
        currentBinary.isNotEmpty &&
        currentBinary != expectedBinary) {
      return _OrphanedProcessMatch.mismatches;
    }
    if ((currentBinary == null || currentBinary.isEmpty) &&
        !lookup.normalizedCommandLine.contains(
          p.basename(binaryPath).toLowerCase(),
        )) {
      return _OrphanedProcessMatch.mismatches;
    }

    final configPath = marker.configPath?.trim();
    if (configPath != null && configPath.isNotEmpty) {
      final normalizedConfigPath = _normalizeComparablePath(configPath);
      if (!lookup.normalizedCommandLine.contains(normalizedConfigPath)) {
        return _OrphanedProcessMatch.mismatches;
      }
    }

    return _OrphanedProcessMatch.matches;
  }

  static Future<RunningProcessLookup> _lookupRunningProcess(int pid) async {
    if (pid <= 0) {
      return const RunningProcessLookup.missing();
    }

    if (Platform.isWindows) {
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

    final result = await Process.run('ps', ['-p', '$pid', '-o', 'args=']);
    if (result.exitCode == 1) {
      return const RunningProcessLookup.missing();
    }
    if (result.exitCode != 0) {
      return const RunningProcessLookup.unavailable();
    }

    final commandLine = result.stdout.toString().trim();
    if (commandLine.isEmpty) {
      return const RunningProcessLookup.unavailable();
    }
    return RunningProcessLookup.found(commandLine: commandLine);
  }

  String _normalizeComparablePath(String value) {
    final normalized = p.normalize(value).replaceAll('\\', '/');
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
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
  const _RuntimeProcessMarker({
    required this.pid,
    this.binaryPath,
    this.configPath,
    this.updatedAt,
  });

  final int pid;
  final String? binaryPath;
  final String? configPath;
  final DateTime? updatedAt;
}

enum _OrphanedProcessMatch { matches, mismatches, missingProcess, inconclusive }

class _WinHttpProxyLease {
  const _WinHttpProxyLease._(this._marker);

  final _WinHttpProxyMarker _marker;
}

class _WinHttpProxyMarker {
  const _WinHttpProxyMarker({
    required this.mixedPort,
    required this.managedSettings,
  });

  final int mixedPort;
  final WindowsWinHttpProxySettings managedSettings;

  Map<String, dynamic> toJson() {
    return {
      'mixedPort': mixedPort,
      'managedSettings': managedSettings.toJson(),
    };
  }

  factory _WinHttpProxyMarker.fromJson(Map<String, dynamic> json) {
    final managedSettings = WindowsWinHttpProxySettings.fromJson(
      Map<String, dynamic>.from(
        ((json['managedSettings'] as Map?) ?? const <String, dynamic>{})
            .cast<String, dynamic>(),
      ),
    );
    return _WinHttpProxyMarker(
      mixedPort:
          (json['mixedPort'] as num?)?.toInt() ??
          _tryParseManagedWinHttpProxyPort(managedSettings.proxyServer) ??
          0,
      managedSettings: managedSettings,
    );
  }
}

int? _tryParseManagedWinHttpProxyPort(String? proxyServer) {
  final normalized = proxyServer?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  final firstEntry = normalized.split(';').first.trim();
  final endpoint = firstEntry.contains('=')
      ? firstEntry.substring(firstEntry.indexOf('=') + 1).trim()
      : firstEntry;
  final parsed = Uri.tryParse(
    endpoint.contains('://') ? endpoint : 'http://$endpoint',
  );
  final host = parsed?.host.toLowerCase();
  if (parsed == null ||
      !parsed.hasPort ||
      (host != '127.0.0.1' && host != 'localhost')) {
    return null;
  }
  return parsed.port;
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
  Future<bool> canLaunchWithEmbeddedPrivilegeBroker({
    required RuntimeMode mode,
  }) async {
    if (!mode.usesTun) {
      return false;
    }

    try {
      await _helperClient.ensureAvailable();
      return true;
    } on Object {
      return false;
    }
  }

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
    RuntimeExitCallback? onExit,
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
  Future<void> stopForAppExit() async {
    if (_remoteSession == null) {
      return;
    }

    final snapshot = await _helperClient.stopRuntimeIfAvailable();
    if (snapshot == null) {
      return;
    }

    _remoteSession = snapshot.session;
    _replaceLogs(snapshot.logs);
  }

  @override
  void dispose() {
    unawaited(stopForAppExit());
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
  final List<String> _lastLogs = <String>[];
  SingboxRuntimeService? _activeService;

  @override
  RuntimeSession? get session => _activeService?.session;

  @override
  List<String> get logs {
    final activeService = _activeService;
    if (activeService != null) {
      return activeService.logs;
    }
    return List.unmodifiable(_lastLogs);
  }

  @override
  bool get launchesWithEmbeddedPrivilegeBroker => true;

  @override
  Future<bool> canLaunchWithEmbeddedPrivilegeBroker({
    required RuntimeMode mode,
  }) async {
    return identical(await _resolveServiceForStart(mode), _helperService);
  }

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
    RuntimeExitCallback? onExit,
  }) {
    return _serializeLifecycle(
      () => _startAdaptive(
        profileId: profileId,
        templateConfig: templateConfig,
        originalTemplateConfig: originalTemplateConfig,
        connectionTuningSettings: connectionTuningSettings,
        urlTestUrl: urlTestUrl,
        mode: mode,
        selectedServerTag: selectedServerTag,
        onExit: onExit,
      ),
    );
  }

  Future<RuntimeSession> _startAdaptive({
    required String profileId,
    required String templateConfig,
    String? originalTemplateConfig,
    required ConnectionTuningSettings connectionTuningSettings,
    required String urlTestUrl,
    required RuntimeMode mode,
    String? selectedServerTag,
    RuntimeExitCallback? onExit,
  }) async {
    final nextService = await _resolveServiceForStart(mode);
    final previousService = _activeService;
    if (previousService != null && !identical(previousService, nextService)) {
      await previousService.stop();
      _rememberLogs(previousService);
      _activeService = null;
    }

    try {
      final session = await nextService.start(
        profileId: profileId,
        templateConfig: templateConfig,
        originalTemplateConfig: originalTemplateConfig,
        connectionTuningSettings: connectionTuningSettings,
        urlTestUrl: urlTestUrl,
        mode: mode,
        selectedServerTag: selectedServerTag,
        onExit: onExit,
      );
      _activeService = nextService;
      _rememberLogs(nextService);
      return session;
    } on Object {
      _rememberLogs(nextService);
      rethrow;
    }
  }

  @override
  Future<void> stop() {
    return _serializeLifecycle(_stopAdaptive);
  }

  Future<void> _stopAdaptive() async {
    final activeService = _activeService;
    if (activeService != null) {
      try {
        await activeService.stop();
        _activeService = null;
      } finally {
        _rememberLogs(activeService);
      }
      return;
    }

    if (_localService.session != null) {
      try {
        await _localService.stop();
      } finally {
        _rememberLogs(_localService);
      }
    }
    if (_helperService.session != null) {
      try {
        await _helperService.stop();
      } finally {
        _rememberLogs(_helperService);
      }
    }
  }

  @override
  Future<void> stopForAppExit() {
    return _serializeLifecycle(_stopForAppExitAdaptive);
  }

  Future<void> _stopForAppExitAdaptive() async {
    final activeService = _activeService;
    if (activeService != null) {
      try {
        await activeService.stopForAppExit();
        _activeService = null;
      } finally {
        _rememberLogs(activeService);
      }
      return;
    }

    if (_localService.session != null) {
      try {
        await _localService.stopForAppExit();
      } finally {
        _rememberLogs(_localService);
      }
    }
    if (_helperService.session != null) {
      try {
        await _helperService.stopForAppExit();
      } finally {
        _rememberLogs(_helperService);
      }
    }
  }

  @override
  void dispose() {
    unawaited(stopForAppExit());
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

  Future<SingboxRuntimeService> _resolveServiceForStart(
    RuntimeMode mode,
  ) async {
    final preferredService = _serviceForMode(mode);
    if (!identical(preferredService, _helperService)) {
      return preferredService;
    }
    if (await _helperService.canLaunchWithEmbeddedPrivilegeBroker(mode: mode)) {
      return _helperService;
    }
    return _localService;
  }

  void _rememberLogs(SingboxRuntimeService service) {
    _lastLogs
      ..clear()
      ..addAll(service.logs);
  }
}
