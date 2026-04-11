import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/app/app.dart';
import 'package:gorion_clean/app/theme.dart';
import 'package:gorion_clean/core/windows/windows_elevation_service.dart';
import 'package:gorion_clean/features/settings/application/desktop_settings_controller.dart';
import 'package:gorion_clean/features/settings/data/desktop_settings_repository.dart';
import 'package:gorion_clean/features/settings/data/launch_at_startup_service.dart';
import 'package:window_manager/window_manager.dart';

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final appLaunchRequest = AppLaunchRequest.fromArgs(args);
  final launchAtStartupService = buildLaunchAtStartupService();
  final windowsElevationService = buildWindowsElevationService(
    currentArgs: args,
  );
  final desktopSettingsBootstrap = await loadDesktopSettingsBootstrap(
    repository: DesktopSettingsRepository(),
    launchAtStartupService: launchAtStartupService,
  );

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1280, 800),
      minimumSize: Size(900, 560),
      center: true,
      title: 'gorion',
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: gorionDefaultWindowBackground,
      skipTaskbar: false,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      if (Platform.isWindows &&
          desktopSettingsBootstrap.effectiveLaunchMinimized &&
          !appLaunchRequest.resumesAfterElevation) {
        await windowManager.hide();
      } else {
        await windowManager.show();
        await windowManager.focus();
      }
    });
  }

  runApp(
    ProviderScope(
      overrides: [
        desktopSettingsBootstrapProvider.overrideWithValue(
          desktopSettingsBootstrap,
        ),
        appLaunchRequestProvider.overrideWithValue(appLaunchRequest),
        launchAtStartupServiceProvider.overrideWithValue(
          launchAtStartupService,
        ),
        windowsElevationServiceProvider.overrideWithValue(
          windowsElevationService,
        ),
      ],
      child: const GorionApp(),
    ),
  );
}
