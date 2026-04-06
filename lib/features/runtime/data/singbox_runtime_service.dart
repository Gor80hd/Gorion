import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gorion_clean/core/constants/singbox_assets.dart';
import 'package:gorion_clean/core/logging/gorion_console_log.dart';
import 'package:gorion_clean/features/runtime/data/clash_api_client.dart';
import 'package:gorion_clean/features/runtime/data/singbox_config_builder.dart';
import 'package:gorion_clean/features/runtime/data/singbox_runtime_support.dart';
import 'package:gorion_clean/features/runtime/data/system_proxy_service.dart';
import 'package:gorion_clean/features/runtime/data/windows_runtime_cleanup_watchdog.dart';
import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';
import 'package:gorion_clean/features/settings/data/connection_tuning_config_overrides.dart';
import 'package:gorion_clean/features/settings/model/connection_tuning_settings.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

const _runtimeProcessMarkerFileName = 'runtime-process.json';

class SingboxRuntimeService {
  SingboxRuntimeService({
    SystemProxyService? systemProxyService,
    WindowsRuntimeCleanupWatchdog? windowsRuntimeCleanupWatchdog,
  }) : _systemProxyService = systemProxyService ?? const SystemProxyService(),
       _windowsRuntimeCleanupWatchdog =
           windowsRuntimeCleanupWatchdog ??
           const WindowsRuntimeCleanupWatchdog();

  Process? _process;
  RuntimeSession? _session;
  final List<String> _logs = <String>[];
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  final SystemProxyService _systemProxyService;
  final WindowsRuntimeCleanupWatchdog _windowsRuntimeCleanupWatchdog;
  SystemProxyLease? _systemProxyLease;

  RuntimeSession? get session => _session;
  List<String> get logs => List.unmodifiable(_logs);

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
        _systemProxyLease = null;
        if (lease != null) {
          unawaited(
            _systemProxyService.restore(
              runtimeDir: runtimeDir,
              lease: lease,
              onLog: _pushLog,
            ),
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
    _process = null;
    _session = null;
    _systemProxyLease = null;

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

  File _processMarkerFile(Directory runtimeDir) {
    return File(p.join(runtimeDir.path, _runtimeProcessMarkerFileName));
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
