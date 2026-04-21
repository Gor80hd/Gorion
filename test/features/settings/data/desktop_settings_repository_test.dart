import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/settings/data/desktop_settings_repository.dart';
import 'package:gorion_clean/features/settings/model/desktop_settings.dart';

void main() {
  late Directory tempDir;
  late DesktopSettingsRepository repository;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('gorion-desktop-settings-');
    repository = DesktopSettingsRepository(
      storageRootLoader: () async => tempDir,
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('persists desktop settings across repository instances', () async {
    const savedSettings = DesktopSettings(
      launchMinimized: true,
      keepRunningInTrayOnClose: false,
      autoConnectOnLaunch: true,
      launchAtStartupPriority: LaunchAtStartupPriority.first,
    );

    await repository.save(savedSettings);
    final loaded = await repository.load();

    expect(loaded, savedSettings);

    final restartedRepository = DesktopSettingsRepository(
      storageRootLoader: () async => tempDir,
    );
    final restartedLoaded = await restartedRepository.load();

    expect(restartedLoaded, savedSettings);
  });

  test(
    'defaults keepRunningInTrayOnClose to true for older saved state',
    () async {
      final stateFile = File(
        '${tempDir.path}${Platform.pathSeparator}desktop-settings.json',
      );
      await stateFile.writeAsString(
        '{"launchMinimized":true,"autoConnectOnLaunch":false}',
      );

      final loaded = await repository.load();

      expect(loaded.launchMinimized, isTrue);
      expect(loaded.keepRunningInTrayOnClose, isTrue);
      expect(loaded.autoConnectOnLaunch, isFalse);
      expect(loaded.launchAtStartupPriority, LaunchAtStartupPriority.standard);
    },
  );
}
