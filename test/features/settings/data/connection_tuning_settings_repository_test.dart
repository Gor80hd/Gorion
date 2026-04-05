import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/settings/data/connection_tuning_settings_repository.dart';
import 'package:gorion_clean/features/settings/model/connection_tuning_settings.dart';

void main() {
  late Directory tempDir;
  late ConnectionTuningSettingsRepository repository;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'gorion-connection-settings-',
    );
    repository = ConnectionTuningSettingsRepository(
      storageRootLoader: () async => tempDir,
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'persists connection tuning settings across repository instances',
    () async {
      const savedSettings = ConnectionTuningSettings(
        forceChromeUtls: true,
        sniDonor: 'cdn.example.com',
        forceVisionFlow: true,
        forceXudpPacketEncoding: true,
        enableMultiplex: true,
        enableTlsRecordFragment: true,
      );

      await repository.save(savedSettings);
      final loaded = await repository.load();

      expect(loaded, savedSettings);

      final restartedRepository = ConnectionTuningSettingsRepository(
        storageRootLoader: () async => tempDir,
      );
      final restartedLoaded = await restartedRepository.load();

      expect(restartedLoaded, savedSettings);
    },
  );
}
