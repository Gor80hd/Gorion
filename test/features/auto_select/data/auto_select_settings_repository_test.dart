import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/auto_select/data/auto_select_settings_repository.dart';
import 'package:gorion_clean/features/auto_select/model/auto_select_state.dart';

void main() {
  late Directory tempDir;
  late AutoSelectSettingsRepository repository;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('gorion-auto-select-');
    repository = AutoSelectSettingsRepository(
      storageRootLoader: () async => tempDir,
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('persists settings, exclusions, and recent caches', () async {
    await repository.saveSettings(
      const AutoSelectSettings(
        enabled: false,
        checkIp: false,
        domainProbeUrl: 'https://probe.example.com/204',
        ipProbeUrl: 'http://9.9.9.9',
      ),
    );
    await repository.updateExcludedServer(
      profileId: 'profile-1',
      serverTag: 'server-a',
      excluded: true,
    );
    await repository.setRecentAutoSelectedServer(
      profileId: 'profile-1',
      serverTag: 'server-b',
    );
    await repository.setRecentSuccessfulAutoConnect(
      profileId: 'profile-1',
      serverTag: 'server-c',
    );

    final loaded = await repository.loadState();

    expect(loaded.settings.enabled, isFalse);
    expect(loaded.settings.checkIp, isFalse);
    expect(loaded.settings.domainProbeUrl, 'https://probe.example.com/204');
    expect(loaded.settings.ipProbeUrl, 'http://9.9.9.9');
    expect(loaded.settings.isExcluded('profile-1', 'server-a'), isTrue);
    expect(
      loaded.recentAutoSelectedServer?.matchesProfile('profile-1'),
      isTrue,
    );
    expect(
      loaded.recentSuccessfulAutoConnect?.matchesProfile('profile-1'),
      isTrue,
    );
  });

  test('clearExpiredCaches removes inactive entries', () async {
    await repository.setRecentAutoSelectedServer(
      profileId: 'profile-1',
      serverTag: 'server-a',
      ttl: const Duration(seconds: -1),
    );
    await repository.setRecentSuccessfulAutoConnect(
      profileId: 'profile-1',
      serverTag: 'server-b',
      ttl: const Duration(seconds: -1),
    );

    final cleared = await repository.clearExpiredCaches();

    expect(cleared.recentAutoSelectedServer, isNull);
    expect(cleared.recentSuccessfulAutoConnect, isNull);
  });
}
