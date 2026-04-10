import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gorion_clean/core/logging/gorion_console_log.dart';
import 'package:gorion_clean/features/zapret/data/zapret_config_generator.dart';
import 'package:gorion_clean/features/zapret/data/zapret_runtime_support.dart';
import 'package:gorion_clean/features/zapret/model/zapret_models.dart';
import 'package:gorion_clean/features/zapret/model/zapret_settings.dart';

class ZapretRuntimeService {
  ZapretRuntimeService({ZapretConfigGenerator? generator})
    : _generator = generator ?? const ZapretConfigGenerator();

  final ZapretConfigGenerator _generator;
  Process? _process;
  ZapretRuntimeSession? _session;
  final List<String> _logs = <String>[];
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;

  ZapretRuntimeSession? get session => _session;

  List<String> get logs => List.unmodifiable(_logs);

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
        'Отдельный zapret на текущем этапе поддерживается только на Windows.',
      );
    }

    await stop();
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
          'Не найден обязательный файл из выбранного комплекта zapret.',
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
  }

  void dispose() {
    unawaited(stop());
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
