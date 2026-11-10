import 'dart:io';
import 'package:path/path.dart' as p;

import 'package:gorion_clean/core/process/process_runner.dart';
import 'package:gorion_clean/core/privileged_helper/privileged_helper_protocol.dart';

/// The user declined the admin password prompt (osascript exit code -128) or
/// cancelled the dialog in another way.
class HelperInstallCancelledException implements Exception {
  const HelperInstallCancelledException();

  @override
  String toString() => 'Установка системного компонента отменена.';
}

/// Installs (and repairs) the privileged helper launchd daemon on macOS.
///
/// The daemon runs the very same app binary with `--gorion-privileged-helper`
/// as root. Installation needs admin rights once, requested through the
/// native macOS password prompt (`osascript ... with administrator
/// privileges`). The daemon starts at boot and is kept alive by launchd.
class MacosPrivilegedHelperInstaller {
  const MacosPrivilegedHelperInstaller({
    Future<ProcessResult> Function(
          String executable,
          List<String> arguments, {
          Duration timeout,
        })
        processRunner =
        _defaultProcessRunner,
  }) : _processRunner = processRunner;

  final Future<ProcessResult> Function(
    String executable,
    List<String> arguments, {
    Duration timeout,
  })
  _processRunner;

  static const _osascriptTimeout = Duration(minutes: 3);

  static Future<ProcessResult> _defaultProcessRunner(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 15),
  }) {
    return runProcessWithTimeout(executable, arguments, timeout: timeout);
  }

  bool isInstalledSync() {
    return File(gorionPrivilegedHelperMacosPlistPath).existsSync();
  }

  /// Builds the launchd plist for the helper pointing at [executablePath].
  static String buildPlist({required String executablePath}) {
    String escape(String value) {
      return value
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;');
    }

    return '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$gorionPrivilegedHelperMacosLabel</string>
	<key>ProgramArguments</key>
	<array>
		<string>${escape(executablePath)}</string>
		<string>$gorionPrivilegedHelperArg</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>$gorionPrivilegedHelperMacosSupportDir/helper.stdout.log</string>
	<key>StandardErrorPath</key>
	<string>$gorionPrivilegedHelperMacosSupportDir/helper.stderr.log</string>
</dict>
</plist>
''';
  }

  /// Runs the full install (or repair): writes the plist, creates the shared
  /// support directory with root:admin permissions, loads the daemon and
  /// clears the stale state file so a fresh token is published.
  ///
  /// Throws [HelperInstallCancelledException] when the user declines the
  /// password prompt.
  Future<void> install({String? executablePath}) async {
    if (!Platform.isMacOS) {
      throw UnsupportedError(
        'The launchd helper installer is only available on macOS.',
      );
    }

    final executable = executablePath ?? Platform.resolvedExecutable;
    final bundle = File(executable).parent.parent.parent;
    if (!bundle.path.endsWith('.app')) {
      throw StateError('Install the TUN helper from a built macOS app bundle.');
    }
    final installedBundle = p.join(
      gorionPrivilegedHelperMacosSupportDir,
      'Helper.app',
    );
    final installedExecutable = p.join(
      installedBundle,
      'Contents',
      'MacOS',
      p.basename(executable),
    );
    final plist = buildPlist(executablePath: installedExecutable);

    final tempPlist = File(
      '${Directory.systemTemp.path}/gorion-privileged-helper-${DateTime.now().microsecondsSinceEpoch}.plist',
    );
    await tempPlist.writeAsString(plist, flush: true);

    try {
      final shellScript =
          '''
set -e
/bin/mkdir -p ${shellQuote(gorionPrivilegedHelperMacosSupportDir)}
/usr/sbin/chown -R root:admin ${shellQuote(gorionPrivilegedHelperMacosSupportDir)}
/bin/chmod -R go-w ${shellQuote(gorionPrivilegedHelperMacosSupportDir)}
/bin/chmod 0750 ${shellQuote(gorionPrivilegedHelperMacosSupportDir)}
/bin/launchctl bootout system/$gorionPrivilegedHelperMacosLabel 2>/dev/null || true
/usr/bin/ditto ${shellQuote(bundle.path)} ${shellQuote(installedBundle)}
/usr/sbin/chown -R root:wheel ${shellQuote(installedBundle)}
/bin/chmod -R go-w ${shellQuote(installedBundle)}
/bin/cp ${shellQuote(tempPlist.path)} ${shellQuote(gorionPrivilegedHelperMacosPlistPath)}
/usr/sbin/chown root:wheel ${shellQuote(gorionPrivilegedHelperMacosPlistPath)}
/bin/chmod 0644 ${shellQuote(gorionPrivilegedHelperMacosPlistPath)}
/bin/rm -f ${shellQuote(gorionPrivilegedHelperMacosStatePath)}
/bin/launchctl bootstrap system ${shellQuote(gorionPrivilegedHelperMacosPlistPath)}
/bin/launchctl kickstart system/$gorionPrivilegedHelperMacosLabel
''';
      await _runOsascript(shellScript);
    } finally {
      try {
        await tempPlist.delete();
      } on Object {
        // Temp files are reaped by the OS anyway.
      }
    }
  }

  /// Restarts an already installed daemon (repair path when health checks
  /// fail but the plist is present).
  Future<void> kickstart() async {
    if (!Platform.isMacOS) {
      return;
    }
    await _runOsascript(
      '/bin/launchctl kickstart -k system/$gorionPrivilegedHelperMacosLabel',
    );
  }

  Future<void> _runOsascript(String shellScript) async {
    const prompt =
        'Gorion нужно установить системный компонент для режима TUN. '
        'Он запускается от root и управляет VPN-туннелем.';
    final script =
        'do shell script "${_escapeForAppleScript(shellScript)}" '
        'with prompt "${_escapeForAppleScript(prompt)}" '
        'with administrator privileges';
    final result = await _processRunner('osascript', [
      '-e',
      script,
    ], timeout: _osascriptTimeout);

    if (result.exitCode == 0) {
      return;
    }

    final stderr = result.stderr.toString();
    if (result.exitCode == -128 ||
        result.exitCode == 128 ||
        stderr.contains('User canceled') ||
        stderr.contains('отмен')) {
      throw const HelperInstallCancelledException();
    }

    throw ProcessException(
      'osascript',
      const ['-e', '<privileged helper install>'],
      stderr.trim().isEmpty
          ? 'Failed to install the privileged helper.'
          : stderr.trim(),
      result.exitCode,
    );
  }

  /// Shell-quotes a single argument for the embedded shell script.
  static String shellQuote(String value) {
    return "'${value.replaceAll("'", "'\\''")}'";
  }

  static String _escapeForAppleScript(String value) {
    return value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
  }
}
