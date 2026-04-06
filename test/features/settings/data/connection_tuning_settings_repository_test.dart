import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/settings/data/connection_tuning_settings_repository.dart';
import 'package:gorion_clean/features/settings/model/connection_tuning_settings.dart';
import 'package:gorion_clean/features/settings/model/split_tunnel_settings.dart';

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
        splitTunnel: SplitTunnelSettings(
          enabled: true,
          geositeTags: ['cn', 'apple'],
          geoipTags: ['private', 'cn'],
          domainSuffixes: ['local', 'lan'],
          ipCidrs: ['10.0.0.0/8'],
          customRuleSets: [
            SplitTunnelCustomRuleSet(
              id: 'corp-routes',
              label: 'Corp routes',
              source: SplitTunnelRuleSetSource.remote,
              url: 'https://example.com/corp.srs',
            ),
          ],
          remoteUpdateInterval: '12h',
          remoteRevision: 42,
        ),
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
