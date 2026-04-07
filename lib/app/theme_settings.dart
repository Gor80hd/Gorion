import 'package:flutter/material.dart';

enum AppThemeModePreference { system, light, dark }

enum AppThemePalette { emerald, ocean, amber, rose }

AppThemeModePreference appThemeModePreferenceFromStorageValue(String? value) {
  return switch (value) {
    'light' => AppThemeModePreference.light,
    'dark' => AppThemeModePreference.dark,
    _ => AppThemeModePreference.dark,
  };
}

AppThemePalette appThemePaletteFromStorageValue(String? value) {
  return switch (value) {
    'ocean' => AppThemePalette.ocean,
    'amber' => AppThemePalette.amber,
    'rose' => AppThemePalette.rose,
    _ => AppThemePalette.emerald,
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
      AppThemeModePreference.system => 'Следует системной теме устройства.',
      AppThemeModePreference.light => 'Светлая палитра интерфейса.',
      AppThemeModePreference.dark => 'Тёмная палитра интерфейса.',
    };
  }
}

extension AppThemePaletteX on AppThemePalette {
  String get storageValue => name;

  String get title {
    return switch (this) {
      AppThemePalette.emerald => 'Gorion',
      AppThemePalette.ocean => 'Ocean',
      AppThemePalette.amber => 'Amber',
      AppThemePalette.rose => 'Rose',
    };
  }

  String get description {
    return switch (this) {
      AppThemePalette.emerald => 'Фирменная зелёная палитра Gorion.',
      AppThemePalette.ocean => 'Холодные сине-бирюзовые акценты.',
      AppThemePalette.amber => 'Тёплые янтарные акценты.',
      AppThemePalette.rose => 'Мягкие розово-красные акценты.',
    };
  }
}

class AppThemeSettings {
  const AppThemeSettings({
    this.mode = AppThemeModePreference.dark,
    this.palette = AppThemePalette.emerald,
  });

  final AppThemeModePreference mode;
  final AppThemePalette palette;

  AppThemeSettings copyWith({
    AppThemeModePreference? mode,
    AppThemePalette? palette,
  }) {
    return AppThemeSettings(
      mode: mode ?? this.mode,
      palette: palette ?? this.palette,
    );
  }

  Map<String, dynamic> toJson() {
    return {'mode': mode.storageValue, 'palette': palette.storageValue};
  }

  factory AppThemeSettings.fromJson(Map<String, dynamic> json) {
    return AppThemeSettings(
      mode: appThemeModePreferenceFromStorageValue(json['mode']?.toString()),
      palette: appThemePaletteFromStorageValue(json['palette']?.toString()),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AppThemeSettings &&
        other.mode == mode &&
        other.palette == palette;
  }

  @override
  int get hashCode => Object.hash(mode, palette);
}
