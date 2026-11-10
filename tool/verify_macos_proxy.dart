// Live check on an explicitly selected, inactive network service.
// dart run tool/verify_macos_proxy.dart 'iPhone USB'
// Exercises apply, crash guard, and full journal recovery. Never deletes a
// journal after a failed restore. Does not install a login LaunchAgent.
import 'dart:convert';
import 'dart:io';
import 'package:gorion_clean/features/runtime/data/system_proxy_service.dart';
import 'package:gorion_clean/features/runtime/data/posix_runtime_cleanup_watchdog.dart';
import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';

class SelectedServiceBackend extends MacosSystemProxyBackend {
  const SelectedServiceBackend(this.service);
  final String service;
  @override
  Future<List<String>> listActiveServices() async => [service];
}

Future<void> main(List<String> args) async {
  if (!Platform.isMacOS || args.length != 1) {
    throw ArgumentError('Specify one inactive macOS network service.');
  }
  final backend = SelectedServiceBackend(args.single);
  final service = SystemProxyService(macosBackend: backend);
  final before = await backend.readService(args.single);
  final dir = await Directory.systemTemp.createTemp('gorion-live-recovery-');
  final parent = await Process.start('/bin/sleep', ['60']);
  final child = await Process.start('/bin/sleep', ['60']);
  final childExit = child.exitCode;
  SystemProxyLease? lease;
  void log(String line, {bool isError = false}) => stdout.writeln(line);
  try {
    await File(
      '${dir.path}/runtime-process.json',
    ).writeAsString(jsonEncode({'pid': child.pid}));
    await const PosixRuntimeCleanupWatchdog().arm(
      runtimeDir: dir,
      parentPid: parent.pid,
      childPid: child.pid,
      managedProxyPort: 59998,
      installLoginRecovery: false,
    );
    lease = await service.enable(
      mode: RuntimeMode.systemProxy,
      runtimeDir: dir,
      mixedPort: 59998,
      onLog: log,
    );
    final during = await backend.readService(args.single);
    if (!during.web.enabled ||
        !during.secureWeb.enabled ||
        !during.socks.enabled) {
      throw StateError('Not all endpoints were enabled.');
    }
    parent.kill(ProcessSignal.sigkill);
    await parent.exitCode;
    await childExit.timeout(const Duration(seconds: 15));
    final afterCrash = await backend.readService(args.single);
    if (afterCrash.web.enabled ||
        afterCrash.secureWeb.enabled ||
        afterCrash.socks.enabled) {
      throw StateError('Guard did not disable all managed endpoints.');
    }
    stdout.writeln('Crash guard: all three managed endpoints disabled.');
  } finally {
    parent.kill(ProcessSignal.sigkill);
    child.kill(ProcessSignal.sigkill);
    await service.restore(runtimeDir: dir, lease: lease, onLog: log);
    final after = await backend.readService(args.single);
    if (jsonEncode(before.toJson()) != jsonEncode(after.toJson())) {
      throw StateError('Snapshot differs after recovery; inspect ${dir.path}.');
    }
    if (!await File('${dir.path}/system-proxy.json').exists()) {
      await dir.delete(recursive: true);
    }
  }
  stdout.writeln(
    'Verified original HTTP, HTTPS, SOCKS and bypass settings restored.',
  );
}
