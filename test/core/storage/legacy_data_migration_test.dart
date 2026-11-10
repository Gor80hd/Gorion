import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion/core/storage/legacy_data_migration.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory legacy;
  late Directory current;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('gorion-migration-');
    legacy = Directory(p.join(root.path, 'com.example', 'gorion_clean'));
    current = Directory(p.join(root.path, 'Gorion', 'Gorion'));
  });

  tearDown(() => root.delete(recursive: true));

  Future<void> writeLegacyProfile() async {
    final file = File(p.join(legacy.path, 'gorion', 'profiles', 'a.json'));
    await file.create(recursive: true);
    await file.writeAsString('legacy');
  }

  test('moves legacy data into an empty current directory', () async {
    await writeLegacyProfile();

    final moved = await migrateLegacyAppData(
      legacySupportDir: legacy,
      currentSupportDir: current,
    );

    expect(moved, isTrue);
    expect(
      await File(
        p.join(current.path, 'gorion', 'profiles', 'a.json'),
      ).readAsString(),
      'legacy',
    );
    expect(await Directory(p.join(legacy.path, 'gorion')).exists(), isFalse);
  });

  test('never overwrites data that already exists', () async {
    await writeLegacyProfile();
    final existing = File(p.join(current.path, 'gorion', 'profiles', 'a.json'));
    await existing.create(recursive: true);
    await existing.writeAsString('current');

    final moved = await migrateLegacyAppData(
      legacySupportDir: legacy,
      currentSupportDir: current,
    );

    expect(moved, isFalse);
    expect(await existing.readAsString(), 'current');
    expect(await Directory(p.join(legacy.path, 'gorion')).exists(), isTrue);
  });

  test('does nothing without legacy data', () async {
    final moved = await migrateLegacyAppData(
      legacySupportDir: legacy,
      currentSupportDir: current,
    );

    expect(moved, isFalse);
    expect(await Directory(p.join(current.path, 'gorion')).exists(), isFalse);
  });
}
