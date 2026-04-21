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
      final launchAtStartupService = _FakeLaunchAtStartupService(
        enabled: true,
        priority: LaunchAtStartupPriority.first,
      );
      final controller = DesktopSettingsController(
        repository: repository,
        launchAtStartupService: launchAtStartupService,
        initialState: const DesktopSettingsState(
          launchAtStartupEnabled: true,
          settings: DesktopSettings(
            launchMinimized: true,
            launchAtStartupPriority: LaunchAtStartupPriority.first,
          ),
        ),
      );

      await controller.setLaunchAtStartupEnabled(false);

      expect(controller.state.launchAtStartupEnabled, isFalse);
      expect(controller.state.settings.launchMinimized, isFalse);
      expect(
        controller.state.settings.launchAtStartupPriority,
        LaunchAtStartupPriority.first,
      );
      expect((await repository.load()).launchMinimized, isFalse);
      expect(launchAtStartupService.setEnabledCalls, [
        (enabled: false, priority: LaunchAtStartupPriority.first),
      ]);
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

    test(
      'changing autostart priority re-registers startup and persists setting',
      () async {
        final repository = DesktopSettingsRepository(
          storageRootLoader: () async => tempDir,
        );
        final launchAtStartupService = _FakeLaunchAtStartupService(
          enabled: true,
        );
        final controller = DesktopSettingsController(
          repository: repository,
          launchAtStartupService: launchAtStartupService,
          initialState: const DesktopSettingsState(
            launchAtStartupEnabled: true,
          ),
        );

        await controller.setLaunchAtStartupPriority(
          LaunchAtStartupPriority.first,
        );

        expect(
          controller.state.settings.launchAtStartupPriority,
          LaunchAtStartupPriority.first,
        );
        expect(
          (await repository.load()).launchAtStartupPriority,
          LaunchAtStartupPriority.first,
        );
        expect(launchAtStartupService.setEnabledCalls, [
          (enabled: true, priority: LaunchAtStartupPriority.first),
        ]);
      },
    );
  });
}

class _FakeLaunchAtStartupService implements LaunchAtStartupService {
  _FakeLaunchAtStartupService({
    required this.enabled,
    this.priority = LaunchAtStartupPriority.standard,
  });

  bool enabled;
  LaunchAtStartupPriority priority;
  final List<({bool enabled, LaunchAtStartupPriority priority})>
  setEnabledCalls = <({bool enabled, LaunchAtStartupPriority priority})>[];

  @override
  Future<bool> isEnabled() async {
    return enabled;
  }

  @override
  Future<LaunchAtStartupPriority> getPriority() async {
    return priority;
  }

  @override
  Future<bool> setEnabled(
    bool enabled, {
    LaunchAtStartupPriority priority = LaunchAtStartupPriority.standard,
  }) async {
    setEnabledCalls.add((enabled: enabled, priority: priority));
    this.enabled = enabled;
    if (enabled) {
      this.priority = priority;
    }
    return true;
  }
}
