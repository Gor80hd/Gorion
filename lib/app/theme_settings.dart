import 'package:flutter/material.dart';

enum AppThemeModePreference { system, light, dark }

AppThemeModePreference appThemeModePreferenceFromStorageValue(String? value) {
  return switch (value) {
    'light' => AppThemeModePreference.light,
    'dark' => AppThemeModePreference.dark,
    _ => AppThemeModePreference.dark,
  };
}

extension AppThemeModePreferenceX on AppThemeModePreference {
  String get storageValue => name;

  ThemeMode get materialThemeMode {
    return switch (this) {
      AppThemeModePreference.system => ThemeMode.system,
      AppThemeModePreference.light => ThemeMode.light,
      AppThemeModePreference.dark => ThemeMode.dark,
    };
  }

  String get title {
    return switch (this) {
      AppThemeModePreference.system => 'Системная',
      AppThemeModePreference.light => 'Светлая',
      AppThemeModePreference.dark => 'Тёмная',
    };
  }

  String get description {
    return switch (this) {
      AppThemeModePreference.system => 'Следует теме устройства',
      AppThemeModePreference.light => 'Всегда светлый интерфейс',
      AppThemeModePreference.dark => 'Всегда тёмный интерфейс',
    };
  }

  IconData get icon {
    return switch (this) {
      AppThemeModePreference.system => Icons.brightness_auto_rounded,
      AppThemeModePreference.light => Icons.light_mode_rounded,
      AppThemeModePreference.dark => Icons.dark_mode_rounded,
    };
  }
}

class AppThemeSettings {
  const AppThemeSettings({this.mode = AppThemeModePreference.dark});

  final AppThemeModePreference mode;

  AppThemeSettings copyWith({AppThemeModePreference? mode}) {
    return AppThemeSettings(mode: mode ?? this.mode);
  }

  Map<String, dynamic> toJson() {
    return {'mode': mode.storageValue};
  }

  factory AppThemeSettings.fromJson(Map<String, dynamic> json) {
    // Поле palette из старых версий игнорируется: остались две темы.
    return AppThemeSettings(
      mode: appThemeModePreferenceFromStorageValue(json['mode']?.toString()),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AppThemeSettings && other.mode == mode;
  }

  @override
  int get hashCode => mode.hashCode;
}
