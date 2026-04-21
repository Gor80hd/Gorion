import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/core/constants/singbox_assets.dart';
import 'package:gorion_clean/core/process/running_process_lookup.dart';
import 'package:gorion_clean/features/runtime/data/singbox_runtime_service.dart';
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
    'cleanupOrphanedProcessForTesting recovers legacy sing-box markers using inferred runtime paths',
    () async {
      final markerFile = File(p.join(runtimeDir.path, 'runtime-process.json'));
      await markerFile.writeAsString(jsonEncode({'pid': 9999999}), flush: true);

      final binaryPath = p.join(
        runtimeDir.path,
        resolveSingboxAsset().fileName,
      );
      final configPath = p.join(runtimeDir.path, 'current-config.json');
      final service = SingboxRuntimeService(
        runningProcessLookupReader: (_) async => RunningProcessLookup.found(
          executablePath: binaryPath,
          commandLine: '"$binaryPath" run -c "$configPath"',
        ),
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
