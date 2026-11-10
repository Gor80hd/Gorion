import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/runtime/data/posix_runtime_cleanup_watchdog.dart';

void main() {
  test(
    'crashed owner terminates child and retains recovery journals',
    () async {
      final dir = await Directory.systemTemp.createTemp('gorion-guard-test-');
      final parent = await Process.start('/bin/sleep', ['60']);
      final child = await Process.start('/bin/sleep', ['60']);
      final parentExit = parent.exitCode;
      final childExit = child.exitCode;
      addTearDown(() async {
        parent.kill(ProcessSignal.sigkill);
        child.kill(ProcessSignal.sigkill);
        await dir.delete(recursive: true);
      });
      final marker = File('${dir.path}/runtime-process.json');
      await marker.writeAsString(jsonEncode({'pid': child.pid}));
      await const PosixRuntimeCleanupWatchdog().arm(
        runtimeDir: dir,
        parentPid: parent.pid,
        childPid: child.pid,
        installLoginRecovery: false,
      );
      parent.kill(ProcessSignal.sigkill);
      await parentExit;
      await childExit.timeout(const Duration(seconds: 8));
      expect(await marker.exists(), isTrue);
    },
    testOn: '!windows',
  );

  test(
    'old guard does not kill child after marker ownership changes',
    () async {
      final dir = await Directory.systemTemp.createTemp('gorion-guard-test-');
      final parent = await Process.start('/bin/sleep', ['60']);
      final child = await Process.start('/bin/sleep', ['60']);
      var exited = false;
      unawaited(child.exitCode.then((_) => exited = true));
      addTearDown(() async {
        parent.kill(ProcessSignal.sigkill);
        child.kill(ProcessSignal.sigkill);
        await dir.delete(recursive: true);
      });
      final marker = File('${dir.path}/runtime-process.json');
      await marker.writeAsString(jsonEncode({'pid': child.pid}));
      await const PosixRuntimeCleanupWatchdog().arm(
        runtimeDir: dir,
        parentPid: parent.pid,
        childPid: child.pid,
        installLoginRecovery: false,
      );
      await marker.writeAsString(jsonEncode({'pid': child.pid + 1000000}));
      parent.kill(ProcessSignal.sigkill);
      await parent.exitCode;
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(exited, isFalse);
    },
    testOn: '!windows',
  );
}
