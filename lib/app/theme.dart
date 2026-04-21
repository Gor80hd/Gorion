import 'package:flutter/material.dart';
import 'package:gorion_clean/app/theme_settings.dart';

const gorionDefaultWindowBackground = Color(0xFF06110B);
const _fontFamily = 'IBMPlexSans';

const gorionBackgroundStart = Color(0xFF000000);
const gorionBackgroundEnd = Color(0xFF00140C);
const gorionCanvas = Color(0xFF06110B);
const gorionSurface = Color(0xFF101B16);
const gorionSurfaceVariant = Color(0xFF172721);
const gorionOnSurface = Color(0xFFE7F6EF);
const gorionOnSurfaceMuted = Color(0xFF7FA395);
const gorionAccent = Color(0xFF1EFFAC);
const gorionAccentDim = Color(0xFF0E865E);
const gorionMonochromeLightAccent = Color(0xFF111111);
const gorionMonochromeLightSecondary = Color(0xFF3E3E3E);
const gorionMonochromeLightTertiary = Color(0xFF6E6E6E);

@immutable
class GorionThemeTokens extends ThemeExtension<GorionThemeTokens> {
  const GorionThemeTokens({
    required this.backgroundStart,
    required this.backgroundEnd,
    required this.backgroundAccent,
    required this.onSurfaceMuted,
    required this.atmospherePrimary,
    required this.atmosphereSecondary,
    required this.atmosphereTertiary,
  });

  final Color backgroundStart;
  final Color backgroundEnd;
  final Color backgroundAccent;
  final Color onSurfaceMuted;
  final Color atmospherePrimary;
  final Color atmosphereSecondary;
  final Color atmosphereTertiary;

  Gradient backgroundGradientFor(Brightness brightness) {
    if (brightness == Brightness.dark) {
      return RadialGradient(
        center: const Alignment(0, -0.12),
        radius: 1.22,
        colors: [
          Colors.black,
          Color.lerp(backgroundStart, Colors.black, 0.90)!,
          Color.lerp(backgroundStart, Colors.black, 0.58)!,
          Color.lerp(backgroundEnd, Colors.black, 0.50)!,
        ],
        stops: const [0.0, 0.10, 0.38, 1.0],
      );
    }

    final lightBackgroundAccent = Color.lerp(
      backgroundAccent,
      Colors.white,
      0.60,
    )!;

    return RadialGradient(
      center: const Alignment(0, -0.12),
      radius: 1.10,
      colors: [
        Colors.white,
        Color.lerp(Colors.white, lightBackgroundAccent, 0.06)!,
        Color.lerp(Colors.white, lightBackgroundAccent, 0.16)!,
        Color.lerp(backgroundEnd, lightBackgroundAccent, 0.58)!,
        Color.lerp(lightBackgroundAccent, backgroundEnd, 0.18)!,
      ],
      stops: const [0.0, 0.42, 0.74, 0.91, 1.0],
    );
  }

  @override
  GorionThemeTokens copyWith({
    Color? backgroundStart,
    Color? backgroundEnd,
    Color? backgroundAccent,
    Color? onSurfaceMuted,
    Color? atmospherePrimary,
    Color? atmosphereSecondary,
    Color? atmosphereTertiary,
  }) {
    return GorionThemeTokens(
      backgroundStart: backgroundStart ?? this.backgroundStart,
      backgroundEnd: backgroundEnd ?? this.backgroundEnd,
      backgroundAccent: backgroundAccent ?? this.backgroundAccent,
      onSurfaceMuted: onSurfaceMuted ?? this.onSurfaceMuted,
      atmospherePrimary: atmospherePrimary ?? this.atmospherePrimary,
      atmosphereSecondary: atmosphereSecondary ?? this.atmosphereSecondary,
      atmosphereTertiary: atmosphereTertiary ?? this.atmosphereTertiary,
    );
  }

  @override
  GorionThemeTokens lerp(
    covariant ThemeExtension<GorionThemeTokens>? other,
    double t,
  ) {
    if (other is! GorionThemeTokens) {
      return this;
    }

    return GorionThemeTokens(
      backgroundStart: Color.lerp(backgroundStart, other.backgroundStart, t)!,
      backgroundEnd: Color.lerp(backgroundEnd, other.backgroundEnd, t)!,
      backgroundAccent: Color.lerp(
        backgroundAccent,
        other.backgroundAccent,
        t,
      )!,
      onSurfaceMuted: Color.lerp(onSurfaceMuted, other.onSurfaceMuted, t)!,
      atmospherePrimary: Color.lerp(
        atmospherePrimary,
        other.atmospherePrimary,
        t,
      )!,
      atmosphereSecondary: Color.lerp(
        atmosphereSecondary,
        other.atmosphereSecondary,
        t,
      )!,
      atmosphereTertiary: Color.lerp(
        atmosphereTertiary,
        other.atmosphereTertiary,
        t,
      )!,
    );
  }
}

extension GorionThemeBuildContextX on BuildContext {
  GorionThemeTokens get gorionTokens => Theme.of(this).gorionTokens;
}

extension GorionThemeDataX on ThemeData {
  GorionThemeTokens get gorionTokens {
    return extension<GorionThemeTokens>() ?? _fallbackGorionTokens(this);
  }

  bool get isMonochromeLightGorion {
    return brightness == Brightness.light &&
        colorScheme.primary.toARGB32() ==
            gorionMonochromeLightAccent.toARGB32() &&
        colorScheme.secondary.toARGB32() ==
            gorionMonochromeLightSecondary.toARGB32();
  }

  Color get brandAccent {
    return isMonochromeLightGorion ? gorionAccent : colorScheme.primary;
  }

  Color surfaceTextColor({double darkAlpha = 1.0, double lightAlpha = 1.0}) {
    return colorScheme.onSurface.withValues(
      alpha: brightness == Brightness.dark ? darkAlpha : lightAlpha,
    );
  }

  Color surfaceMutedTextColor({
    double darkAlpha = 1.0,
    double lightAlpha = 0.92,
  }) {
    return gorionTokens.onSurfaceMuted.withValues(
      alpha: brightness == Brightness.dark ? darkAlpha : lightAlpha,
    );
  }

  Color surfaceStrokeColor({
    double darkAlpha = 0.08,
    double lightAlpha = 0.14,
  }) {
    return brightness == Brightness.dark
        ? colorScheme.onSurface.withValues(alpha: darkAlpha)
        : colorScheme.outline.withValues(alpha: lightAlpha);
  }
}

GorionThemeTokens _fallbackGorionTokens(ThemeData theme) {
  final scheme = theme.colorScheme;
  final isDark = theme.brightness == Brightness.dark;
  final scaffold = theme.scaffoldBackgroundColor;
  final surface = scheme.surface;

  return GorionThemeTokens(
    backgroundStart: isDark
        ? _mix(scaffold, Colors.black, 0.10)
        : _mix(scaffold, scheme.primary, 0.045),
    backgroundEnd: isDark
        ? _mix(surface, scheme.primary, 0.18)
        : _mix(surface, scheme.primary, 0.13),
    backgroundAccent: scheme.primary,
    onSurfaceMuted: isDark
        ? _mix(scheme.onSurface, surface, 0.35)
        : _mix(scheme.onSurface, scheme.surface, 0.30),
    atmospherePrimary: scheme.primary.withValues(alpha: isDark ? 0.14 : 0.032),
    atmosphereSecondary: scheme.secondary.withValues(
      alpha: isDark ? 0.10 : 0.022,
    ),
    atmosphereTertiary: scheme.tertiary.withValues(
      alpha: isDark ? 0.08 : 0.018,
    ),
  );
}

class AppThemePalettePresentation {
  const AppThemePalettePresentation({
    required this.title,
    required this.description,
    required this.previewColor,
  });

  final String title;
  final String description;
  final Color previewColor;
}

class _PaletteAccentSet {
  const _PaletteAccentSet({
    required this.accent,
    required this.secondary,
    required this.tertiary,
  });

  final Color accent;
  final Color secondary;
  final Color tertiary;
}

AppThemePalettePresentation describeAppThemePalette(AppThemePalette palette) {
  final accents = _paletteAccents(palette);
  return AppThemePalettePresentation(
    title: palette.title,
    description: palette.description,
    previewColor: accents.accent,
  );
}

ThemeData buildGorionTheme({
  required Brightness brightness,
  required AppThemePalette palette,
}) {
  final isMonochromeLight =
      brightness == Brightness.light && palette == AppThemePalette.emerald;
  final baseAccents = isMonochromeLight
      ? const _PaletteAccentSet(
          accent: gorionMonochromeLightAccent,
          secondary: gorionMonochromeLightSecondary,
          tertiary: gorionMonochromeLightTertiary,
        )
      : _paletteAccents(palette);
  final accents = _resolvedPaletteAccents(palette, brightness);
  final isDark = brightness == Brightness.dark;

  final canvas = isDark
      ? _mix(const Color(0xFF07110D), accents.accent, 0.10)
      : isMonochromeLight
      ? const Color(0xFFFFFFFF)
      : _mix(const Color(0xFFF7FBF9), baseAccents.accent, 0.07);
  final surface = isDark
      ? _mix(const Color(0xFF111B17), accents.accent, 0.08)
      : isMonochromeLight
      ? const Color(0xFFFFFFFF)
      : _mix(const Color(0xFFFFFFFF), baseAccents.accent, 0.11);
  final surfaceVariant = isDark
      ? _mix(const Color(0xFF172520), accents.accent, 0.14)
      : isMonochromeLight
      ? const Color(0xFFF3F3F3)
      : _mix(
          _mix(const Color(0xFFF5FAF7), baseAccents.secondary, 0.10),
          baseAccents.accent,
          0.18,
        );
  final backgroundStart = isDark
      ? _mix(const Color(0xFF020303), accents.accent, 0.10)
      : isMonochromeLight
      ? const Color(0xFFFFFFFF)
      : _mix(const Color(0xFFF9FCFA), baseAccents.accent, 0.09);
  final backgroundEnd = isDark
      ? _mix(const Color(0xFF081711), accents.accent, 0.22)
      : isMonochromeLight
      ? Color.lerp(const Color(0xFFE8ECE8), gorionAccent, 0.08)!
      : _mix(const Color(0xFFE8F2EC), baseAccents.secondary, 0.24);
  final onSurface = isDark
      ? const Color(0xFFE8F5EF)
      : isMonochromeLight
      ? const Color(0xFF050505)
      : _mix(const Color(0xFF1B2520), baseAccents.secondary, 0.38);
  final onSurfaceMuted = isDark
      ? _mix(const Color(0xFF7FA395), accents.accent, 0.22)
      : isMonochromeLight
      ? const Color(0xFF626262)
      : _mix(const Color(0xFF607067), baseAccents.secondary, 0.34);
  final outline = isDark
      ? _mix(const Color(0xFF274439), accents.accent, 0.18)
      : isMonochromeLight
      ? const Color(0xFFBDBDBD)
      : _mix(const Color(0xFFAAC2B6), baseAccents.secondary, 0.32);
  final outlineVariant = isDark
      ? _mix(const Color(0xFF1A3128), accents.accent, 0.14)
      : isMonochromeLight
      ? const Color(0xFFE5E5E5)
      : _mix(const Color(0xFFD6E4DD), baseAccents.accent, 0.18);
  final error = isDark
      ? const Color(0xFFFF7373)
      : isMonochromeLight
      ? const Color(0xFF1F1F1F)
      : const Color(0xFFB42318);
  final onPrimary =
      ThemeData.estimateBrightnessForColor(accents.accent) == Brightness.dark
      ? Colors.white
      : const Color(0xFF05110B);
  final onSecondary =
      ThemeData.estimateBrightnessForColor(accents.secondary) == Brightness.dark
      ? Colors.white
      : onSurface;
  final onTertiary =
      ThemeData.estimateBrightnessForColor(accents.tertiary) == Brightness.dark
      ? Colors.white
      : const Color(0xFF09101A);
  final bodyMediumColor = isDark
      ? onSurfaceMuted
      : onSurface.withValues(alpha: 0.94);
  final bodySmallColor = isDark
      ? onSurfaceMuted
      : onSurfaceMuted.withValues(alpha: 0.96);
  final hintColor = isDark
      ? onSurfaceMuted
      : onSurfaceMuted.withValues(alpha: 0.86);
  final iconColor = isDark
      ? onSurfaceMuted
      : onSurfaceMuted.withValues(alpha: 0.96);
  final shadowColor = isDark
      ? Colors.black
      : isMonochromeLight
      ? const Color(0xFF6A6A6A)
      : _mix(const Color(0xFF6D8378), baseAccents.secondary, 0.18);

  final scheme = ColorScheme(
    brightness: brightness,
    primary: accents.accent,
    onPrimary: onPrimary,
    secondary: accents.secondary,
    onSecondary: onSecondary,
    tertiary: accents.tertiary,
    onTertiary: onTertiary,
    error: error,
    onError: const Color(0xFFFFFFFF),
    surface: surface,
    onSurface: onSurface,
    surfaceContainerHighest: surfaceVariant,
    outline: outline,
    outlineVariant: outlineVariant,
  );

  final tokens = GorionThemeTokens(
    backgroundStart: backgroundStart,
    backgroundEnd: backgroundEnd,
    backgroundAccent: isDark
        ? accents.accent
        : isMonochromeLight
        ? gorionAccent
        : baseAccents.accent,
    onSurfaceMuted: onSurfaceMuted,
    atmospherePrimary: (isDark ? accents.accent : baseAccents.accent)
        .withValues(
          alpha: isDark
              ? 0.14
              : isMonochromeLight
              ? 0.028
              : 0.032,
        ),
    atmosphereSecondary: accents.secondary.withValues(
      alpha: isDark
          ? 0.10
          : isMonochromeLight
          ? 0.018
          : 0.022,
    ),
    atmosphereTertiary: accents.tertiary.withValues(
      alpha: isDark
          ? 0.08
          : isMonochromeLight
          ? 0.014
          : 0.018,
    ),
  );

  final baseTextStyle = TextStyle(fontFamily: _fontFamily, color: onSurface);

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
      color: bodyMediumColor,
    ),
    bodySmall: baseTextStyle.copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w400,
      color: bodySmallColor,
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
    canvasColor: canvas,
    shadowColor: shadowColor,
    fontFamily: _fontFamily,
    textTheme: textTheme,
    extensions: [tokens],
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        fontFamily: _fontFamily,
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: onSurface,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surfaceVariant,
      hintStyle: TextStyle(
        fontFamily: _fontFamily,
        color: hintColor,
        fontSize: 14,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: accents.accent, width: 1.4),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: outlineVariant),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: accents.accent,
        foregroundColor: onPrimary,
        textStyle: const TextStyle(
          fontFamily: _fontFamily,
          fontWeight: FontWeight.w600,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accents.accent,
        foregroundColor: onPrimary,
        textStyle: const TextStyle(
          fontFamily: _fontFamily,
          fontWeight: FontWeight.w600,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: accents.accent,
        side: BorderSide(color: accents.secondary),
        textStyle: const TextStyle(
          fontFamily: _fontFamily,
          fontWeight: FontWeight.w600,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: accents.accent,
        textStyle: const TextStyle(
          fontFamily: _fontFamily,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      side: BorderSide(color: outline),
      selectedColor: accents.accent.withValues(alpha: isDark ? 0.18 : 0.12),
      backgroundColor: surfaceVariant,
      labelStyle: TextStyle(
        fontFamily: _fontFamily,
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: onSurface,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
    ),
    dividerTheme: DividerThemeData(color: outlineVariant, thickness: 1),
    iconTheme: IconThemeData(color: iconColor),
    popupMenuTheme: PopupMenuThemeData(
      color: surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: outline),
      ),
      textStyle: TextStyle(
        fontFamily: _fontFamily,
        fontSize: 13,
        color: onSurface,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: surfaceVariant,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: outline),
      ),
      textStyle: TextStyle(
        fontFamily: _fontFamily,
        fontSize: 12,
        color: onSurface,
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.all(outline),
    ),
  );
}

_PaletteAccentSet _paletteAccents(AppThemePalette palette) {
  return switch (palette) {
    AppThemePalette.emerald => const _PaletteAccentSet(
      accent: Color(0xFF1EFFAC),
      secondary: Color(0xFF0E865E),
      tertiary: Color(0xFF72A8FF),
    ),
    AppThemePalette.ocean => const _PaletteAccentSet(
      accent: Color(0xFF3EC6FF),
      secondary: Color(0xFF1D7EA3),
      tertiary: Color(0xFF57E3D0),
    ),
    AppThemePalette.amber => const _PaletteAccentSet(
      accent: Color(0xFFFFC857),
      secondary: Color(0xFFB87818),
      tertiary: Color(0xFFFF8A5B),
    ),
    AppThemePalette.rose => const _PaletteAccentSet(
      accent: Color(0xFFFF7A90),
      secondary: Color(0xFFB54968),
      tertiary: Color(0xFFFFB86C),
    ),
  };
}

_PaletteAccentSet _resolvedPaletteAccents(
  AppThemePalette palette,
  Brightness brightness,
) {
  if (brightness == Brightness.light && palette == AppThemePalette.emerald) {
    return const _PaletteAccentSet(
      accent: gorionMonochromeLightAccent,
      secondary: gorionMonochromeLightSecondary,
      tertiary: gorionMonochromeLightTertiary,
    );
  }

  final base = _paletteAccents(palette);
  if (brightness == Brightness.dark) {
    return base;
  }

  return _PaletteAccentSet(
    accent: _accentOnLightSurface(base.accent, amount: 0.28),
    secondary: _accentOnLightSurface(base.secondary, amount: 0.10),
    tertiary: _accentOnLightSurface(base.tertiary, amount: 0.16),
  );
}

Color _accentOnLightSurface(Color color, {required double amount}) {
  if (ThemeData.estimateBrightnessForColor(color) == Brightness.dark) {
    return color;
  }

  return _mix(color, Colors.black, amount);
}

Color _mix(Color base, Color tint, double amount) {
  return Color.lerp(base, tint, amount.clamp(0.0, 1.0))!;
}
