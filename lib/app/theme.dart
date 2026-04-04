import 'package:flutter/material.dart';

const gorionBackgroundStart = Color(0xFF000000);
const gorionBackgroundEnd = Color(0xFF00140C);
const gorionCanvas = Color(0xFF06110B);
const gorionSurface = Color(0xFF101B16);
const gorionSurfaceVariant = Color(0xFF172721);
const gorionOnSurface = Color(0xFFE7F6EF);
const gorionOnSurfaceMuted = Color(0xFF7FA395);
const gorionAccent = Color(0xFF1EFFAC);
const gorionAccentDim = Color(0xFF0E865E);

const gorionAppBackgroundGradient = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [gorionBackgroundStart, gorionBackgroundEnd],
);

ThemeData buildGorionTheme() {
  const canvas = gorionCanvas;
  const surface = gorionSurface;
  const surfaceVariant = gorionSurfaceVariant;
  const onSurface = gorionOnSurface;
  const onSurfaceMuted = gorionOnSurfaceMuted;
  const accent = gorionAccent;
  const accentDim = gorionAccentDim;

  const fontFamily = 'IBMPlexSans';

  final scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: accent,
    onPrimary: canvas,
    secondary: accentDim,
    onSecondary: onSurface,
    tertiary: const Color(0xFF6366F1),
    onTertiary: onSurface,
    error: const Color(0xFFEF4444),
    onError: onSurface,
    surface: surface,
    onSurface: onSurface,
    surfaceContainerHighest: surfaceVariant,
    outline: const Color(0xFF274439),
    outlineVariant: const Color(0xFF1A3128),
  );

  const baseTextStyle = TextStyle(fontFamily: fontFamily, color: onSurface);

  final textTheme = TextTheme(
    displayLarge: baseTextStyle.copyWith(
      fontSize: 57,
      fontWeight: FontWeight.w700,
      letterSpacing: -1.5,
    ),
    displayMedium: baseTextStyle.copyWith(
      fontSize: 45,
      fontWeight: FontWeight.w700,
      letterSpacing: -1.0,
    ),
    displaySmall: baseTextStyle.copyWith(
      fontSize: 36,
      fontWeight: FontWeight.w600,
    ),
    headlineLarge: baseTextStyle.copyWith(
      fontSize: 32,
      fontWeight: FontWeight.w700,
      letterSpacing: -1.0,
    ),
    headlineMedium: baseTextStyle.copyWith(
      fontSize: 28,
      fontWeight: FontWeight.w600,
    ),
    headlineSmall: baseTextStyle.copyWith(
      fontSize: 24,
      fontWeight: FontWeight.w600,
    ),
    titleLarge: baseTextStyle.copyWith(
      fontSize: 22,
      fontWeight: FontWeight.w600,
    ),
    titleMedium: baseTextStyle.copyWith(
      fontSize: 16,
      fontWeight: FontWeight.w600,
    ),
    titleSmall: baseTextStyle.copyWith(
      fontSize: 14,
      fontWeight: FontWeight.w600,
    ),
    bodyLarge: baseTextStyle.copyWith(
      fontSize: 16,
      fontWeight: FontWeight.w400,
    ),
    bodyMedium: baseTextStyle.copyWith(
      fontSize: 14,
      fontWeight: FontWeight.w400,
      color: onSurfaceMuted,
    ),
    bodySmall: baseTextStyle.copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w400,
      color: onSurfaceMuted,
    ),
    labelLarge: baseTextStyle.copyWith(
      fontSize: 14,
      fontWeight: FontWeight.w600,
    ),
    labelMedium: baseTextStyle.copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w600,
    ),
    labelSmall: baseTextStyle.copyWith(
      fontSize: 11,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.5,
    ),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: canvas,
    fontFamily: fontFamily,
    textTheme: textTheme,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        fontFamily: fontFamily,
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: onSurface,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surfaceVariant,
      hintStyle: const TextStyle(
        fontFamily: fontFamily,
        color: onSurfaceMuted,
        fontSize: 14,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFF274439)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: accent, width: 1.4),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0xFF1A3128)),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: canvas,
        textStyle: const TextStyle(
          fontFamily: fontFamily,
          fontWeight: FontWeight.w600,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: accent,
        side: const BorderSide(color: accentDim),
        textStyle: const TextStyle(
          fontFamily: fontFamily,
          fontWeight: FontWeight.w600,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: accent,
        textStyle: const TextStyle(
          fontFamily: fontFamily,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      side: const BorderSide(color: Color(0xFF274439)),
      selectedColor: const Color(0xFF143628),
      backgroundColor: surfaceVariant,
      labelStyle: const TextStyle(
        fontFamily: fontFamily,
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: onSurface,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
    ),
    dividerTheme: const DividerThemeData(
      color: Color(0xFF1A3128),
      thickness: 1,
    ),
    iconTheme: const IconThemeData(color: onSurfaceMuted),
    popupMenuTheme: PopupMenuThemeData(
      color: surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFF274439)),
      ),
      textStyle: const TextStyle(
        fontFamily: fontFamily,
        fontSize: 13,
        color: onSurface,
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: surfaceVariant,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF274439)),
      ),
      textStyle: const TextStyle(
        fontFamily: fontFamily,
        fontSize: 12,
        color: onSurface,
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.all(const Color(0xFF274439)),
    ),
  );
}
