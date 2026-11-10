import 'dart:io';

import 'package:gorion/features/runtime/data/posix_runtime_cleanup_watchdog.dart';
import 'package:gorion/features/runtime/data/system_proxy_service.dart'
    show ProxyLogSink;
import 'package:gorion/features/runtime/data/windows_runtime_cleanup_watchdog.dart';

/// Platform-dispatching crash guard for the sing-box runtime. Windows keeps
/// the PowerShell implementation (it also restores WinHTTP state); macOS and
/// Linux use the detached shell watchdog.
class RuntimeCleanupWatchdog {
  const RuntimeCleanupWatchdog({
    WindowsRuntimeCleanupWatchdog windows =
        const WindowsRuntimeCleanupWatchdog(),
    PosixRuntimeCleanupWatchdog posix = const PosixRuntimeCleanupWatchdog(),
  }) : _windows = windows,
       _posix = posix;

  final WindowsRuntimeCleanupWatchdog _windows;
  final PosixRuntimeCleanupWatchdog _posix;

  Future<void> arm({
    required Directory runtimeDir,
    required int parentPid,
    required int childPid,
    int? managedProxyPort,
    ProxyLogSink? onLog,
  }) async {
    void log(String line, {bool isError = false}) {
      onLog?.call(line, isError: isError);
    }

    if (Platform.isWindows) {
      await _windows.arm(
        runtimeDir: runtimeDir,
        parentPid: parentPid,
        childPid: childPid,
        onLog: log,
      );
      return;
    }

    await _posix.arm(
      runtimeDir: runtimeDir,
      parentPid: parentPid,
      childPid: childPid,
      managedProxyPort: managedProxyPort,
      onLog: log,
    );
  }
}
