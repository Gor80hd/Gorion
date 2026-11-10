import 'dart:math' as math;
import 'dart:ui' show ImageFilter;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Liquid-glass панель: почти прозрачная заливка, размытие фона,
/// тональный градиент (рефракция) и бликующая кромка сверху.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.borderRadius = 15,
    this.padding = EdgeInsets.zero,
    this.margin = EdgeInsets.zero,
    this.width,
    this.height,
    this.opacity = 0.5,
    this.backgroundColor,
    this.boxShadow,
    this.strokeColor,
    this.strokeOpacity = 0.9,
    this.strokeWidth = 1.0,
    this.showGlow = false,
    this.glowBlur = 8,
    this.gradientBegin = Alignment.topLeft,
    this.gradientEnd = Alignment.bottomRight,
  });

  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final double? width;
  final double? height;
  final double opacity;
  final Color? backgroundColor;
  final List<BoxShadow>? boxShadow;
  final Color? strokeColor;
  final double strokeOpacity;
  final double strokeWidth;
  final bool showGlow;
  final double glowBlur;
  final AlignmentGeometry gradientBegin;
  final AlignmentGeometry gradientEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final baseColor = _resolveBaseColor(theme, backgroundColor);
    final edgeColor = _resolveStrokeColor(theme, strokeColor);
    final fillOpacity = _resolveFillOpacity(theme, opacity);
    final blurSigma = isDark ? 22.0 : 18.0;

    return Container(
      width: width,
      height: height,
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: boxShadow,
      ),
      child: CustomPaint(
        painter: _GlassEdgePainter(
          borderRadius: borderRadius,
          edgeColor: edgeColor,
          strokeOpacity: strokeOpacity,
          strokeWidth: strokeWidth,
          showGlow: showGlow,
          glowBlur: glowBlur,
          isDark: isDark,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
            child: Container(
              padding: padding,
              decoration: _glassFillDecoration(
                isDark: isDark,
                baseColor: baseColor,
                opacity: fillOpacity,
                borderRadius: borderRadius,
                scheme: scheme,
              ),
              foregroundDecoration: _glassSheenDecoration(
                isDark: isDark,
                borderRadius: borderRadius,
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

Color _resolveBaseColor(ThemeData theme, Color? value) {
  if (value == null) {
    return theme.colorScheme.surface;
  }
  return value;
}

Color _resolveStrokeColor(ThemeData theme, Color? value) {
  if (value == null) {
    return theme.colorScheme.onSurface;
  }
  if (value == Colors.white && theme.brightness == Brightness.light) {
    return theme.colorScheme.outline;
  }
  if (value == Colors.black) {
    return theme.shadowColor;
  }
  return value;
}

double _resolveFillOpacity(ThemeData theme, double opacity) {
  if (opacity <= 0) {
    return 0;
  }

  final isDark = theme.brightness == Brightness.dark;
  final scaled = isDark ? opacity : opacity * 1.35;
  final minOpacity = isDark ? 0.035 : 0.06;
  return math.max(minOpacity, scaled).clamp(0.0, 0.85).toDouble();
}

/// Тональная «рефракция»: верх панели чуть светлее, низ чуть глубже,
/// за счёт чего стекло читается объёмно на любом фоне.
BoxDecoration _glassFillDecoration({
  required bool isDark,
  required Color baseColor,
  required double opacity,
  required double borderRadius,
  required ColorScheme scheme,
}) {
  final topTone = isDark
      ? Color.lerp(baseColor, Colors.white, 0.10)!
      : Color.lerp(baseColor, Colors.white, 0.42)!;
  final middleTone = baseColor;
  final bottomTone = isDark
      ? Color.lerp(baseColor, Colors.black, 0.16)!
      : Color.lerp(baseColor, scheme.onSurface, 0.05)!;

  return BoxDecoration(
    borderRadius: BorderRadius.circular(borderRadius),
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      stops: const [0.0, 0.52, 1.0],
      colors: [
        topTone.withValues(alpha: opacity * (isDark ? 1.0 : 0.92)),
        middleTone.withValues(alpha: opacity * 0.82),
        bottomTone.withValues(alpha: opacity * (isDark ? 0.9 : 1.0)),
      ],
    ),
  );
}

/// Мягкий блик: тонкая светлая растяжка по верхней части стекла.
BoxDecoration _glassSheenDecoration({
  required bool isDark,
  required double borderRadius,
}) {
  final sheen = isDark ? Colors.white : Colors.white;
  return BoxDecoration(
    borderRadius: BorderRadius.circular(borderRadius),
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      stops: const [0.0, 0.28, 0.6, 1.0],
      colors: [
        sheen.withValues(alpha: isDark ? 0.075 : 0.28),
        sheen.withValues(alpha: isDark ? 0.02 : 0.08),
        Colors.transparent,
        Colors.transparent,
      ],
    ),
  );
}

class _GlassEdgePainter extends CustomPainter {
  const _GlassEdgePainter({
    required this.borderRadius,
    required this.edgeColor,
    required this.strokeOpacity,
    required this.strokeWidth,
    required this.showGlow,
    required this.glowBlur,
    required this.isDark,
  });

  final double borderRadius;
  final Color edgeColor;
  final double strokeOpacity;
  final double strokeWidth;
  final bool showGlow;
  final double glowBlur;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) {
      return;
    }

    final width = strokeWidth <= 0 ? 0.6 : strokeWidth;
    final inset = width / 2;
    final rect = Rect.fromLTWH(
      inset,
      inset,
      size.width - width,
      size.height - width,
    );
    if (rect.width <= 0 || rect.height <= 0) {
      return;
    }
    final rRect = RRect.fromRectAndRadius(
      rect,
      Radius.circular(math.max(0.0, borderRadius - inset)),
    );

    final baseAlpha = strokeOpacity.clamp(0.0, 1.0);

    if (showGlow && glowBlur > 0 && baseAlpha > 0) {
      final glowPaint = Paint()
        ..color = edgeColor.withValues(alpha: (baseAlpha * 0.55).clamp(0, 0.4))
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..maskFilter = MaskFilter.blur(BlurStyle.outer, glowBlur);
      canvas.drawRRect(rRect, glowPaint);
    }

    if (baseAlpha <= 0) {
      return;
    }

    // Основная кромка: яркая слева-сверху, почти невидимая снизу-справа.
    final edgeHighlight = isDark
        ? Color.lerp(edgeColor, Colors.white, 0.55)!
        : Color.lerp(edgeColor, Colors.white, 0.72)!;
    final borderPaint = Paint()
      ..shader = ui.Gradient.linear(
        rect.topLeft,
        rect.bottomRight,
        [
          edgeHighlight.withValues(alpha: (baseAlpha * 1.15).clamp(0.0, 0.85)),
          edgeColor.withValues(alpha: (baseAlpha * 0.55).clamp(0.0, 0.6)),
          edgeColor.withValues(alpha: (baseAlpha * 0.22).clamp(0.0, 0.35)),
        ],
        const [0.0, 0.45, 1.0],
      )
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    canvas.drawRRect(rRect, borderPaint);

    // Спекулярная линия по верхней кромке — главный признак «жидкого» стекла.
    final specularPaint = Paint()
      ..shader = ui.Gradient.linear(
        rect.topCenter,
        Offset(rect.center.dx, rect.top + rect.height * 0.32),
        [
          Colors.white.withValues(
            alpha: (baseAlpha * (isDark ? 0.5 : 0.95)).clamp(0.0, 1.0),
          ),
          Colors.white.withValues(alpha: 0),
        ],
      )
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round;
    canvas.drawRRect(rRect, specularPaint);
  }

  @override
  bool shouldRepaint(_GlassEdgePainter oldDelegate) {
    return oldDelegate.borderRadius != borderRadius ||
        oldDelegate.edgeColor != edgeColor ||
        oldDelegate.strokeOpacity != strokeOpacity ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.showGlow != showGlow ||
        oldDelegate.glowBlur != glowBlur ||
        oldDelegate.isDark != isDark;
  }
}
