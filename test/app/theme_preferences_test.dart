import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/app/theme_preferences.dart';
import 'package:gorion_clean/app/theme_settings.dart';

void main() {
  group('AppThemeSettings defaults', () {
    test('use dark mode when no stored preference exists', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'gorion-theme-settings-',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final repository = AppThemeSettingsRepository(
        storageRootLoader: () async => tempDir,
      );

      final loaded = await repository.load();

      expect(loaded.mode, AppThemeModePreference.dark);
    });

    test('ignores legacy palette key when stored json has no mode', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'gorion-theme-settings-',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final stateFile = File(
        '${tempDir.path}${Platform.pathSeparator}theme-settings.json',
      );
      await stateFile.writeAsString('''{
  "palette": "rose"
}''');

      final repository = AppThemeSettingsRepository(
        storageRootLoader: () async => tempDir,
      );

      final loaded = await repository.load();

      expect(loaded.mode, AppThemeModePreference.dark);
    });
  });
}
