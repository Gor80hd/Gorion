import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gorion_clean/core/logging/gorion_console_log.dart';
import 'package:gorion_clean/features/zapret/data/zapret_config_generator.dart';
import 'package:gorion_clean/features/zapret/data/zapret_runtime_support.dart';
import 'package:gorion_clean/features/zapret/model/zapret_models.dart';
import 'package:gorion_clean/features/zapret/model/zapret_settings.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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

  Future<ZapretSettings> hydrateSettings(ZapretSettings settings) async {
    if (settings.hasInstallDirectory) {
      return settings;
    }
    if (!Platform.isWindows) {
      return settings;
    }

    final bundleDir = await prepareZapretBundle();
    return settings.copyWith(installDirectory: bundleDir.path);
  }

  Future<ZapretRuntimeSession> start({
    required ZapretSettings settings,
    required void Function(int exitCode) onExit,
    bool preserveLogs = false,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError(
        'Отдельный zapret2 на текущем этапе поддерживается только на Windows.',
      );
    }

    await stop();
    if (!preserveLogs) {
      _logs.clear();
    } else if (_logs.isNotEmpty) {
      _appendLog('--- новая попытка запуска zapret2 ---');
    }

    final effectiveSettings = await hydrateSettings(settings);
    final configuration = _generator.build(effectiveSettings);
    final executablePath = _generator.resolveExecutablePath(
      effectiveSettings.normalizedInstallDirectory,
    );
    if (executablePath == null) {
      throw FileSystemException(
        'Не удалось найти winws2.exe в выбранном каталоге установки zapret2.',
        effectiveSettings.normalizedInstallDirectory,
      );
    }

    for (final requiredFile in configuration.requiredFiles) {
      if (!File(requiredFile).existsSync()) {
        throw FileSystemException(
          'Не найден обязательный файл из комплекта zapret2.',
          requiredFile,
        );
      }
    }

    _appendLog(
      'Подготовка пресета zapret2: ${effectiveSettings.preset.label}.',
    );
    await _validateConfiguration(
      executablePath: executablePath,
      configuration: configuration,
    );
    _appendLog('Проверка конфигурации пройдена.');
    final launchConfigPath = await _writeConfigFile(
      configuration: configuration,
      dryRun: false,
    );
    final launchArguments = ['@$launchConfigPath'];
    _appendCommandTrace(
      label: 'RUN',
      executablePath: executablePath,
      workingDirectory: configuration.workingDirectory,
      arguments: launchArguments,
    );
    _appendConfigTrace(
      label: 'RUN CFG',
      configPath: launchConfigPath,
      configLines: configuration.arguments,
    );
    _appendLog('Запуск zapret2 из $executablePath.');

    Process process;
    try {
      process = await Process.start(
        executablePath,
        launchArguments,
        workingDirectory: configuration.workingDirectory,
        mode: ProcessStartMode.normal,
      );
    } on ProcessException catch (error) {
      _appendLog('Не удалось запустить winws2: $error', isError: true);
      rethrow;
    }

    _process = process;
    _session = ZapretRuntimeSession(
      executablePath: executablePath,
      workingDirectory: configuration.workingDirectory,
      processId: process.pid,
      startedAt: DateTime.now(),
      arguments: List<String>.unmodifiable(launchArguments),
      commandPreview: configuration.preview,
    );
    _appendLog('Процесс zapret2 запущен с PID ${process.pid}.');

    _stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _appendLog('STDOUT $line'));
    _stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _appendLog('STDERR $line', isError: true));

    process.exitCode.then((code) {
      _appendLog('zapret2 завершился с кодом $code.', isError: code != 0);
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

    _appendLog('Остановка zapret2 PID ${process.pid}.');
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

  Future<void> _validateConfiguration({
    required String executablePath,
    required ZapretLaunchConfiguration configuration,
  }) async {
    final configPath = await _writeConfigFile(
      configuration: configuration,
      dryRun: true,
    );
    final arguments = ['@$configPath'];
    _appendCommandTrace(
      label: 'DRY-RUN',
      executablePath: executablePath,
      workingDirectory: configuration.workingDirectory,
      arguments: arguments,
    );
    _appendConfigTrace(
      label: 'DRY-RUN CFG',
      configPath: configPath,
      configLines: ['--dry-run', ...configuration.arguments],
    );

    ProcessResult result;
    try {
      result = await Process.run(
        executablePath,
        arguments,
        workingDirectory: configuration.workingDirectory,
      );
    } on ProcessException catch (error) {
      _appendLog('Не удалось выполнить dry-run winws2: $error', isError: true);
      rethrow;
    }

    _appendProcessOutputBlock('DRY-RUN STDOUT', result.stdout?.toString());
    _appendProcessOutputBlock(
      'DRY-RUN STDERR',
      result.stderr?.toString(),
      isError: true,
    );

    if (result.exitCode == 0) {
      return;
    }

    _appendLog('DRY-RUN завершился с кодом ${result.exitCode}.', isError: true);

    final stderr = result.stderr?.toString().trim();
    final stdout = result.stdout?.toString().trim();
    final details = [
      if (stderr != null && stderr.isNotEmpty) stderr,
      if (stdout != null && stdout.isNotEmpty) stdout,
    ].join('\n');
    if (details.isEmpty) {
      _appendLog(
        'DRY-RUN не вернул stdout/stderr. Для диагностики смотрите аргументы выше в секции ZAPRET.',
        isError: true,
      );
    }

    throw ProcessException(
      executablePath,
      arguments,
      details.isEmpty
          ? 'Проверка конфигурации завершилась с ошибкой.'
          : details,
      result.exitCode,
    );
  }

  Future<String> _writeConfigFile({
    required ZapretLaunchConfiguration configuration,
    required bool dryRun,
  }) async {
    final directory = await _ensureGeneratedConfigDirectory();
    final file = File(
      p.join(
        directory.path,
        'gorion-zapret-${dryRun ? 'dry-run' : 'run'}-${DateTime.now().microsecondsSinceEpoch}.conf',
      ),
    );
    final lines = [if (dryRun) '--dry-run', ...configuration.arguments];
    final content = lines.map(_escapeConfigLine).join('\n');
    await file.writeAsString(content, flush: true);
    return file.path;
  }

  Future<Directory> _ensureGeneratedConfigDirectory() async {
    final appSupportDir = await getApplicationSupportDirectory();
    final directory = Directory(
      p.join(appSupportDir.path, 'gorion', 'runtime', 'zapret2', 'generated'),
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  String _escapeConfigLine(String value) {
    if (!value.contains(' ') && !value.contains('\t')) {
      return value;
    }

    final escaped = value.replaceAll('"', r'\"');
    return '"$escaped"';
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

  void _appendConfigTrace({
    required String label,
    required String configPath,
    required List<String> configLines,
  }) {
    _appendLog('$label file: $configPath');
    for (var index = 0; index < configLines.length; index += 1) {
      _appendLog('$label line ${index + 1}: ${configLines[index]}');
    }
  }

  void _appendProcessOutputBlock(
    String label,
    String? output, {
    bool isError = false,
  }) {
    final text = output?.trim();
    if (text == null || text.isEmpty) {
      return;
    }

    final lines = const LineSplitter().convert(text);
    for (final line in lines) {
      _appendLog('$label $line', isError: isError);
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
