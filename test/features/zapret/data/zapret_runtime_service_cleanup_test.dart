import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/core/process/running_process_lookup.dart';
import 'package:gorion_clean/features/zapret/data/zapret_runtime_service.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory runtimeDir;

  setUp(() async {
    runtimeDir = await Directory.systemTemp.createTemp(
      'gorion-zapret-orphan-test-',
    );
  });

  tearDown(() async {
    if (await runtimeDir.exists()) {
      await runtimeDir.delete(recursive: true);
    }
  });

  test(
    'cleanupOrphanedProcessForTesting keeps legacy zapret markers when process inspection is unavailable',
    () async {
      final markerFile = File(p.join(runtimeDir.path, 'runtime-process.json'));
      await markerFile.writeAsString(jsonEncode({'pid': 9999997}), flush: true);

      final service = ZapretRuntimeService(
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

  test(
    'cleanupOrphanedProcessForTesting clears cwd-sensitive zapret markers when executable directory anchors relative files',
    () async {
      final executablePath = r'E:\Tools\zapret2\bin\winws.exe';
      final markerFile = File(p.join(runtimeDir.path, 'runtime-process.json'));
      await markerFile.writeAsString(
        jsonEncode({
          'pid': 9999996,
          'executablePath': executablePath,
          'workingDirectory': r'E:\Tools\zapret2\bin',
          'arguments': ['--dpi-desync-fake=tls_clienthello_google_com.bin'],
        }),
        flush: true,
      );

      final service = ZapretRuntimeService(
        runningProcessLookupReader: (_) async => RunningProcessLookup.found(
          executablePath: executablePath,
          commandLine:
              '"$executablePath" --dpi-desync-fake=tls_clienthello_google_com.bin',
        ),
      );

      await service.cleanupOrphanedProcessForTesting(runtimeDir);

      expect(await markerFile.exists(), isFalse);
    },
  );

  test(
    'cleanupOrphanedProcessForTesting keeps cwd-sensitive zapret markers when working directory cannot be anchored safely',
    () async {
      final executablePath = r'E:\Tools\zapret2\bin\winws.exe';
      final markerFile = File(p.join(runtimeDir.path, 'runtime-process.json'));
      await markerFile.writeAsString(
        jsonEncode({
          'pid': 9999996,
          'executablePath': executablePath,
          'workingDirectory': r'E:\Tools\zapret2\profiles',
          'arguments': ['--dpi-desync-fake=tls_clienthello_google_com.bin'],
        }),
        flush: true,
      );

      final service = ZapretRuntimeService(
        runningProcessLookupReader: (_) async => RunningProcessLookup.found(
          commandLine:
              '"$executablePath" --dpi-desync-fake=tls_clienthello_google_com.bin',
        ),
      );

      await service.cleanupOrphanedProcessForTesting(runtimeDir);

      expect(await markerFile.exists(), isTrue);
    },
  );

  test(
    'cleanupOrphanedProcessForTesting still clears zapret marker for verified flag-only arguments',
    () async {
      final executablePath = r'E:\Tools\zapret2\bin\winws.exe';
      final markerFile = File(p.join(runtimeDir.path, 'runtime-process.json'));
      await markerFile.writeAsString(
        jsonEncode({
          'pid': 9999995,
          'executablePath': executablePath,
          'workingDirectory': r'E:\Tools\zapret2\bin',
          'arguments': ['--wf-tcp=80,443,12'],
        }),
        flush: true,
      );

      final service = ZapretRuntimeService(
        runningProcessLookupReader: (_) async => RunningProcessLookup.found(
          executablePath: executablePath,
          commandLine: '"$executablePath" --wf-tcp=80,443,12',
        ),
      );

      await service.cleanupOrphanedProcessForTesting(runtimeDir);

      expect(await markerFile.exists(), isFalse);
    },
  );

  test(
    'cleanupOrphanedProcessForTesting accepts quoted equals arguments with spaces',
    () async {
      final executablePath = r'E:\Program Files\Gorion Boost\bin\winws.exe';
      final markerFile = File(p.join(runtimeDir.path, 'runtime-process.json'));
      await markerFile.writeAsString(
        jsonEncode({
          'pid': 9999994,
          'executablePath': executablePath,
          'workingDirectory': r'E:\Program Files\Gorion Boost\bin',
          'arguments': ['--hostlist=profiles\\custom lists\\youtube.txt'],
        }),
        flush: true,
      );

      final service = ZapretRuntimeService(
        runningProcessLookupReader: (_) async => RunningProcessLookup.found(
          executablePath: executablePath,
          commandLine:
              '"$executablePath" --hostlist="profiles\\custom lists\\youtube.txt"',
        ),
      );

      await service.cleanupOrphanedProcessForTesting(runtimeDir);

      expect(await markerFile.exists(), isFalse);
    },
  );
}
