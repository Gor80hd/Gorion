import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _pendingActionArgPrefix = '--gorion-pending-action=';
const gorionLaunchAtStartupArg = '--gorion-launched-at-startup';

enum PendingElevatedLaunchAction {
  connectTun('connect-tun'),
  startZapret('start-zapret'),
  testZapretConfigs('test-zapret-configs');

  const PendingElevatedLaunchAction(this.cliValue);

  final String cliValue;

  String toCliArg() => '$_pendingActionArgPrefix$cliValue';

  static PendingElevatedLaunchAction? fromArg(String value) {
    if (!value.startsWith(_pendingActionArgPrefix)) {
      return null;
    }

    final rawValue = value.substring(_pendingActionArgPrefix.length).trim();
    for (final action in values) {
      if (action.cliValue == rawValue) {
        return action;
      }
    }
    return null;
  }
}

class AppLaunchRequest {
  const AppLaunchRequest({
    this.pendingElevatedAction,
    this.launchedAtStartup = false,
  });

  final PendingElevatedLaunchAction? pendingElevatedAction;
  final bool launchedAtStartup;

  bool get resumesAfterElevation => pendingElevatedAction != null;

  static AppLaunchRequest fromArgs(List<String> args) {
    PendingElevatedLaunchAction? pendingElevatedAction;
    var launchedAtStartup = false;
    for (final arg in args) {
      pendingElevatedAction =
          PendingElevatedLaunchAction.fromArg(arg) ?? pendingElevatedAction;
      if (arg.trim().toLowerCase() == gorionLaunchAtStartupArg) {
        launchedAtStartup = true;
      }
    }
    return AppLaunchRequest(
      pendingElevatedAction: pendingElevatedAction,
      launchedAtStartup: launchedAtStartup,
    );
  }
}

final appLaunchRequestProvider = Provider<AppLaunchRequest>(
  (ref) => const AppLaunchRequest(),
);

final windowsElevationServiceProvider = Provider<WindowsElevationService>(
  (ref) => const NoopWindowsElevationService(),
);

abstract interface class WindowsElevationService {
  Future<bool> isElevated();

  Future<void> relaunchAsAdministrator({
    required PendingElevatedLaunchAction action,
  });
}

class ElevationRequestCancelledException implements Exception {
  const ElevationRequestCancelledException([
    this.message = 'The elevation request was cancelled by the user.',
  ]);

  final String message;

  @override
  String toString() => message;
}

class PowerShellWindowsElevationService implements WindowsElevationService {
  PowerShellWindowsElevationService({
    List<String> currentArgs = const [],
    Future<void> Function(int exitCode)? exitCurrentProcess,
  }) : _currentArgs = _sanitizeArgs(currentArgs),
       _exitCurrentProcess = exitCurrentProcess ?? _defaultExitCurrentProcess;

  final List<String> _currentArgs;
  final Future<void> Function(int exitCode) _exitCurrentProcess;

  @override
  Future<bool> isElevated() async {
    if (!Platform.isWindows) {
      return false;
    }

    final result = await Process.run('powershell.exe', const [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      '[bool](([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))',
    ]);
    if (result.exitCode != 0) {
      throw ProcessException(
        'powershell.exe',
        const [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          '[bool](([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))',
        ],
        _combineProcessOutput(result),
        result.exitCode,
      );
    }

    return result.stdout.toString().trim().toLowerCase() == 'true';
  }

  @override
  Future<void> relaunchAsAdministrator({
    required PendingElevatedLaunchAction action,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError(
        'Elevation relaunch is only available on Windows.',
      );
    }

    final executablePath = Platform.resolvedExecutable;
    final arguments = <String>[..._currentArgs, action.toCliArg()];
    final script = _buildRelaunchScript(
      executablePath: executablePath,
      arguments: arguments,
    );

    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ]);

    if (result.exitCode == 0) {
      await _exitCurrentProcess(0);
      return;
    }

    final details = _combineProcessOutput(result);
    if (result.exitCode == 1223 || _isUserCancelled(details)) {
      throw const ElevationRequestCancelledException();
    }

    throw ProcessException(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ],
      details.isEmpty
          ? 'Не удалось запросить повышение прав администратора.'
          : details,
      result.exitCode,
    );
  }

  static List<String> _sanitizeArgs(List<String> args) {
    return [
      for (final arg in args)
        if (!arg.startsWith(_pendingActionArgPrefix)) arg,
    ];
  }

  static Future<void> _defaultExitCurrentProcess(int exitCode) async {
    exit(exitCode);
  }

  String _buildRelaunchScript({
    required String executablePath,
    required List<String> arguments,
  }) {
    final powerShellArguments = arguments.map(_toPowerShellLiteral).join(', ');
    final argumentExpression = arguments.isEmpty
        ? '@()'
        : '@($powerShellArguments)';

    return '''
\$arguments = $argumentExpression
try {
  Start-Process -FilePath ${_toPowerShellLiteral(executablePath)} -ArgumentList \$arguments -Verb RunAs -ErrorAction Stop | Out-Null
  exit 0
} catch {
  \$message = \$_.Exception.Message
  if (\$message) {
    [Console]::Error.WriteLine(\$message)
  }
  if (\$message -match 'cancelled by the user|canceled by the user|отмен[а-я]+ пользователем') {
    exit 1223
  }
  exit 1
}
''';
  }

  String _toPowerShellLiteral(String value) {
    return "'${value.replaceAll("'", "''")}'";
  }

  bool _isUserCancelled(String value) {
    final normalized = value.toLowerCase();
    return normalized.contains('cancelled by the user') ||
        normalized.contains('canceled by the user') ||
        normalized.contains('отмен') && normalized.contains('пользовател');
  }

  String _combineProcessOutput(ProcessResult result) {
    final lines = <String>[];
    final stderr = result.stderr?.toString().trim();
    final stdout = result.stdout?.toString().trim();
    if (stderr != null && stderr.isNotEmpty) {
      lines.add(stderr);
    }
    if (stdout != null && stdout.isNotEmpty) {
      lines.add(stdout);
    }
    return lines.join('\n');
  }
}

class NoopWindowsElevationService implements WindowsElevationService {
  const NoopWindowsElevationService();

  @override
  Future<bool> isElevated() async {
    return false;
  }

  @override
  Future<void> relaunchAsAdministrator({
    required PendingElevatedLaunchAction action,
  }) async {
    throw UnsupportedError('Elevation relaunch is only available on Windows.');
  }
}

WindowsElevationService buildWindowsElevationService({
  List<String> currentArgs = const [],
  Future<void> Function(int exitCode)? exitCurrentProcess,
}) {
  if (kIsWeb || !Platform.isWindows) {
    return const NoopWindowsElevationService();
  }

  return PowerShellWindowsElevationService(
    currentArgs: currentArgs,
    exitCurrentProcess: exitCurrentProcess,
  );
}
