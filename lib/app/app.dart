import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/app/theme_preferences.dart';
import 'package:gorion_clean/app/theme_settings.dart';
import 'package:gorion_clean/app/shell.dart';
import 'package:gorion_clean/app/theme.dart';
import 'package:gorion_clean/core/windows/elevation_relaunch_prompt_service.dart';
import 'package:gorion_clean/features/home/widget/home_page.dart';

class GorionApp extends ConsumerWidget {
  const GorionApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeSettings = ref.watch(appThemeSettingsProvider);
    final navigatorKey = ref.watch(rootNavigatorKeyProvider);

    return MaterialApp(
      navigatorKey: navigatorKey,
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
      home: const AppShell(child: HomePage(animateOnMount: false)),
    );
  }
}
