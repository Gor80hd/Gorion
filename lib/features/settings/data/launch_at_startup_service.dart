import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:gorion_clean/core/windows/windows_elevation_service.dart';
import 'package:gorion_clean/features/settings/model/desktop_settings.dart';
import 'package:launch_at_startup/launch_at_startup.dart';

typedef LaunchAtStartupProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

abstract interface class LaunchAtStartupService {
  Future<bool> isEnabled();

  Future<LaunchAtStartupPriority> getPriority();

  Future<bool> setEnabled(
    bool enabled, {
    LaunchAtStartupPriority priority = LaunchAtStartupPriority.standard,
  });
}

class DesktopLaunchAtStartupService implements LaunchAtStartupService {
  DesktopLaunchAtStartupService({
    required String appName,
    required String appPath,
    List<String> args = const [],
    LaunchAtStartupProcessRunner? processRunner,
    LaunchAtStartupService? startupEntryService,
  }) : _taskName = _buildTaskName(appName),
       _appName = appName,
       _appPath = appPath,
       _args = List.unmodifiable(args),
       _hasLegacyStartupEntryMigration = args.isNotEmpty,
       _legacyStartupEntryValue = _buildRegistryValue(appPath, const []),
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
  final String _appName;
  final String _appPath;
  final List<String> _args;
  final bool _hasLegacyStartupEntryMigration;
  final String _legacyStartupEntryValue;
  final LaunchAtStartupProcessRunner _processRunner;
  final LaunchAtStartupService _startupEntryService;

  @override
  Future<bool> isEnabled() async {
    final scheduledTaskEnabled = await _isScheduledTaskEnabled();
    if (scheduledTaskEnabled) {
      return true;
    }

    final startupEntryEnabled = await _startupEntryService.isEnabled();
    if (startupEntryEnabled) {
      return true;
    }

    if (_hasLegacyStartupEntryMigration &&
        await _isLegacyStartupEntryEnabled()) {
      return true;
    }

    return false;
  }

  @override
  Future<LaunchAtStartupPriority> getPriority() async {
    final scheduledTaskEnabled = await _isScheduledTaskEnabled();
    if (scheduledTaskEnabled) {
      return LaunchAtStartupPriority.first;
    }
    return LaunchAtStartupPriority.standard;
  }

  @override
  Future<bool> setEnabled(
    bool enabled, {
    LaunchAtStartupPriority priority = LaunchAtStartupPriority.standard,
  }) async {
    if (enabled) {
      if (priority == LaunchAtStartupPriority.first) {
        final scheduledTaskEnabled = await _createScheduledTask();
        if (!scheduledTaskEnabled) {
          return false;
        }

        final startupEntryDisabled = await _disableStartupEntrySilently();
        if (!startupEntryDisabled) {
          await _deleteScheduledTaskSilently();
          return false;
        }
        return true;
      }

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

  Future<bool> _createScheduledTask() async {
    final result = await _runPowerShell(_buildCreateTaskScript());
    if (result.exitCode == 0) {
      return true;
    }
    _throwPowerShellException(
      result,
      'Не удалось включить приоритетный автозапуск Windows.',
    );
  }

  Future<bool> _disableStartupEntrySilently() async {
    try {
      return await _startupEntryService.setEnabled(false);
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

  Future<bool> _isLegacyStartupEntryEnabled() async {
    final result = await _runPowerShell(_buildLegacyStartupEntryExistsScript());
    if (result.exitCode == 0) {
      return true;
    }
    if (result.exitCode == 1) {
      return false;
    }
    _throwPowerShellException(
      result,
      'Не удалось проверить legacy startup entry Windows.',
    );
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

  String _buildCreateTaskScript() {
    final argumentString = _joinWindowsArguments(_args);
    final actionArgumentClause = argumentString.isEmpty
        ? ''
        : ' -Argument ${_toPowerShellLiteral(argumentString)}';

    return '''
try {
  \$userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
  \$action = New-ScheduledTaskAction -Execute ${_toPowerShellLiteral(_appPath)}$actionArgumentClause
  \$trigger = New-ScheduledTaskTrigger -AtLogOn -User \$userId
  \$principal = New-ScheduledTaskPrincipal -UserId \$userId -LogonType Interactive -RunLevel Highest
  Register-ScheduledTask -TaskName ${_toPowerShellLiteral(_taskName)} -Action \$action -Trigger \$trigger -Principal \$principal -Description ${_toPowerShellLiteral('Launch $_appName at logon before standard startup entries.')} -Force | Out-Null
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

  String _buildLegacyStartupEntryExistsScript() {
    return '''
try {
  \$runKeyPath = 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'
  \$approvedKeyPath = 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run'
  \$valueName = ${_toPowerShellLiteral(_appName)}
  \$expectedValue = ${_toPowerShellLiteral(_legacyStartupEntryValue)}
  \$runValue = Get-ItemPropertyValue -Path \$runKeyPath -Name \$valueName -ErrorAction SilentlyContinue
  if (\$runValue -ne \$expectedValue) {
    exit 1
  }
  \$approved = Get-ItemPropertyValue -Path \$approvedKeyPath -Name \$valueName -ErrorAction SilentlyContinue
  if (\$null -eq \$approved -or \$approved.Length -eq 0 -or (\$approved[0] % 2) -eq 0) {
    exit 0
  }
  exit 1
} catch {
  \$message = \$_.Exception.Message
  if (\$message) {
    [Console]::Error.WriteLine(\$message)
  }
  exit 2
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

  static String _buildRegistryValue(String appPath, List<String> args) {
    final executable = _quoteExecutablePath(appPath);
    if (args.isEmpty) {
      return executable;
    }
    return '$executable ${args.join(' ')}';
  }

  static String _toPowerShellLiteral(String value) {
    return "'${value.replaceAll("'", "''")}'";
  }

  static String _joinWindowsArguments(List<String> args) {
    return args.map(_quoteCommandLineArgument).join(' ').trim();
  }

  static String _quoteCommandLineArgument(String value) {
    final escaped = value.replaceAll('"', r'\"');
    if (escaped.isEmpty) {
      return '""';
    }
    if (escaped.contains(RegExp(r'\s'))) {
      return '"$escaped"';
    }
    return escaped;
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
  Future<LaunchAtStartupPriority> getPriority() async {
    return LaunchAtStartupPriority.standard;
  }

  @override
  Future<bool> setEnabled(
    bool enabled, {
    LaunchAtStartupPriority priority = LaunchAtStartupPriority.standard,
  }) {
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
  Future<LaunchAtStartupPriority> getPriority() async {
    return LaunchAtStartupPriority.standard;
  }

  @override
  Future<bool> setEnabled(
    bool enabled, {
    LaunchAtStartupPriority priority = LaunchAtStartupPriority.standard,
  }) async {
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
    args: args.isEmpty ? const [gorionLaunchAtStartupArg] : args,
  );
}

String _quoteExecutablePath(String value) {
  final trimmed = value.trim();
  if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
    return trimmed;
  }
  return '"$trimmed"';
}
