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
    LaunchAtStartupService? legacyRunEntryService,
  }) : _taskName = _buildTaskName(appName),
       _appPath = _normalizeExecutablePath(appPath),
       _args = List.unmodifiable(args),
       _processRunner =
           processRunner ??
           ((executable, arguments) => Process.run(executable, arguments)),
       _legacyRunEntryService =
           legacyRunEntryService ?? const NoopLaunchAtStartupService();

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
      legacyRunEntryService: LegacyRunEntryLaunchAtStartupService.configure(
        appName: appName,
        appPath: appPath,
        packageName: packageName,
        args: args,
      ),
    );
  }

  final String _taskName;
  final String _appPath;
  final List<String> _args;
  final LaunchAtStartupProcessRunner _processRunner;
  final LaunchAtStartupService _legacyRunEntryService;

  @override
  Future<bool> isEnabled() async {
    final scheduledTaskEnabled = await _isScheduledTaskEnabled();
    if (scheduledTaskEnabled) {
      return true;
    }

    final legacyEnabled = await _legacyRunEntryService.isEnabled();
    if (!legacyEnabled) {
      return false;
    }

    final migrated = await _createScheduledTask();
    if (migrated) {
      await _disableLegacyRunEntrySilently();
    }
    return true;
  }

  @override
  Future<bool> setEnabled(bool enabled) async {
    if (enabled) {
      final scheduledTaskEnabled = await _createScheduledTask();
      if (!scheduledTaskEnabled) {
        return false;
      }
      await _disableLegacyRunEntrySilently();
      return true;
    }

    final scheduledTaskDisabled = await _deleteScheduledTask();
    final legacyRunEntryDisabled = await _disableLegacyRunEntrySilently();
    return scheduledTaskDisabled && legacyRunEntryDisabled;
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

  Future<bool> _createScheduledTask() async {
    final result = await _runPowerShell(_buildCreateTaskScript());
    if (result.exitCode == 0) {
      return true;
    }
    _throwPowerShellException(
      result,
      'Не удалось создать автозапуск Windows с правами администратора.',
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

  Future<bool> _disableLegacyRunEntrySilently() async {
    try {
      return await _legacyRunEntryService.setEnabled(false);
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

  String _buildCreateTaskScript() {
    final actionCommand = _args.isEmpty
        ? '  \$action = New-ScheduledTaskAction -Execute ${_toPowerShellLiteral(_appPath)}'
        : '  \$action = New-ScheduledTaskAction -Execute ${_toPowerShellLiteral(_appPath)} -Argument ${_toPowerShellLiteral(_buildWindowsArgumentLine(_args))}';

    return '''
try {
  \$userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
  \$trigger = New-ScheduledTaskTrigger -AtLogOn -User \$userId
  \$principal = New-ScheduledTaskPrincipal -UserId \$userId -LogonType Interactive -RunLevel Highest
$actionCommand
  Register-ScheduledTask -TaskName ${_toPowerShellLiteral(_taskName)} -Action \$action -Trigger \$trigger -Principal \$principal -Force | Out-Null
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

  static String _normalizeExecutablePath(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
      return trimmed.substring(1, trimmed.length - 1);
    }
    return trimmed;
  }

  static String _buildWindowsArgumentLine(List<String> args) {
    return args.map(_quoteWindowsCommandLineArgument).join(' ');
  }

  static String _quoteWindowsCommandLineArgument(String value) {
    if (value.isEmpty) {
      return '""';
    }

    final needsQuotes = value.contains(RegExp(r'[\s"]'));
    if (!needsQuotes) {
      return value;
    }

    final buffer = StringBuffer('"');
    var backslashCount = 0;
    for (final rune in value.runes) {
      final char = String.fromCharCode(rune);
      if (char == r'\') {
        backslashCount += 1;
        continue;
      }
      if (char == '"') {
        buffer.write(_repeatBackslashes(backslashCount * 2 + 1));
        buffer.write('"');
        backslashCount = 0;
        continue;
      }
      if (backslashCount > 0) {
        buffer.write(_repeatBackslashes(backslashCount));
        backslashCount = 0;
      }
      buffer.write(char);
    }
    if (backslashCount > 0) {
      buffer.write(_repeatBackslashes(backslashCount * 2));
    }
    buffer.write('"');
    return buffer.toString();
  }

  static String _repeatBackslashes(int count) {
    return List.filled(count, r'\').join();
  }

  static String _toPowerShellLiteral(String value) {
    return "'${value.replaceAll("'", "''")}'";
  }
}

class LegacyRunEntryLaunchAtStartupService implements LaunchAtStartupService {
  LegacyRunEntryLaunchAtStartupService._(this._launchAtStartup);

  factory LegacyRunEntryLaunchAtStartupService.configure({
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
    return LegacyRunEntryLaunchAtStartupService._(launchAtStartup);
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
