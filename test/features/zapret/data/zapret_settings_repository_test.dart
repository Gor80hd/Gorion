import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/zapret/data/zapret_settings_repository.dart';
import 'package:gorion_clean/features/zapret/model/zapret_models.dart';
import 'package:gorion_clean/features/zapret/model/zapret_settings.dart';

void main() {
  late Directory tempDir;
  late ZapretSettingsRepository repository;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('gorion-zapret-settings-');
    repository = ZapretSettingsRepository(
      storageRootLoader: () async => tempDir,
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('persists zapret settings across repository instances', () async {
    const savedSettings = ZapretSettings(
      installDirectory: r'E:\Tools\zapret2',
      preset: ZapretPreset.combined,
      strategyProfile: ZapretStrategyProfile.combinedStrong,
      customProfile: ZapretCustomProfile(
        youtubeVariant: ZapretFlowsealVariant.multisplit,
        discordVariant: ZapretFlowsealVariant.hostfakesplit,
        genericVariant: ZapretFlowsealVariant.multidisorder,
      ),
      gameFilterEnabled: true,
      ipSetFilterMode: ZapretIpSetFilterMode.any,
      startOnAppLaunch: true,
      autoStopOnTun: true,
    );

    await repository.save(savedSettings);
    final loaded = await repository.load();

    expect(loaded, savedSettings);

    final restartedRepository = ZapretSettingsRepository(
      storageRootLoader: () async => tempDir,
    );
    final restartedLoaded = await restartedRepository.load();

    expect(restartedLoaded, savedSettings);
  });

  test('defaults autoStopOnTun to true for older saved state', () async {
    final stateFile = File(
      '${tempDir.path}${Platform.pathSeparator}zapret-settings.json',
    );
    await stateFile.writeAsString(
      '{"installDirectory":"C:/zapret2","preset":"discord","startOnAppLaunch":true}',
    );

    final loaded = await repository.load();

    expect(loaded.installDirectory, 'C:/zapret2');
    expect(loaded.preset, ZapretPreset.discord);
    expect(loaded.strategyProfile, isNull);
    expect(loaded.gameFilterEnabled, isFalse);
    expect(loaded.ipSetFilterMode, ZapretIpSetFilterMode.none);
    expect(loaded.startOnAppLaunch, isTrue);
    expect(loaded.autoStopOnTun, isTrue);
  });
}
