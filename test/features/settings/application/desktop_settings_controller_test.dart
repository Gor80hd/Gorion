import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/settings/application/desktop_settings_controller.dart';
import 'package:gorion_clean/features/settings/data/desktop_settings_repository.dart';
import 'package:gorion_clean/features/settings/data/launch_at_startup_service.dart';
import 'package:gorion_clean/features/settings/model/desktop_settings.dart';

void main() {
  group('DesktopSettingsController', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'gorion-desktop-controller-',
      );
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('disabling autostart clears launchMinimized state', () async {
      final repository = DesktopSettingsRepository(
        storageRootLoader: () async => tempDir,
      );
      final controller = DesktopSettingsController(
        repository: repository,
        launchAtStartupService: _FakeLaunchAtStartupService(enabled: true),
        initialState: const DesktopSettingsState(
          launchAtStartupEnabled: true,
          settings: DesktopSettings(launchMinimized: true),
        ),
      );

      await controller.setLaunchAtStartupEnabled(false);

      expect(controller.state.launchAtStartupEnabled, isFalse);
      expect(controller.state.settings.launchMinimized, isFalse);
      expect((await repository.load()).launchMinimized, isFalse);
    });

    test(
      'cannot persist launchMinimized while autostart is disabled',
      () async {
        final repository = DesktopSettingsRepository(
          storageRootLoader: () async => tempDir,
        );
        final controller = DesktopSettingsController(
          repository: repository,
          launchAtStartupService: _FakeLaunchAtStartupService(enabled: false),
          initialState: const DesktopSettingsState(),
        );

        await controller.setLaunchMinimized(true);

        expect(controller.state.settings.launchMinimized, isFalse);
        expect((await repository.load()).launchMinimized, isFalse);
      },
    );
  });
}

class _FakeLaunchAtStartupService implements LaunchAtStartupService {
  _FakeLaunchAtStartupService({required this.enabled});

  bool enabled;

  @override
  Future<bool> isEnabled() async {
    return enabled;
  }

  @override
  Future<bool> setEnabled(bool enabled) async {
    this.enabled = enabled;
    return true;
  }
}
