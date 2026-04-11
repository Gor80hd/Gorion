import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/runtime/data/singbox_runtime_support.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory runtimeRoot;

  setUp(() async {
    runtimeRoot = await Directory.systemTemp.createTemp(
      'gorion-runtime-cleanup-test-',
    );
  });

  tearDown(() async {
    if (await runtimeRoot.exists()) {
      await runtimeRoot.delete(recursive: true);
    }
  });

  test(
    'deletes stale detached runtimes and prunes empty benchmark scopes',
    () async {
      final now = DateTime.utc(2026, 4, 11, 12);
      final staleTime = now.subtract(const Duration(minutes: 45));

      final staleBenchmark = await _createDetachedRuntime(
        runtimeRoot,
        ['benchmark', 'batch', '1775411113398049'],
        modifiedAt: staleTime,
        files: const ['config.json', 'sing-box.exe', 'sing-box.version'],
      );

      await cleanupStaleDetachedRuntimeDirectories(runtimeRoot, now: now);

      expect(await staleBenchmark.exists(), isFalse);
      expect(
        await Directory(
          p.join(runtimeRoot.path, 'benchmark', 'batch'),
        ).exists(),
        isFalse,
      );
    },
  );

  test(
    'keeps fresh detached runtimes and unrelated runtime directories',
    () async {
      final now = DateTime.utc(2026, 4, 11, 12);
      final staleTime = now.subtract(const Duration(minutes: 45));
      final freshTime = now.subtract(const Duration(minutes: 2));

      final stalePreconnect = await _createDetachedRuntime(
        runtimeRoot,
        ['preconnect', 'old-probe'],
        modifiedAt: staleTime,
        files: const ['preconnect-config.json', 'sing-box.exe'],
      );
      final freshMaintain = await _createDetachedRuntime(
        runtimeRoot,
        ['maintain', 'fresh-probe'],
        modifiedAt: freshTime,
        files: const ['maintain-config.json', 'sing-box.exe'],
      );
      final zapretRuntime = await _createDetachedRuntime(
        runtimeRoot,
        ['zapret2'],
        modifiedAt: staleTime,
        files: const ['runtime-process.json', 'sing-box.exe'],
      );

      await cleanupStaleDetachedRuntimeDirectories(runtimeRoot, now: now);

      expect(await stalePreconnect.exists(), isFalse);
      expect(await freshMaintain.exists(), isTrue);
      expect(await zapretRuntime.exists(), isTrue);
    },
  );
}

Future<Directory> _createDetachedRuntime(
  Directory root,
  List<String> segments, {
  required DateTime modifiedAt,
  required List<String> files,
}) async {
  final directory = Directory(p.joinAll([root.path, ...segments]));
  await directory.create(recursive: true);
  for (final name in files) {
    final file = File(p.join(directory.path, name));
    await file.writeAsString(name, flush: true);
    await file.setLastModified(modifiedAt);
  }
  return directory;
}
