import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:launch_at_startup/launch_at_startup.dart';

typedef LaunchAtStartupProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

abstract interface class LaunchAtStartupService {
  Future<bool> isEnabled();

  Future<bool> setEnabled(bool enabled);
}

class DesktopLaunchAtStartupService implements LaunchAtStartupService {
  DesktopLaunchAtStartupService({
    required String appName,
    required String appPath,
    List<String> args = const [],
    LaunchAtStartupProcessRunner? processRunner,
    LaunchAtStartupService? startupEntryService,
  }) : _taskName = _buildTaskName(appName),
       _processRunner =
           processRunner ??
           ((executable, arguments) => Process.run(executable, arguments)),
       _startupEntryService =
           startupEntryService ?? const NoopLaunchAtStartupService();

  factory DesktopLaunchAtStartupService.configure({
    required String appName,
    required String appPath,
    String? packageName,
    List<String> args = const [],
  }) {
    return DesktopLaunchAtStartupService(
      appName: appName,
      appPath: appPath,
      args: args,
      startupEntryService: RunEntryLaunchAtStartupService.configure(
        appName: appName,
        appPath: appPath,
        packageName: packageName,
        args: args,
      ),
    );
  }

  final String _taskName;
  final LaunchAtStartupProcessRunner _processRunner;
  final LaunchAtStartupService _startupEntryService;

  @override
  Future<bool> isEnabled() async {
    final startupEntryEnabled = await _startupEntryService.isEnabled();
    if (startupEntryEnabled) {
      await _deleteScheduledTaskSilently();
      return true;
    }

    final scheduledTaskEnabled = await _isScheduledTaskEnabled();
    if (!scheduledTaskEnabled) {
      return false;
    }

    final migrated = await _enableStartupEntrySilently();
    if (migrated) {
      await _deleteScheduledTaskSilently();
    }
    return true;
  }

  @override
  Future<bool> setEnabled(bool enabled) async {
    if (enabled) {
      final startupEntryEnabled = await _startupEntryService.setEnabled(true);
      if (!startupEntryEnabled) {
        return false;
      }
      await _deleteScheduledTaskSilently();
      return true;
    }

    final startupEntryDisabled = await _startupEntryService.setEnabled(false);
    final scheduledTaskDisabled = await _deleteScheduledTaskSilently();
    return startupEntryDisabled && scheduledTaskDisabled;
  }

  Future<bool> _isScheduledTaskEnabled() async {
    final result = await _runPowerShell(_buildTaskExistsScript());
    if (result.exitCode == 0) {
      return true;
    }
    if (result.exitCode == 1) {
      return false;
    }
    _throwPowerShellException(
      result,
      'Не удалось проверить elevated-автозапуск Windows.',
    );
  }

  Future<bool> _deleteScheduledTask() async {
    final result = await _runPowerShell(_buildDeleteTaskScript());
    if (result.exitCode == 0) {
      return true;
    }
    _throwPowerShellException(
      result,
      'Не удалось отключить elevated-автозапуск Windows.',
    );
  }

  Future<bool> _enableStartupEntrySilently() async {
    try {
      return await _startupEntryService.setEnabled(true);
    } on Object {
      return false;
    }
  }

  Future<bool> _deleteScheduledTaskSilently() async {
    try {
      return await _deleteScheduledTask();
    } on Object {
      return false;
    }
  }

  Future<ProcessResult> _runPowerShell(String script) {
    return _processRunner('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ]);
  }

  String _buildTaskExistsScript() {
    return '''
try {
  \$task = Get-ScheduledTask -TaskName ${_toPowerShellLiteral(_taskName)} -ErrorAction SilentlyContinue
  if (\$null -eq \$task) {
    exit 1
  }
  exit 0
} catch {
  \$message = \$_.Exception.Message
  if (\$message) {
    [Console]::Error.WriteLine(\$message)
  }
  exit 2
}
''';
  }

  String _buildDeleteTaskScript() {
    return '''
try {
  \$task = Get-ScheduledTask -TaskName ${_toPowerShellLiteral(_taskName)} -ErrorAction SilentlyContinue
  if (\$null -eq \$task) {
    exit 0
  }
  Unregister-ScheduledTask -TaskName ${_toPowerShellLiteral(_taskName)} -Confirm:\$false -ErrorAction Stop
  exit 0
} catch {
  \$message = \$_.Exception.Message
  if (\$message) {
    [Console]::Error.WriteLine(\$message)
  }
  exit 1
}
''';
  }

  Never _throwPowerShellException(
    ProcessResult result,
    String fallbackMessage,
  ) {
    throw ProcessException(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        '<script>',
      ],
      _combineProcessOutput(result, fallbackMessage),
      result.exitCode,
    );
  }

  String _combineProcessOutput(ProcessResult result, String fallbackMessage) {
    final lines = <String>[];
    final stderr = result.stderr?.toString().trim();
    final stdout = result.stdout?.toString().trim();
    if (stderr != null && stderr.isNotEmpty) {
      lines.add(stderr);
    }
    if (stdout != null && stdout.isNotEmpty) {
      lines.add(stdout);
    }
    if (lines.isEmpty) {
      return fallbackMessage;
    }
    return lines.join('\n');
  }

  static String _buildTaskName(String appName) {
    final trimmed = appName.trim();
    final normalized = trimmed.isEmpty ? 'gorion' : trimmed;
    return '$normalized Elevated Startup';
  }

  static String _toPowerShellLiteral(String value) {
    return "'${value.replaceAll("'", "''")}'";
  }
}

class RunEntryLaunchAtStartupService implements LaunchAtStartupService {
  RunEntryLaunchAtStartupService._(this._launchAtStartup);

  factory RunEntryLaunchAtStartupService.configure({
    required String appName,
    required String appPath,
    String? packageName,
    List<String> args = const [],
  }) {
    launchAtStartup.setup(
      appName: appName,
      appPath: _quoteExecutablePath(appPath),
      packageName: packageName,
      args: args,
    );
    return RunEntryLaunchAtStartupService._(launchAtStartup);
  }

  final LaunchAtStartup _launchAtStartup;

  @override
  Future<bool> isEnabled() {
    return _launchAtStartup.isEnabled();
  }

  @override
  Future<bool> setEnabled(bool enabled) {
    return enabled ? _launchAtStartup.enable() : _launchAtStartup.disable();
  }
}

class NoopLaunchAtStartupService implements LaunchAtStartupService {
  const NoopLaunchAtStartupService();

  @override
  Future<bool> isEnabled() async {
    return false;
  }

  @override
  Future<bool> setEnabled(bool enabled) async {
    return enabled == false;
  }
}

LaunchAtStartupService buildLaunchAtStartupService({
  String appName = 'gorion',
  String? appPath,
  String? packageName,
  List<String> args = const [],
}) {
  if (kIsWeb || !Platform.isWindows) {
    return const NoopLaunchAtStartupService();
  }

  return DesktopLaunchAtStartupService.configure(
    appName: appName,
    appPath: appPath ?? Platform.resolvedExecutable,
    packageName: packageName,
    args: args,
  );
}

String _quoteExecutablePath(String value) {
  final trimmed = value.trim();
  if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
    return trimmed;
  }
  return '"$trimmed"';
}
