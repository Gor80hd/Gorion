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

  test(
    'uses enabled game filter by default when no state file exists',
    () async {
      final loaded = await repository.load();

      expect(loaded.gameFilterEnabled, isTrue);
      expect(loaded.gameFilterMode, ZapretGameFilterMode.all);
    },
  );

  test('persists zapret settings across repository instances', () async {
    final savedSettings = ZapretSettings(
      installDirectory: r'E:\Tools\zapret2',
      configFileName: 'general (ALT10).conf',
      gameFilterMode: ZapretGameFilterMode.tcp,
      preset: ZapretPreset.combined,
      strategyProfile: ZapretStrategyProfile.combinedStrong,
      customProfile: ZapretCustomProfile(
        youtubeVariant: ZapretFlowsealVariant.multisplit,
        discordVariant: ZapretFlowsealVariant.hostfakesplit,
        genericVariant: ZapretFlowsealVariant.multidisorder,
      ),
      ipSetFilterMode: ZapretIpSetFilterMode.any,
      startOnAppLaunch: true,
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

  test(
    'defaults autoStopOnTun to true and enables game filter for older saved state',
    () async {
      final stateFile = File(
        '${tempDir.path}${Platform.pathSeparator}zapret-settings.json',
      );
      await stateFile.writeAsString(
        '{"installDirectory":"C:/zapret2","preset":"discord","startOnAppLaunch":true}',
      );

      final loaded = await repository.load();

      expect(loaded.installDirectory, 'C:/zapret2');
      expect(loaded.effectiveConfigFileName, 'general.conf');
      expect(loaded.preset, ZapretPreset.discord);
      expect(loaded.strategyProfile, isNull);
      expect(loaded.gameFilterEnabled, isTrue);
      expect(loaded.gameFilterMode, ZapretGameFilterMode.all);
      expect(loaded.ipSetFilterMode, ZapretIpSetFilterMode.none);
      expect(loaded.startOnAppLaunch, isTrue);
      expect(loaded.autoStopOnTun, isTrue);
    },
  );

  test('forces autoStopOnTun back to true for legacy disabled state', () async {
    final stateFile = File(
      '${tempDir.path}${Platform.pathSeparator}zapret-settings.json',
    );
    await stateFile.writeAsString(
      '{"installDirectory":"C:/zapret2","autoStopOnTun":false}',
    );

    final loaded = await repository.load();

    expect(loaded.installDirectory, 'C:/zapret2');
    expect(loaded.autoStopOnTun, isTrue);
  });

  test(
    'loads legacy customProfile variant keys as enabled block profiles',
    () async {
      final stateFile = File(
        '${tempDir.path}${Platform.pathSeparator}zapret-settings.json',
      );
      await stateFile.writeAsString('''
      {
        "installDirectory":"C:/zapret2",
        "customProfile":{
          "youtubeVariant":"multisplit",
          "discordVariant":"simplefake",
          "genericVariant":"simplefake-maxru"
        }
      }
      ''');

      final loaded = await repository.load();

      expect(loaded.customProfile?.youtubeEnabled, isTrue);
      expect(
        loaded.customProfile?.youtubeVariant,
        ZapretFlowsealVariant.multisplit,
      );
      expect(loaded.customProfile?.discordEnabled, isTrue);
      expect(
        loaded.customProfile?.genericVariant,
        ZapretFlowsealVariant.simpleFakeMaxRu,
      );
    },
  );
}
