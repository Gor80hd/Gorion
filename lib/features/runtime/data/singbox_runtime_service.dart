import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:gorion/core/constants/singbox_assets.dart';
import 'package:gorion/core/logging/gorion_console_log.dart';
import 'package:gorion/core/privileged_helper/privileged_helper_client.dart';
import 'package:gorion/core/process/current_process.dart';
import 'package:gorion/core/process/process_runner.dart';
import 'package:gorion/core/process/running_process_lookup.dart';
import 'package:gorion/features/runtime/data/clash_api_client.dart';
import 'package:gorion/features/runtime/data/runtime_cleanup_watchdog.dart';
import 'package:gorion/features/runtime/data/runtime_engine.dart';
import 'package:gorion/features/runtime/data/singbox_config_builder.dart';
import 'package:gorion/features/runtime/data/singbox_runtime_support.dart';
import 'package:gorion/features/runtime/data/system_proxy_service.dart';
import 'package:gorion/features/runtime/data/windows_winhttp_proxy_service.dart';
import 'package:gorion/features/runtime/model/runtime_mode.dart';
import 'package:gorion/features/runtime/model/runtime_models.dart';
import 'package:gorion/features/settings/data/connection_tuning_config_overrides.dart';
import 'package:gorion/features/settings/model/connection_tuning_settings.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

const _runtimeProcessMarkerFileName = 'runtime-process.json';
const _winHttpProxyMarkerFileName = 'winhttp-proxy.json';

/// Owns the local sing-box process and everything attached to it: the
/// process marker, the cleanup watchdog, the system proxy lease and the
/// WinHTTP lease.
///
/// Reliability contract:
/// - every startup attempt cleans up after itself on failure, whatever was
///   already set up (process, proxy, markers) — a failed connect never
///   leaves a half-configured system;
/// - `stop()` is idempotent and never hangs: every external command has a
///   hard timeout, and process termination escalates SIGTERM -> SIGKILL;
/// - an unexpected core exit restores the system proxy through the same
///   serialized lifecycle queue, so it can never race a new start;
/// - markers on disk allow the next app launch (or the watchdog) to recover
///   from kill -9, crashes and power loss.
class SingboxRuntimeService implements RuntimeEngine {
  /// Two attempts are enough: ports are freshly reserved per attempt, so the
  /// only retry-worthy failure is a transient controller startup timeout.
  /// Config and permission errors kill sing-box instantly and surface
  /// immediately instead of burning ~36 s on pointless retries.
  static const _maxStartupAttempts = 2;

  SingboxRuntimeService({
    SystemProxyService? systemProxyService,
    RuntimeCleanupWatchdog? runtimeCleanupWatchdog,
    PrivilegedHelperClient? privilegedHelperClient,
    Future<RunningProcessLookup> Function(int pid)? runningProcessLookupReader,
  }) : _systemProxyService = systemProxyService ?? const SystemProxyService(),
       _runtimeCleanupWatchdog =
           runtimeCleanupWatchdog ?? const RuntimeCleanupWatchdog(),
       _privilegedHelperClient = privilegedHelperClient,
       _runningProcessLookupReader =
           runningProcessLookupReader ?? _lookupRunningProcess;

  Process? _process;
  RuntimeSession? _session;
  final List<String> _logs = <String>[];
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  final SystemProxyService _systemProxyService;
  final RuntimeCleanupWatchdog _runtimeCleanupWatchdog;
  final PrivilegedHelperClient? _privilegedHelperClient;
  final Future<RunningProcessLookup> Function(int pid)
  _runningProcessLookupReader;
  SystemProxyLease? _systemProxyLease;
  _WinHttpProxyLease? _winHttpProxyLease;
  final _lifecycle = LifecycleQueue();
  Process? _stoppingProcess;

  /// Exit codes of dead children, keyed by process identity. Recorded
  /// synchronously when `exitCode` completes — before the queued exit
  /// handler runs — so the startup abort check can see early exits.
  final _exitCodes = Expando<int>('singboxExitCode');

  @override
  RuntimeSession? get session => _session;
  @override
  List<String> get logs => List.unmodifiable(_logs);
  @override
  bool get launchesWithEmbeddedPrivilegeBroker => false;

  @override
  Future<bool> canLaunchWithEmbeddedPrivilegeBroker({
    required RuntimeMode mode,
  }) async {
    return false;
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
    return _lifecycle.run(
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
    required ConnectionTuningSettings connectionTuningSettings,
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
      try {
        return await _tryStartOnce(
          runtimeDir: runtimeDir,
          binaryFile: binaryFile,
          profileId: profileId,
          templateConfig: templateConfig,
          originalTemplateConfig: originalTemplateConfig,
          connectionTuningSettings: connectionTuningSettings,
          urlTestUrl: urlTestUrl,
          mode: mode,
          selectedServerTag: selectedServerTag,
          onExit: onExit,
        );
      } on Object catch (error, stackTrace) {
        startupError = error;
        startupStackTrace = stackTrace;
        if (attempt >= _maxStartupAttempts ||
            !_isRetryableStartupError(error)) {
          break;
        }
        _pushLog(
          'Retrying sing-box startup with fresh local ports '
          '(attempt ${attempt + 1}/$_maxStartupAttempts) after: $error',
          isError: true,
        );
      }
    }

    Error.throwWithStackTrace(
      startupError ?? StateError('Failed to start sing-box.'),
      startupStackTrace ?? StackTrace.current,
    );
  }

  /// One full startup attempt. Any failure after the process exists runs the
  /// complete `_stopImpl` cleanup, so a broken attempt can never leak a
  /// running sing-box or an active system proxy.
  Future<RuntimeSession> _tryStartOnce({
    required Directory runtimeDir,
    required File binaryFile,
    required String profileId,
    required String templateConfig,
    String? originalTemplateConfig,
    required ConnectionTuningSettings connectionTuningSettings,
    required String urlTestUrl,
    required RuntimeMode mode,
    String? selectedServerTag,
    RuntimeExitCallback? onExit,
  }) async {
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
      await configFile.writeAsString(built.configJson, flush: true);

      final checked = await runProcessWithTimeout(binaryFile.path, [
        'check',
        '-c',
        configFile.path,
      ], workingDirectory: runtimeDir.path);
      if (checked.exitCode != 0) {
        throw FormatException(
          'Invalid sing-box configuration: ${checked.stderr}',
        );
      }

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

      final process = await Process.start(
        binaryFile.path,
        ['run', '-c', configFile.path],
        workingDirectory: runtimeDir.path,
        mode: ProcessStartMode.normal,
      );

      _process = process;
      _pushLog('sing-box process started with PID ${process.pid}.');
      await _writeProcessMarker(
        runtimeDir,
        pid: process.pid,
        binaryPath: binaryFile.path,
        configPath: configFile.path,
      );
      await _runtimeCleanupWatchdog.arm(
        runtimeDir: runtimeDir,
        parentPid: currentProcessPid,
        childPid: process.pid,
        managedProxyPort: mode.usesSystemProxy ? mixedPort : null,
        onLog: _pushLog,
      );

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

      unawaited(
        process.exitCode
            .then((code) {
              _exitCodes[process] = code;
              return _handleProcessExit(
                process,
                code,
                runtimeDir,
                session,
                onExit,
              );
            })
            .catchError((Object error) {
              _pushLog('Exit handler failed: $error', isError: true);
            }),
      );

      final clashClient = ClashApiClient.fromSession(session);
      try {
        await clashClient.waitUntilReady(
          onLog: _pushLog,
          abortReason: () {
            final startupExitCode = _exitCodes[process];
            if (startupExitCode == null) {
              return null;
            }
            return 'sing-box exited before the local controller became ready. '
                'Exit code: $startupExitCode. Check runtime logs for stderr details.';
          },
        );
      } on Object catch (error, stackTrace) {
        _pushLog('The Clash API did not start: $error', isError: true);
        Error.throwWithStackTrace(error, stackTrace);
      }

      if (mode.usesSystemProxy) {
        _systemProxyLease = await _systemProxyService.enable(
          mode: mode,
          runtimeDir: runtimeDir,
          mixedPort: mixedPort,
          bypassSteam: connectionTuningSettings.bypassSteamForSystemProxy,
          onLog: _pushLog,
        );
        await _enableWinHttpProxy(
          runtimeDir: runtimeDir,
          mixedPort: mixedPort,
          bypassSteam: connectionTuningSettings.bypassSteamForSystemProxy,
        );
      }

      if (_exitCodes[process] != null) {
        throw StateError('sing-box exited while enabling the system proxy.');
      }
      _pushLog('Clash API is ready on ${session.controllerBaseUrl}.');
      _session = session;
      return session;
    } on Object {
      // Whatever this attempt managed to set up — process, proxy, markers —
      // goes down with it. A failed connect must leave the system clean.
      await _stopImpl();
      rethrow;
    } finally {
      await controllerReservation?.close();
      await mixedReservation?.close();
    }
  }

  /// Handles an unexpected core exit. Runs inside the serialized lifecycle
  /// queue so the proxy restore can never race a fresh `start()`.
  Future<void> _handleProcessExit(
    Process process,
    int exitCode,
    Directory runtimeDir,
    RuntimeSession session,
    RuntimeExitCallback? onExit,
  ) {
    return _lifecycle.run(() async {
      _pushLog('sing-box exited with code $exitCode.');
      if (identical(_stoppingProcess, process)) {
        return;
      }
      if (!identical(_process, process)) {
        return;
      }

      await _stdoutSubscription?.cancel();
      await _stderrSubscription?.cancel();
      _stdoutSubscription = null;
      _stderrSubscription = null;

      final lease = _systemProxyLease;
      final winHttpLease = _winHttpProxyLease;
      _systemProxyLease = null;
      _winHttpProxyLease = null;
      if (lease != null || session.mode.usesSystemProxy) {
        try {
          await _systemProxyService.restore(
            runtimeDir: runtimeDir,
            lease: lease,
            onLog: _pushLog,
          );
        } on Object catch (error) {
          _pushLog('Failed to restore the system proxy: $error', isError: true);
        }
      }
      if (winHttpLease != null) {
        try {
          await _restoreWinHttpProxy(
            runtimeDir: runtimeDir,
            lease: winHttpLease,
          );
        } on Object catch (error) {
          _pushLog(
            'Failed to restore the WinHTTP proxy: $error',
            isError: true,
          );
        }
      }

      if (!await File(
        p.join(runtimeDir.path, systemProxyMarkerFileName),
      ).exists()) {
        await _deleteProcessMarker(runtimeDir, expectedPid: process.pid);
      }
      final activeSession = _session;
      _process = null;
      _session = null;
      if (activeSession != null) {
        onExit?.call(activeSession, exitCode);
      }
    });
  }

  @override
  Future<void> stop() {
    return _lifecycle.run(_stopImpl);
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
    Object? cleanupError;
    if (process == null) {
      final owner = await _readProcessMarker(runtimeDir);
      if (owner?.launcherPid != null &&
          owner!.launcherPid != currentProcessPid &&
          await _isProcessAlive(owner.launcherPid!)) {
        return;
      }
    }

    // Restore the proxy before killing the core: while the restore runs the
    // old core can still serve the loopback endpoint, so the system never
    // points at a dead port.
    if (systemProxyLease != null ||
        session?.mode.usesSystemProxy == true ||
        await File(
          p.join(runtimeDir.path, systemProxyMarkerFileName),
        ).exists()) {
      try {
        await _systemProxyService.restore(
          runtimeDir: runtimeDir,
          lease: systemProxyLease,
          onLog: _pushLog,
        );
      } on Object catch (error) {
        cleanupError ??= error;
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
        cleanupError ??= error;
        _pushLog('Failed to restore the WinHTTP proxy: $error', isError: true);
      }
    }

    if (process == null) {
      if (cleanupError != null) throw cleanupError;
      return;
    }

    _pushLog('Stopping sing-box PID ${process.pid}.');
    _stoppingProcess = process;
    try {
      // SIGTERM first: sing-box shuts down gracefully, closing the TUN
      // interface and cleaning up its routes itself.
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 4));
      } on TimeoutException {
        _pushLog(
          'sing-box did not exit gracefully, forcing termination.',
          isError: true,
        );
        process.kill(ProcessSignal.sigkill);
        try {
          await process.exitCode.timeout(const Duration(seconds: 2));
        } on TimeoutException {
          // Keep the marker: the process may still die, and the orphan
          // cleanup on the next start needs to find it.
          _pushLog(
            'sing-box PID ${process.pid} did not exit after SIGKILL; keeping the runtime marker for the next cleanup pass.',
            isError: true,
          );
          return;
        }
      }

      if (!await File(
        p.join(runtimeDir.path, systemProxyMarkerFileName),
      ).exists()) {
        await _deleteProcessMarker(runtimeDir, expectedPid: process.pid);
      }
    } finally {
      if (identical(_stoppingProcess, process)) {
        _stoppingProcess = null;
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
    }
    if (cleanupError != null) throw cleanupError;
  }

  /// App-exit shutdown, bounded in time so a hung component can never block
  /// the OS from quitting the app. No-ops cheaply when nothing is running —
  /// important because `Future.timeout` would otherwise leave a pending
  /// timer behind on every dispose.
  @override
  Future<void> stopForAppExit() async {
    if (_session == null &&
        _process == null &&
        _systemProxyLease == null &&
        _winHttpProxyLease == null) {
      return;
    }
    try {
      await stop().timeout(const Duration(seconds: 30));
    } on TimeoutException {
      _pushLog(
        'Runtime shutdown exceeded the app-exit budget; the watchdog and the next launch will finish the cleanup.',
        isError: true,
      );
    } on Object catch (error) {
      _pushLog('Shutdown recovery remains pending: $error', isError: true);
    }
  }

  @override
  void dispose() {
    unawaited(stopForAppExit());
  }

  /// Best-effort recovery of state left behind by a previous app session.
  /// Runs at app start (not only on connect), so a crash or a reboot never
  /// leaves the machine without internet. Never throws. Serialized through
  /// the lifecycle queue so it can never race a connect.
  @override
  Future<void> recoverFromPreviousSession({ProxyLogSink? onLog}) {
    return _lifecycle.run(() => _recoverFromPreviousSessionImpl(onLog));
  }

  Future<void> _recoverFromPreviousSessionImpl(ProxyLogSink? onLog) async {
    void log(String line, {bool isError = false}) {
      _pushLog(line, isError: isError);
      onLog?.call(line, isError: isError);
    }

    try {
      final runtimeDir = await _runtimeDirectory();
      final orphan = await _readProcessMarker(runtimeDir);

      // A live launcher means another app instance owns the runtime — do not
      // touch its process or its proxy state.
      final launcherAlive =
          orphan?.launcherPid != null &&
          await _isProcessAlive(orphan!.launcherPid!);
      if (orphan == null || !launcherAlive) {
        await _systemProxyService.cleanupOrphanedState(
          runtimeDir: runtimeDir,
          onLog: log,
        );
        await _cleanupOrphanedWinHttpProxyState(runtimeDir);
        if (orphan != null) {
          await _cleanupOrphanedProcess(runtimeDir, onLog: log);
        }
      }
    } on Object catch (error) {
      log('Startup recovery failed: $error', isError: true);
    }
  }

  Future<bool> _isProcessAlive(int pid) async {
    if (pid <= 0) {
      return false;
    }
    final lookup = await _runningProcessLookupReader(pid);
    return lookup.isFound;
  }

  Future<File> _prepareBinary(Directory runtimeDir) {
    return prepareSingboxBinary(runtimeDir);
  }

  Future<Directory> _runtimeDirectory() {
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

  Future<void> _cleanupOrphanedProcess(
    Directory runtimeDir, {
    ProxyLogSink? onLog,
  }) async {
    void log(String line, {bool isError = false}) {
      _pushLog(line, isError: isError);
      onLog?.call(line, isError: isError);
    }

    final marker = await _readProcessMarker(runtimeDir);
    if (marker == null) {
      return;
    }

    if (marker.launcherPid != null &&
        marker.launcherPid != currentProcessPid &&
        await _isProcessAlive(marker.launcherPid!)) {
      log('Another Gorion instance owns this runtime; leaving it untouched.');
      return;
    }
    final matchStatus = await _inspectOrphanedProcessMarker(marker);
    switch (matchStatus) {
      case _OrphanedProcessMatch.matches:
        break;
      case _OrphanedProcessMatch.mismatches:
        log(
          'Skipping orphaned sing-box cleanup for PID ${marker.pid} because the running process no longer matches the saved runtime marker.',
        );
        await _deleteProcessMarker(runtimeDir, expectedPid: marker.pid);
        return;
      case _OrphanedProcessMatch.missingProcess:
        log('Removing stale sing-box PID marker for ${marker.pid}.');
        await _deleteProcessMarker(runtimeDir, expectedPid: marker.pid);
        return;
      case _OrphanedProcessMatch.inconclusive:
        log(
          'Could not verify orphaned sing-box PID ${marker.pid} safely; keeping the runtime marker for a later cleanup attempt.',
          isError: true,
        );
        return;
    }

    final killed = Process.killPid(marker.pid);
    if (killed) {
      // A successful signal is not proof that the core has exited.
      for (var attempt = 0; attempt < 40; attempt++) {
        if ((await _runningProcessLookupReader(marker.pid)).isMissing) {
          await _deleteProcessMarker(runtimeDir, expectedPid: marker.pid);
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      log(
        'Orphaned core did not stop after SIGTERM; keeping its marker.',
        isError: true,
      );
      return;
    }
    // killPid can report false for both "no such process" and "permission
    // denied". Re-check liveness before deciding the fate of the marker.
    final lookupAfterKill = await _runningProcessLookupReader(marker.pid);
    if (lookupAfterKill.isMissing) {
      log('Removing stale sing-box PID marker for ${marker.pid}.');
      await _deleteProcessMarker(runtimeDir, expectedPid: marker.pid);
      return;
    }

    log(
      'Failed to stop orphaned sing-box PID ${marker.pid}; keeping the runtime marker so the next attempt can retry.',
      isError: true,
    );
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
    final payload = <String, Object?>{
      'pid': pid,
      'binaryPath': binaryPath,
      'configPath': configPath,
      'launcherPid': currentProcessPid,
    };
    final pending = File('${markerFile.path}.tmp');
    await pending.writeAsString(jsonEncode(payload), flush: true);
    await pending.rename(markerFile.path);
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
        launcherPid: _tryParseInt(decoded['launcherPid']),
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
    } on Object catch (error) {
      _pushLog('Failed to restore the WinHTTP proxy: $error', isError: true);
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

  /// Only a controller-startup timeout is worth a retry with fresh ports.
  /// Everything else (bad config, missing TUN permissions, spawn failure)
  /// fails fast instead of multiplying the wait.
  bool _isRetryableStartupError(Object error) {
    return error is TimeoutException;
  }

  Future<_OrphanedProcessMatch> _inspectOrphanedProcessMarker(
    _RuntimeProcessMarker marker,
  ) async {
    final binaryPath = marker.binaryPath?.trim();
    final lookup = await _runningProcessLookupReader(marker.pid);
    if (lookup.isMissing) {
      return _OrphanedProcessMatch.missingProcess;
    }
    if (!lookup.isFound) {
      return _OrphanedProcessMatch.inconclusive;
    }

    if (binaryPath == null || binaryPath.isEmpty) {
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
      final result = await runProcessWithTimeout('powershell.exe', [
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

    final result = await runProcessWithTimeout('ps', [
      '-p',
      '$pid',
      '-o',
      'args=',
    ]);
    if (result.exitCode != 0) {
      // POSIX ps exits non-zero when the PID does not exist.
      return const RunningProcessLookup.missing();
    }

    final commandLine = result.stdout.toString().trim();
    if (commandLine.isEmpty) {
      return const RunningProcessLookup.missing();
    }
    return RunningProcessLookup.found(commandLine: commandLine);
  }

  /// Paths are compared case-insensitively: the process command line is
  /// lowercased by [RunningProcessLookup.normalizedCommandLine], and both
  /// Windows and the default macOS filesystem are case-insensitive anyway.
  String _normalizeComparablePath(String value) {
    return p.normalize(value).replaceAll('\\', '/').toLowerCase();
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
    this.launcherPid,
  });

  final int pid;
  final String? binaryPath;
  final String? configPath;
  final int? launcherPid;
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
