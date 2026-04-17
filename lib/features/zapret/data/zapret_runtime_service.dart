import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gorion_clean/core/windows/privileged_helper_client.dart';
import 'package:gorion_clean/core/windows/privileged_helper_protocol.dart';
import 'package:gorion_clean/core/logging/gorion_console_log.dart';
import 'package:gorion_clean/features/runtime/data/singbox_runtime_support.dart';
import 'package:gorion_clean/features/runtime/data/windows_runtime_cleanup_watchdog.dart';
import 'package:gorion_clean/features/zapret/data/zapret_config_generator.dart';
import 'package:gorion_clean/features/zapret/data/zapret_runtime_support.dart';
import 'package:gorion_clean/features/zapret/model/zapret_models.dart';
import 'package:gorion_clean/features/zapret/model/zapret_settings.dart';
import 'package:path/path.dart' as p;

const _runtimeProcessMarkerFileName = 'runtime-process.json';

ZapretRuntimeService buildZapretRuntimeService() {
  if (Platform.isWindows && WindowsPrivilegedHelperClient.isProvisionedSync()) {
    return _PrivilegedHelperZapretRuntimeService(
      helperClient: WindowsPrivilegedHelperClient(),
    );
  }

  return ZapretRuntimeService();
}

class ZapretRuntimeService {
  ZapretRuntimeService({
    ZapretConfigGenerator? generator,
    WindowsRuntimeCleanupWatchdog? windowsRuntimeCleanupWatchdog,
  }) : _generator = generator ?? const ZapretConfigGenerator(),
       _windowsRuntimeCleanupWatchdog =
           windowsRuntimeCleanupWatchdog ??
           const WindowsRuntimeCleanupWatchdog();

  final ZapretConfigGenerator _generator;
  final WindowsRuntimeCleanupWatchdog _windowsRuntimeCleanupWatchdog;
  Process? _process;
  ZapretRuntimeSession? _session;
  final List<String> _logs = <String>[];
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;

  ZapretRuntimeSession? get session => _session;

  List<String> get logs => List.unmodifiable(_logs);
  bool get launchesWithEmbeddedPrivilegeBroker => false;

  void recordDiagnostic(String line, {bool isError = false}) {
    _appendLog(line, isError: isError);
  }

  ZapretLaunchConfiguration buildPreview(ZapretSettings settings) {
    return _generator.build(settings);
  }

  List<ZapretConfigOption> listAvailableProfiles(String installDirectory) {
    return _generator.listAvailableProfiles(installDirectory);
  }

  String resolveSelectedConfigFileName(
    String installDirectory,
    String preferredFileName,
  ) {
    return _generator.resolveSelectedConfigFileName(
      installDirectory,
      preferredFileName,
    );
  }

  Future<ZapretSettings> hydrateSettings(ZapretSettings settings) async {
    if (!Platform.isWindows) {
      return settings;
    }

    if (settings.hasInstallDirectory) {
      await ensureBundledSupportLayout(settings.normalizedInstallDirectory);
      await ensureBundledProfileConfigs(settings.normalizedInstallDirectory);
      return settings;
    }

    final bundleDir = await prepareZapretBundle();
    await ensureBundledSupportLayout(bundleDir.path);
    await ensureBundledProfileConfigs(bundleDir.path);
    if (_generator.listAvailableProfiles(bundleDir.path).isEmpty) {
      return settings;
    }
    return settings.copyWith(installDirectory: bundleDir.path);
  }

  Future<ZapretRuntimeSession> start({
    required ZapretSettings settings,
    required void Function(int exitCode) onExit,
    bool preserveLogs = false,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError(
        'Gorion Boost на текущем этапе поддерживается только на Windows.',
      );
    }

    final runtimeDir = await _runtimeDirectory();
    await stop();
    await _cleanupOrphanedProcess(runtimeDir);
    if (!preserveLogs) {
      _logs.clear();
    } else if (_logs.isNotEmpty) {
      _appendLog('--- новая попытка запуска zapret ---');
    }

    final effectiveSettings = await hydrateSettings(settings);
    final configuration = _generator.build(effectiveSettings);
    for (final requiredFile in configuration.requiredFiles) {
      if (!File(requiredFile).existsSync()) {
        throw FileSystemException(
          'Не найден обязательный файл из выбранного комплекта Gorion Boost.',
          requiredFile,
        );
      }
    }

    _appendLog(
      'Подготовка конфига zapret: ${effectiveSettings.effectiveConfigFileName}.',
    );
    _appendCommandTrace(
      label: 'RUN',
      executablePath: configuration.executablePath,
      workingDirectory: configuration.workingDirectory,
      arguments: configuration.arguments,
    );
    _appendLog('Запуск zapret из ${configuration.executablePath}.');

    Process process;
    try {
      process = await Process.start(
        configuration.executablePath,
        configuration.arguments,
        workingDirectory: configuration.workingDirectory,
        mode: ProcessStartMode.normal,
      );
    } on ProcessException catch (error) {
      _appendLog('Не удалось запустить winws: $error', isError: true);
      rethrow;
    }

    _process = process;
    _session = ZapretRuntimeSession(
      executablePath: configuration.executablePath,
      workingDirectory: configuration.workingDirectory,
      processId: process.pid,
      startedAt: DateTime.now(),
      arguments: List<String>.unmodifiable(configuration.arguments),
      commandPreview: configuration.preview,
    );
    await _writeProcessMarker(
      runtimeDir,
      pid: process.pid,
      executablePath: configuration.executablePath,
      workingDirectory: configuration.workingDirectory,
      arguments: configuration.arguments,
    );
    await _windowsRuntimeCleanupWatchdog.arm(
      runtimeDir: runtimeDir,
      parentPid: pid,
      childPid: process.pid,
      onLog: _appendLog,
    );
    _appendLog('Процесс zapret запущен с PID ${process.pid}.');

    _stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _appendLog('STDOUT $line'));
    _stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _appendLog('STDERR $line', isError: true));

    process.exitCode.then((code) {
      unawaited(_deleteProcessMarker(runtimeDir, expectedPid: process.pid));
      _appendLog('zapret завершился с кодом $code.', isError: code != 0);
      _process = null;
      _session = null;
      onExit(code);
    });

    return _session!;
  }

  Future<void> stop() async {
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription = null;

    final runtimeDir = await _runtimeDirectory();
    final process = _process;
    _process = null;
    _session = null;

    if (process == null) {
      return;
    }

    _appendLog('Остановка zapret PID ${process.pid}.');
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 4));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(const Duration(seconds: 2));
    }

    await _deleteProcessMarker(runtimeDir, expectedPid: process.pid);
  }

  void dispose() {
    unawaited(stop());
  }

  Future<Directory> _runtimeDirectory() async {
    return ensureGorionRuntimeDirectory(subdirectory: 'zapret2');
  }

  Future<void> _cleanupOrphanedProcess(Directory runtimeDir) async {
    final marker = await _readProcessMarker(runtimeDir);
    if (marker == null) {
      return;
    }

    final killed = Process.killPid(marker.pid);
    if (killed) {
      _appendLog(
        'Остановлен осиротевший процесс zapret PID ${marker.pid} из предыдущего сеанса приложения.',
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    } else {
      _appendLog(
        'Удаляется устаревший marker процесса zapret PID ${marker.pid}.',
      );
    }

    await _deleteProcessMarker(runtimeDir, expectedPid: marker.pid);
  }

  Future<void> _writeProcessMarker(
    Directory runtimeDir, {
    required int pid,
    required String executablePath,
    required String workingDirectory,
    required List<String> arguments,
  }) async {
    final markerFile = _processMarkerFile(runtimeDir);
    final payload = <String, Object>{
      'pid': pid,
      'executablePath': executablePath,
      'workingDirectory': workingDirectory,
      'arguments': arguments,
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

  void _appendCommandTrace({
    required String label,
    required String executablePath,
    required String workingDirectory,
    required List<String> arguments,
  }) {
    _appendLog('$label cwd: $workingDirectory');
    _appendLog('$label exe: $executablePath');
    for (var index = 0; index < arguments.length; index += 1) {
      _appendLog('$label arg ${index + 1}: ${arguments[index]}');
    }
  }

  void _appendLog(String line, {bool isError = false}) {
    final prefix = isError ? '[ошибка]' : '[инфо]';
    _logs.add('$prefix $line');
    GorionConsoleLog.zapret(line, isError: isError);
    if (_logs.length > 200) {
      _logs.removeRange(0, _logs.length - 200);
    }
  }
}

class _RuntimeProcessMarker {
  const _RuntimeProcessMarker({required this.pid});

  final int pid;
}

class _PrivilegedHelperZapretRuntimeService extends ZapretRuntimeService {
  _PrivilegedHelperZapretRuntimeService({
    required WindowsPrivilegedHelperClient helperClient,
  }) : _helperClient = helperClient;

  final WindowsPrivilegedHelperClient _helperClient;
  ZapretRuntimeSession? _remoteSession;
  final List<String> _remoteLogs = <String>[];
  Timer? _statePollTimer;
  void Function(int exitCode)? _onExit;
  bool _pollInFlight = false;

  @override
  ZapretRuntimeSession? get session => _remoteSession;

  @override
  List<String> get logs => List.unmodifiable(_remoteLogs);

  @override
  bool get launchesWithEmbeddedPrivilegeBroker => true;

  @override
  void recordDiagnostic(String line, {bool isError = false}) {
    final prefix = isError ? '[ошибка]' : '[инфо]';
    _remoteLogs.add('$prefix $line');
    if (_remoteLogs.length > 200) {
      _remoteLogs.removeRange(0, _remoteLogs.length - 200);
    }
    unawaited(
      _helperClient
          .recordZapretDiagnostic(line: line, isError: isError)
          .then((snapshot) => _replaceState(snapshot))
          .catchError((_) => null),
    );
  }

  @override
  Future<ZapretRuntimeSession> start({
    required ZapretSettings settings,
    required void Function(int exitCode) onExit,
    bool preserveLogs = false,
  }) async {
    final snapshot = await _helperClient.startZapret(
      settings: settings,
      preserveLogs: preserveLogs,
    );
    _replaceState(snapshot);
    _onExit = onExit;
    _startPolling();
    final session = _remoteSession;
    if (session == null) {
      throw StateError(
        'Privileged helper did not return a running zapret session.',
      );
    }
    return session;
  }

  @override
  Future<void> stop() async {
    _statePollTimer?.cancel();
    _statePollTimer = null;
    _onExit = null;
    final snapshot = await _helperClient.stopZapret();
    _replaceState(snapshot);
  }

  @override
  void dispose() {
    unawaited(stop());
  }

  void _startPolling() {
    _statePollTimer?.cancel();
    _statePollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_pollState());
    });
  }

  Future<void> _pollState() async {
    if (_pollInFlight) {
      return;
    }
    _pollInFlight = true;
    final previousSession = _remoteSession;
    try {
      final snapshot = await _helperClient.fetchZapretState();
      _replaceState(snapshot);
      if (previousSession != null && snapshot.session == null) {
        _statePollTimer?.cancel();
        _statePollTimer = null;
        final callback = _onExit;
        _onExit = null;
        if (callback != null) {
          callback(snapshot.lastExitCode ?? 0);
        }
      }
    } on Object {
      // Keep the last known state; the GUI can retry on the next poll.
    } finally {
      _pollInFlight = false;
    }
  }

  void _replaceState(PrivilegedHelperZapretSnapshot snapshot) {
    _remoteSession = snapshot.session;
    _remoteLogs
      ..clear()
      ..addAll(snapshot.logs);
  }
}
