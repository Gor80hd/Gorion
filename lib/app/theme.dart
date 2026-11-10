import 'package:flutter/material.dart';

const gorionDefaultWindowBackground = Color(0xFF050D0A);
const _fontFamily = 'IBMPlexSans';

// Единая фирменная палитра Gorion: два выверенных режима (светлый и тёмный)
// без выбора цветовых гамм.
const gorionAccent = Color(0xFF1EFFAC);
const gorionAccentLight = Color(0xFF0B7A57);
const gorionOnSurface = Color(0xFFE9F6EF);
const gorionOnSurfaceMuted = Color(0xFF8AA897);

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
          Color.lerp(backgroundStart, Colors.black, 0.88)!,
          Color.lerp(backgroundStart, Colors.black, 0.52)!,
          Color.lerp(backgroundEnd, Colors.black, 0.42)!,
        ],
        stops: const [0.0, 0.10, 0.38, 1.0],
      );
    }

    return RadialGradient(
      center: const Alignment(0, -0.12),
      radius: 1.10,
      colors: [
        Colors.white,
        Color.lerp(Colors.white, backgroundStart, 0.55)!,
        backgroundStart,
        backgroundEnd,
      ],
      stops: const [0.0, 0.45, 0.78, 1.0],
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

  Color get brandAccent => colorScheme.primary;

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

  return GorionThemeTokens(
    backgroundStart: isDark ? const Color(0xFF030807) : const Color(0xFFFBFDFC),
    backgroundEnd: isDark ? const Color(0xFF0A1A12) : const Color(0xFFE7F0EB),
    backgroundAccent: scheme.primary,
    onSurfaceMuted: isDark ? gorionOnSurfaceMuted : const Color(0xFF55675E),
    atmospherePrimary: scheme.primary.withValues(alpha: isDark ? 0.14 : 0.05),
    atmosphereSecondary: scheme.secondary.withValues(
      alpha: isDark ? 0.10 : 0.04,
    ),
    atmosphereTertiary: scheme.tertiary.withValues(
      alpha: isDark ? 0.08 : 0.03,
    ),
  );
}

ThemeData buildGorionTheme({required Brightness brightness}) {
  final isDark = brightness == Brightness.dark;

  final accent = isDark ? gorionAccent : gorionAccentLight;
  final secondary = isDark ? const Color(0xFF57E3D0) : const Color(0xFF0E865E);
  final tertiary = isDark ? const Color(0xFF72A8FF) : const Color(0xFF3D6FB4);

  final canvas = isDark ? const Color(0xFF060F0B) : const Color(0xFFF5F8F6);
  final surface = isDark ? const Color(0xFF0C1811) : const Color(0xFFFFFFFF);
  final surfaceVariant = isDark
      ? const Color(0xFF12241B)
      : const Color(0xFFEDF2EF);
  final backgroundStart = isDark
      ? const Color(0xFF030807)
      : const Color(0xFFFBFDFC);
  final backgroundEnd = isDark
      ? const Color(0xFF0A1A12)
      : const Color(0xFFE7F0EB);
  final onSurface = isDark ? gorionOnSurface : const Color(0xFF12201A);
  final onSurfaceMuted = isDark
      ? gorionOnSurfaceMuted
      : const Color(0xFF55675E);
  final outline = isDark ? const Color(0xFF25453A) : const Color(0xFFB7C7BE);
  final outlineVariant = isDark
      ? const Color(0xFF183026)
      : const Color(0xFFDCE5DF);
  final error = isDark ? const Color(0xFFFF7373) : const Color(0xFFB42318);
  final onPrimary = isDark ? const Color(0xFF04120B) : const Color(0xFFFFFFFF);
  final shadowColor = isDark ? Colors.black : const Color(0xFF44564D);

  final scheme = ColorScheme(
    brightness: brightness,
    primary: accent,
    onPrimary: onPrimary,
    secondary: secondary,
    onSecondary: isDark ? const Color(0xFF04120B) : Colors.white,
    tertiary: tertiary,
    onTertiary: isDark ? const Color(0xFF04120B) : Colors.white,
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
    backgroundAccent: accent,
    onSurfaceMuted: onSurfaceMuted,
    atmospherePrimary: accent.withValues(alpha: isDark ? 0.14 : 0.05),
    atmosphereSecondary: secondary.withValues(alpha: isDark ? 0.10 : 0.04),
    atmosphereTertiary: tertiary.withValues(alpha: isDark ? 0.08 : 0.03),
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
      letterSpacing: -0.6,
    ),
    headlineLarge: baseTextStyle.copyWith(
      fontSize: 32,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.8,
    ),
    headlineMedium: baseTextStyle.copyWith(
      fontSize: 28,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.4,
    ),
    headlineSmall: baseTextStyle.copyWith(
      fontSize: 24,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.2,
    ),
    titleLarge: baseTextStyle.copyWith(
      fontSize: 20,
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
      height: 1.55,
    ),
    bodyMedium: baseTextStyle.copyWith(
      fontSize: 14,
      fontWeight: FontWeight.w400,
      color: isDark ? onSurfaceMuted : onSurface.withValues(alpha: 0.80),
      height: 1.5,
    ),
    bodySmall: baseTextStyle.copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w400,
      color: onSurfaceMuted,
      height: 1.45,
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
      letterSpacing: 0.4,
    ),
  );

  final buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(12),
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
      fillColor: isDark
          ? onSurface.withValues(alpha: 0.05)
          : onSurface.withValues(alpha: 0.04),
      hintStyle: TextStyle(
        fontFamily: _fontFamily,
        color: onSurfaceMuted,
        fontSize: 14,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: accent, width: 1.4),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: outlineVariant),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: onPrimary,
        elevation: 0,
        textStyle: const TextStyle(
          fontFamily: _fontFamily,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        shape: buttonShape,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: onPrimary,
        textStyle: const TextStyle(
          fontFamily: _fontFamily,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        shape: buttonShape,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: onSurface,
        side: BorderSide(color: outline, width: 1),
        textStyle: const TextStyle(
          fontFamily: _fontFamily,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        shape: buttonShape,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: accent,
        textStyle: const TextStyle(
          fontFamily: _fontFamily,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        shape: buttonShape,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: onSurfaceMuted),
    ),
    chipTheme: ChipThemeData(
      side: BorderSide(color: outlineVariant),
      selectedColor: accent.withValues(alpha: isDark ? 0.20 : 0.14),
      backgroundColor: isDark
          ? onSurface.withValues(alpha: 0.05)
          : onSurface.withValues(alpha: 0.04),
      labelStyle: TextStyle(
        fontFamily: _fontFamily,
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: onSurface,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: accent,
      thumbColor: accent,
      inactiveTrackColor: onSurface.withValues(alpha: isDark ? 0.12 : 0.10),
      overlayColor: accent.withValues(alpha: 0.12),
      trackHeight: 3,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return isDark ? const Color(0xFF04120B) : Colors.white;
        }
        return onSurfaceMuted;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return accent;
        }
        return onSurface.withValues(alpha: isDark ? 0.14 : 0.10);
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return Colors.transparent;
        }
        return onSurface.withValues(alpha: isDark ? 0.16 : 0.14);
      }),
    ),
    dividerTheme: DividerThemeData(color: outlineVariant, thickness: 1),
    iconTheme: IconThemeData(color: onSurfaceMuted),
    popupMenuTheme: PopupMenuThemeData(
      color: isDark ? const Color(0xFF101D15) : Colors.white,
      elevation: 16,
      shadowColor: shadowColor.withValues(alpha: 0.4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: outlineVariant),
      ),
      textStyle: TextStyle(
        fontFamily: _fontFamily,
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: onSurface,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: isDark ? const Color(0xFF0E1A13) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: isDark ? const Color(0xFF16281E) : const Color(0xFF12201A),
      contentTextStyle: TextStyle(
        fontFamily: _fontFamily,
        fontSize: 13,
        color: isDark ? onSurface : Colors.white,
      ),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF16281E) : const Color(0xFF12201A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark ? outline : Colors.transparent,
        ),
      ),
      textStyle: const TextStyle(
        fontFamily: _fontFamily,
        fontSize: 12,
        color: Colors.white,
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: accent,
      linearTrackColor: onSurface.withValues(alpha: isDark ? 0.10 : 0.08),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.all(
        onSurface.withValues(alpha: isDark ? 0.18 : 0.22),
      ),
    ),
  );
}
