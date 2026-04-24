import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/features/settings/application/desktop_settings_controller.dart';
import 'package:gorion_clean/features/settings/data/launch_at_startup_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final appSettingsResetServiceProvider = Provider<AppSettingsResetService>(
  (ref) => AppSettingsResetService(
    launchAtStartupService: ref.read(launchAtStartupServiceProvider),
  ),
);

class AppSettingsResetService {
  AppSettingsResetService({
    required LaunchAtStartupService launchAtStartupService,
    Future<Directory> Function()? storageRootLoader,
  }) : _launchAtStartupService = launchAtStartupService,
       _storageRootLoader = storageRootLoader ?? _defaultStorageRoot;

  static const managedFileNames = <String>[
    'theme-settings.json',
    'desktop-settings.json',
    'connection-settings.json',
    'auto-select.json',
    'zapret-settings.json',
    'server-sort-mode.json',
    'server-favorites.json',
  ];

  final LaunchAtStartupService _launchAtStartupService;
  final Future<Directory> Function() _storageRootLoader;

  Future<void> resetAll() async {
    final disabled = await _launchAtStartupService.setEnabled(false);
    if (!disabled) {
      throw StateError('Не удалось отключить автозапуск приложения.');
    }

    final root = await _storageRootLoader();
    for (final fileName in managedFileNames) {
      final file = File(p.join(root.path, fileName));
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  static Future<Directory> _defaultStorageRoot() async {
    final appDir = await getApplicationSupportDirectory();
    final root = Directory(p.join(appDir.path, 'gorion'));
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    return root;
  }
}
