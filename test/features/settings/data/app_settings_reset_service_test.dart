import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/app/theme_preferences.dart';
import 'package:gorion_clean/app/theme_settings.dart';
import 'package:gorion_clean/features/auto_select/data/auto_select_settings_repository.dart';
import 'package:gorion_clean/features/auto_select/model/auto_select_state.dart';
import 'package:gorion_clean/features/home/data/server_sort_mode_settings_repository.dart';
import 'package:gorion_clean/features/home/model/server_sort_mode.dart';
import 'package:gorion_clean/features/settings/data/app_settings_reset_service.dart';
import 'package:gorion_clean/features/settings/data/connection_tuning_settings_repository.dart';
import 'package:gorion_clean/features/settings/data/desktop_settings_repository.dart';
import 'package:gorion_clean/features/settings/data/launch_at_startup_service.dart';
import 'package:gorion_clean/features/settings/model/connection_tuning_settings.dart';
import 'package:gorion_clean/features/settings/model/desktop_settings.dart';
import 'package:gorion_clean/features/zapret/data/zapret_settings_repository.dart';
import 'package:gorion_clean/features/zapret/model/zapret_settings.dart';
import 'package:path/path.dart' as p;

void main() {
  group('AppSettingsResetService', () {
    late Directory tempDir;

    Future<Directory> loadTempRoot() async => tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('gorion-settings-reset-');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'removes managed settings files and leaves unrelated data untouched',
      () async {
        final launchAtStartup = _FakeLaunchAtStartupService(enabled: true);

        await AppThemeSettingsRepository(storageRootLoader: loadTempRoot).save(
          const AppThemeSettings(
            mode: AppThemeModePreference.light,
            palette: AppThemePalette.rose,
          ),
        );
        await DesktopSettingsRepository(storageRootLoader: loadTempRoot).save(
          const DesktopSettings(
            launchMinimized: true,
            autoConnectOnLaunch: true,
          ),
        );
        await ConnectionTuningSettingsRepository(
          storageRootLoader: loadTempRoot,
        ).save(
          const ConnectionTuningSettings(
            forceChromeUtls: true,
            enableMultiplex: true,
          ),
        );
        await AutoSelectSettingsRepository(
          storageRootLoader: loadTempRoot,
        ).saveSettings(
          const AutoSelectSettings(
            enabled: false,
            excludedServerKeys: ['profile-a:server-b'],
          ),
        );
        await ZapretSettingsRepository(storageRootLoader: loadTempRoot).save(
          const ZapretSettings(
            installDirectory: 'C:\\zapret',
            startOnAppLaunch: true,
          ),
        );
        await ServerSortModeSettingsRepository(
          storageRootLoader: loadTempRoot,
        ).save(ServerSortMode.alpha);

        final profilesFile = File(p.join(tempDir.path, 'profiles.json'));
        await profilesFile.writeAsString('keep-me');

        final service = AppSettingsResetService(
          launchAtStartupService: launchAtStartup,
          storageRootLoader: loadTempRoot,
        );

        await service.resetAll();

        for (final fileName in AppSettingsResetService.managedFileNames) {
          expect(File(p.join(tempDir.path, fileName)).existsSync(), isFalse);
        }
        expect(await profilesFile.readAsString(), 'keep-me');
        expect(launchAtStartup.enabled, isFalse);
        expect(launchAtStartup.setEnabledCalls, [false]);
      },
    );

    test('stops before deleting files when autostart disable fails', () async {
      final themeRepository = AppThemeSettingsRepository(
        storageRootLoader: loadTempRoot,
      );
      await themeRepository.save(
        const AppThemeSettings(mode: AppThemeModePreference.light),
      );

      final service = AppSettingsResetService(
        launchAtStartupService: _FakeLaunchAtStartupService(
          enabled: true,
          allowDisable: false,
        ),
        storageRootLoader: loadTempRoot,
      );

      await expectLater(service.resetAll(), throwsStateError);
      expect(
        File(p.join(tempDir.path, 'theme-settings.json')).existsSync(),
        isTrue,
      );
    });
  });
}

class _FakeLaunchAtStartupService implements LaunchAtStartupService {
  _FakeLaunchAtStartupService({
    required this.enabled,
    this.allowDisable = true,
  });

  bool enabled;
  final bool allowDisable;
  final List<bool> setEnabledCalls = <bool>[];

  @override
  Future<bool> isEnabled() async {
    return enabled;
  }

  @override
  Future<LaunchAtStartupPriority> getPriority() async {
    return LaunchAtStartupPriority.standard;
  }

  @override
  Future<bool> setEnabled(
    bool enabled, {
    LaunchAtStartupPriority priority = LaunchAtStartupPriority.standard,
  }) async {
    setEnabledCalls.add(enabled);
    if (enabled == false && !allowDisable) {
      return false;
    }
    this.enabled = enabled;
    return true;
  }
}
