import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/app/app_router.dart';
import 'package:gorion_clean/app/theme_preferences.dart';
import 'package:gorion_clean/app/theme_settings.dart';
import 'package:gorion_clean/app/theme.dart';

class GorionApp extends ConsumerWidget {
  const GorionApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeSettings = ref.watch(appThemeSettingsProvider);
    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      routerConfig: router,
      title: 'gorion',
      debugShowCheckedModeBanner: false,
      theme: buildGorionTheme(
        brightness: Brightness.light,
        palette: themeSettings.palette,
      ),
      darkTheme: buildGorionTheme(
        brightness: Brightness.dark,
        palette: themeSettings.palette,
      ),
      themeMode: themeSettings.mode.materialThemeMode,
    );
  }
}
