import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

ThemeData buildGorionTheme() {
  const canvas = Color(0xFFF4F0E8);
  const surface = Color(0xFFFFFBF3);
  const ink = Color(0xFF18211E);
  const accent = Color(0xFF0E6C66);
  const accentSoft = Color(0xFFBDE4D7);
  const warm = Color(0xFFCB8A45);

  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: Brightness.light,
    surface: surface,
  ).copyWith(
    primary: accent,
    secondary: warm,
    tertiary: accentSoft,
    onSurface: ink,
    surface: surface,
    outline: const Color(0xFFB4B0A6),
  );

  final baseText = GoogleFonts.ibmPlexSansTextTheme();

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: canvas,
    textTheme: baseText.copyWith(
      headlineLarge: baseText.headlineLarge?.copyWith(
        fontWeight: FontWeight.w700,
        color: ink,
        letterSpacing: -1.2,
      ),
      titleLarge: baseText.titleLarge?.copyWith(
        fontWeight: FontWeight.w600,
        color: ink,
      ),
      titleMedium: baseText.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
        color: ink,
      ),
      bodyLarge: baseText.bodyLarge?.copyWith(color: ink),
      bodyMedium: baseText.bodyMedium?.copyWith(color: ink.withValues(alpha: 0.84)),
      labelLarge: baseText.labelLarge?.copyWith(fontWeight: FontWeight.w600),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: ink,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: Color(0xFFE0DBD1)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: accent, width: 1.4),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
        side: const BorderSide(color: Color(0xFFE4DED4)),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
    ),
    chipTheme: ChipThemeData(
      side: BorderSide.none,
      selectedColor: accentSoft,
      backgroundColor: const Color(0xFFEAE4D7),
      labelStyle: baseText.labelLarge ?? const TextStyle(),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
    ),
  );
}