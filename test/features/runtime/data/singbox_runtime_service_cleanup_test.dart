import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion/core/constants/singbox_assets.dart';
import 'package:gorion/core/process/running_process_lookup.dart';
import 'package:gorion/features/runtime/data/singbox_runtime_service.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory runtimeDir;

  setUp(() async {
    runtimeDir = await Directory.systemTemp.createTemp(
      'gorion-singbox-orphan-test-',
    );
  });

  tearDown(() async {
    if (await runtimeDir.exists()) {
      await runtimeDir.delete(recursive: true);
    }
  });

  test(
    'cleanupOrphanedProcessForTesting kills a real orphaned process and removes the marker',
    () async {
      final binaryPath = p.join(
        runtimeDir.path,
        resolveSingboxAsset().fileName,
      );
      final configPath = p.join(runtimeDir.path, 'current-config.json');
      // `tail -f` stays alive with both paths on its command line, like a
      // real sing-box invocation; the files must exist for tail to run.
      await File(binaryPath).create();
      await File(configPath).create();

      final orphan = await Process.start('tail', [
        '-f',
        binaryPath,
        configPath,
      ]);
      // Subscribe early so the VM reaps the child after the kill.
      final exitFuture = orphan.exitCode;
      addTearDown(() => orphan.kill(ProcessSignal.sigkill));

      final markerFile = File(p.join(runtimeDir.path, 'runtime-process.json'));
      await markerFile.writeAsString(
        jsonEncode({
          'pid': orphan.pid,
          'binaryPath': binaryPath,
          'configPath': configPath,
        }),
        flush: true,
      );

      final service = SingboxRuntimeService();
      await service.cleanupOrphanedProcessForTesting(runtimeDir);

      expect(await markerFile.exists(), isFalse);
      await expectLater(
        exitFuture.timeout(const Duration(seconds: 5)),
        completes,
      );
    },
    testOn: '!windows',
  );

  test(
    'cleanupOrphanedProcessForTesting removes the marker when the orphan is already gone',
    () async {
      final markerFile = File(p.join(runtimeDir.path, 'runtime-process.json'));
      await markerFile.writeAsString(jsonEncode({'pid': 9999998}), flush: true);

      final service = SingboxRuntimeService(
        runningProcessLookupReader: (_) async =>
            const RunningProcessLookup.missing(),
      );

      await service.cleanupOrphanedProcessForTesting(runtimeDir);

      expect(await markerFile.exists(), isFalse);
    },
  );

  test(
    'cleanupOrphanedProcessForTesting keeps sing-box marker when process inspection is unavailable',
    () async {
      final binaryPath = p.join(
        runtimeDir.path,
        resolveSingboxAsset().fileName,
      );
      final configPath = p.join(runtimeDir.path, 'current-config.json');
      final markerFile = File(p.join(runtimeDir.path, 'runtime-process.json'));
      await markerFile.writeAsString(
        jsonEncode({
          'pid': 9999998,
          'binaryPath': binaryPath,
          'configPath': configPath,
        }),
        flush: true,
      );

      final service = SingboxRuntimeService(
        runningProcessLookupReader: (_) async =>
            const RunningProcessLookup.unavailable(),
      );

      await service.cleanupOrphanedProcessForTesting(runtimeDir);

      expect(await markerFile.exists(), isTrue);
      await expectLater(
        service.ensureNoOrphanedProcessConflictForTesting(runtimeDir),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('could not safely verify'),
          ),
        ),
      );
    },
  );
}
