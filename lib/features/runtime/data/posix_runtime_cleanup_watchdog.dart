import 'dart:io';

import 'package:gorion_clean/core/process/process_runner.dart';
import 'package:gorion_clean/features/runtime/data/system_proxy_service.dart'
    show ProxyLogSink;
import 'package:path/path.dart' as p;

/// Crash guard for the sing-box runtime on macOS and Linux.
///
/// A detached process handles GUI crashes. Power loss also kills the guard;
/// a login LaunchAgent disables stale endpoints after reboot, and Gorion
/// restores the original configuration from the durable journal on startup.
/// The guard disables only endpoints on the managed port and retains the
/// journal so the app can restore the original configuration later.
class PosixRuntimeCleanupWatchdog {
  const PosixRuntimeCleanupWatchdog();

  static const scriptFileName = 'runtime-watchdog.sh';

  Future<void> arm({
    required Directory runtimeDir,
    required int parentPid,
    required int childPid,
    int? managedProxyPort,
    ProxyLogSink? onLog,
    bool installLoginRecovery = true,
  }) async {
    if (!(Platform.isMacOS || Platform.isLinux)) {
      return;
    }

    final scriptFile = File(p.join(runtimeDir.path, scriptFileName));
    await scriptFile.writeAsString(_buildScript(), flush: true);
    await Process.run('chmod', ['700', scriptFile.path]);

    Future<String> identity(int processPid) async {
      final result = await runProcessWithTimeout('/bin/ps', [
        '-p',
        '$processPid',
        '-o',
        'lstart=',
        '-o',
        'command=',
      ]);
      return result.stdout.toString().trim();
    }

    final arguments = [
      scriptFile.path,
      '$parentPid',
      '$childPid',
      runtimeDir.path,
      if (managedProxyPort != null) '$managedProxyPort' else '',
      await identity(parentPid),
      await identity(childPid),
    ];
    if (Platform.isMacOS && managedProxyPort != null && installLoginRecovery) {
      // LaunchAgents are loaded at login, including after power loss. The
      // same ownership checks make an old job harmless after clean shutdown.
      final home = Platform.environment['HOME'];
      if (home == null) {
        throw StateError('Cannot install proxy login recovery.');
      }
      final agent = File(
        p.join(
          home,
          'Library',
          'LaunchAgents',
          'app.gorion.proxy-recovery.plist',
        ),
      );
      await agent.parent.create(recursive: true);
      String xml(String value) => value
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;');
      final pending = File('${agent.path}.tmp');
      await pending.writeAsString('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>app.gorion.proxy-recovery</string>
<key>ProgramArguments</key><array>
<string>/bin/bash</string>
${arguments.map((argument) => '<string>${xml(argument)}</string>').join('\n')}
</array><key>RunAtLoad</key><true/>
</dict></plist>
''', flush: true);
      await pending.rename(agent.path);
    }
    await Process.start(
      '/bin/bash',
      arguments,
      mode: ProcessStartMode.detached,
    );
    onLog?.call('Armed the POSIX runtime cleanup watchdog.');
  }

  static String _buildScript() {
    // Arguments: <parentPid> <childPid> <runtimeDir> [managedProxyPort]
    return r'''
#!/bin/bash
parent_pid="$1"
child_pid="$2"
runtime_dir="$3"
managed_port="$4"
process_marker="$runtime_dir/runtime-process.json"
proxy_marker="$runtime_dir/system-proxy.json"
parent_identity="$5"
child_identity="$6"

restore_managed_proxy() {
  [ -z "$managed_port" ] && return 0
  [ ! -f "$proxy_marker" ] && return 0
  command -v networksetup >/dev/null 2>&1 || return 0

  local service current kind failed=0
  while IFS= read -r service; do
    service="${service#\*}"
    [ -z "$service" ] && continue
    case "$service" in *asterisk*) continue ;; esac
    for kind in webproxy securewebproxy socksfirewallproxy; do
      current="$(networksetup -get"$kind" "$service" 2>/dev/null)"
      if printf '%s\n' "$current" | grep -Eq '^Server: (127\.0\.0\.1|localhost)$' &&
         printf '%s\n' "$current" | grep -qx "Port: $managed_port"; then
        networksetup -set"${kind}state" "$service" off >/dev/null 2>&1 || failed=1
      fi
    done
  done <<EOF
$(networksetup -listallnetworkservices 2>/dev/null)
EOF
  return "$failed"
  # Never discard the saved configuration: a failed command needs retry,
  # and successful emergency disabling still needs original-state restore.

}

while true; do
  # Stop an old guard before a later session can reuse the directory.
  if [ ! -f "$process_marker" ] ||
     ! grep -Eq "\"pid\":[[:space:]]*$child_pid([,}])" "$process_marker"; then
    exit 0
  fi
  current_parent="$(ps -p "$parent_pid" -o lstart= -o command= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [ -z "$current_parent" ] || [ "$current_parent" != "$parent_identity" ]; then
    proxy_restored=0
    restore_managed_proxy && proxy_restored=1
    current_identity="$(ps -p "$child_pid" -o lstart= -o command= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [ -n "$child_identity" ] && [ "$current_identity" = "$child_identity" ]; then
      kill "$child_pid" 2>/dev/null
      sleep 2
      current_identity="$(ps -p "$child_pid" -o lstart= -o command= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      if [ "$current_identity" = "$child_identity" ]; then
        kill -9 "$child_pid" 2>/dev/null
      fi
    fi
    # Retain both journals for startup recovery; retry failed proxy writes.
    [ "$proxy_restored" = 1 ] && exit 0
  fi
  sleep 1
done
''';
  }
}
