import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/app/theme_settings.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final appThemeSettingsRepositoryProvider = Provider<AppThemeSettingsRepository>(
  (ref) => AppThemeSettingsRepository(),
);

final appThemeSettingsProvider =
    NotifierProvider<AppThemeSettingsNotifier, AppThemeSettings>(
      AppThemeSettingsNotifier.new,
    );

class AppThemeSettingsRepository {
  AppThemeSettingsRepository({Future<Directory> Function()? storageRootLoader})
    : _storageRootLoader = storageRootLoader ?? _defaultStorageRoot;

  final Future<Directory> Function() _storageRootLoader;

  Future<AppThemeSettings> load() async {
    final stateFile = await _stateFile();
    if (!await stateFile.exists()) {
      return const AppThemeSettings();
    }

    final content = await stateFile.readAsString();
    if (content.trim().isEmpty) {
      return const AppThemeSettings();
    }

    final decoded = jsonDecode(content);
    if (decoded is Map<String, dynamic>) {
      return AppThemeSettings.fromJson(decoded);
    }
    if (decoded is Map) {
      return AppThemeSettings.fromJson(
        Map<String, dynamic>.from(decoded.cast<String, dynamic>()),
      );
    }
    return const AppThemeSettings();
  }

  Future<AppThemeSettings> save(AppThemeSettings settings) async {
    final normalized = settings.copyWith();
    final stateFile = await _stateFile();
    await stateFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(normalized.toJson()),
    );
    return normalized;
  }

  Future<File> _stateFile() async {
    final root = await _storageRootLoader();
    return File(p.join(root.path, 'theme-settings.json'));
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

class AppThemeSettingsNotifier extends Notifier<AppThemeSettings> {
  bool _restoreScheduled = false;
  bool _hasLocalOverride = false;
  bool _alive = true;

  @override
  AppThemeSettings build() {
    _alive = true;
    ref.onDispose(() => _alive = false);
    if (!_restoreScheduled) {
      _restoreScheduled = true;
      unawaited(_restore());
    }
    return const AppThemeSettings();
  }

  Future<void> setMode(AppThemeModePreference mode) async {
    await _update(state.copyWith(mode: mode));
  }

  Future<void> setPalette(AppThemePalette palette) async {
    await _update(state.copyWith(palette: palette));
  }

  Future<void> _update(AppThemeSettings next) async {
    if (state == next) {
      return;
    }

    _hasLocalOverride = true;
    final previous = state;
    state = next;

    try {
      await ref.read(appThemeSettingsRepositoryProvider).save(next);
    } catch (_) {
      if (_alive) {
        state = previous;
      }
    }
  }

  Future<void> _restore() async {
    try {
      final stored = await ref.read(appThemeSettingsRepositoryProvider).load();
      if (_alive && !_hasLocalOverride) {
        state = stored;
      }
    } catch (_) {
      // Fall back to defaults when persisted theme settings are unavailable.
    }
  }
}
