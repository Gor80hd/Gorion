import 'dart:math' as math;
import 'dart:ui';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:gorion_clean/app/theme.dart';

class GlassPanel extends StatefulWidget {
  static const _strokeOutset = 1.0;

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
  State<GlassPanel> createState() => _GlassPanelState();
}

class _GlassPanelState extends State<GlassPanel> {
  Offset _globalOffset = Offset.zero;

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final renderBox = context.findRenderObject() as RenderBox?;
      if (renderBox == null || !renderBox.hasSize) return;

      final nextOffset = renderBox.localToGlobal(Offset.zero);
      if ((_globalOffset - nextOffset).distanceSquared < 0.25) return;

      setState(() => _globalOffset = nextOffset);
    });

    final viewportSize = MediaQuery.maybeOf(context)?.size ?? Size.zero;
    final theme = Theme.of(context);
    final backgroundColor = _resolveAdaptiveBackgroundColor(
      theme,
      widget.backgroundColor,
    );
    final strokeColor = _resolveAdaptiveStrokeColor(theme, widget.strokeColor);
    final effectiveOpacity = _resolveGlassOpacity(theme, widget.opacity);
    final blurSigma = _resolveGlassBlur(theme);
    final lightEdgeOpacity = _resolveLightGlassEdgeOpacity(
      theme,
      widget.strokeOpacity,
    );
    final lightEdgeColor = _resolveLightGlassEdgeColor(theme, strokeColor);

    return Container(
      width: widget.width,
      height: widget.height,
      margin: widget.margin,
      child: CustomPaint(
        painter: _GradientStrokePainter(
          borderRadius: widget.borderRadius,
          strokeColor: strokeColor,
          strokeOpacity: widget.strokeOpacity,
          strokeWidth: widget.strokeWidth,
          strokeOutset: GlassPanel._strokeOutset,
          showGlow: widget.showGlow,
          glowBlur: widget.glowBlur,
          gradientBegin: widget.gradientBegin,
          gradientEnd: widget.gradientEnd,
          viewportSize: viewportSize,
          globalOffset: _globalOffset,
        ),
        foregroundPainter: lightEdgeOpacity > 0
            ? _LightGlassEdgePainter(
                borderRadius: widget.borderRadius,
                strokeWidth: math.max(0.9, widget.strokeWidth * 0.92),
                edgeColor: lightEdgeColor,
                edgeOpacity: lightEdgeOpacity,
              )
            : null,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
            child: Container(
              padding: widget.padding,
              decoration: _buildGlassDecoration(
                theme,
                backgroundColor,
                effectiveOpacity,
                widget.borderRadius,
              ),
              foregroundDecoration: theme.brightness == Brightness.dark
                  ? null
                  : _buildGlassHighlightDecoration(theme, widget.borderRadius),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

Color _resolveAdaptiveBackgroundColor(ThemeData theme, Color? value) {
  if (value == null) {
    return theme.colorScheme.surface;
  }
  if (value == Colors.white) {
    return theme.brightness == Brightness.dark
        ? theme.colorScheme.onSurface
        : theme.colorScheme.surface;
  }
  return value;
}

Color _resolveAdaptiveStrokeColor(ThemeData theme, Color? value) {
  if (value == null) {
    return theme.colorScheme.onSurface;
  }
  if (value == Colors.white) {
    return theme.brightness == Brightness.dark
        ? theme.colorScheme.onSurface
        : theme.colorScheme.outline;
  }
  if (value == Colors.black) {
    return theme.shadowColor;
  }
  return value;
}

double _resolveGlassOpacity(ThemeData theme, double opacity) {
  if (opacity <= 0) {
    return 0;
  }

  final minOpacity = theme.brightness == Brightness.dark ? 0.05 : 0.11;
  if (opacity < minOpacity) {
    return minOpacity;
  }

  return opacity.clamp(0.0, 1.0).toDouble();
}

double _resolveGlassBlur(ThemeData theme) {
  return theme.brightness == Brightness.dark ? 13 : 9;
}

double _resolveLightGlassEdgeOpacity(ThemeData theme, double strokeOpacity) {
  if (theme.brightness != Brightness.light) {
    return 0;
  }

  final normalizedOpacity = strokeOpacity.clamp(0.0, 1.0).toDouble();
  final minOpacity = theme.isMonochromeLightGorion ? 0.14 : 0.12;
  final maxOpacity = theme.isMonochromeLightGorion ? 0.24 : 0.20;
  final scaledOpacity = normalizedOpacity * 1.05 + 0.08;
  return math.max(minOpacity, math.min(maxOpacity, scaledOpacity));
}

Color _resolveLightGlassEdgeColor(ThemeData theme, Color strokeColor) {
  if (theme.brightness != Brightness.light) {
    return strokeColor;
  }

  final scheme = theme.colorScheme;
  final neutralEdge = Color.lerp(
    scheme.outline,
    scheme.onSurface,
    theme.isMonochromeLightGorion ? 0.22 : 0.16,
  )!;

  final isNeutralStroke =
      strokeColor.toARGB32() == scheme.outline.toARGB32() ||
      strokeColor.toARGB32() == scheme.onSurface.toARGB32();
  if (isNeutralStroke) {
    return neutralEdge;
  }

  return Color.lerp(
    neutralEdge,
    strokeColor,
    theme.isMonochromeLightGorion ? 0.34 : 0.28,
  )!;
}

BoxDecoration _buildGlassDecoration(
  ThemeData theme,
  Color baseColor,
  double opacity,
  double borderRadius,
) {
  final scheme = theme.colorScheme;
  final isDark = theme.brightness == Brightness.dark;
  final surface = scheme.surface;
  final tintColor = _resolveLightGlassTintColor(theme, baseColor);
  final uniformLightTint = tintColor == null
      ? null
      : Color.lerp(surface, Color.lerp(baseColor, tintColor, 0.16)!, 0.18)!;
  final topColor = Color.lerp(
    surface,
    uniformLightTint ?? tintColor ?? baseColor,
    isDark
        ? 0.24
        : uniformLightTint != null
        ? 1.0
        : tintColor != null
        ? 0.14
        : 0.10,
  )!.withValues(alpha: (opacity * (isDark ? 1.18 : 1.34)).clamp(0.0, 1.0));
  final middleColor = Color.lerp(
    surface,
    uniformLightTint ??
        (tintColor == null
            ? baseColor
            : Color.lerp(baseColor, tintColor, 0.55)!),
    isDark
        ? 0.32
        : uniformLightTint != null
        ? 1.0
        : tintColor != null
        ? 0.20
        : 0.16,
  )!.withValues(alpha: (opacity * (isDark ? 0.92 : 1.10)).clamp(0.0, 1.0));
  final bottomColor = Color.lerp(
    surface,
    uniformLightTint ??
        (tintColor == null
            ? baseColor
            : Color.lerp(baseColor, tintColor, 0.35)!),
    isDark
        ? 0.40
        : uniformLightTint != null
        ? 1.0
        : tintColor != null
        ? 0.25
        : 0.22,
  )!.withValues(alpha: (opacity * (isDark ? 0.84 : 0.96)).clamp(0.0, 1.0));

  return BoxDecoration(
    borderRadius: BorderRadius.circular(borderRadius),
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      stops: const [0.0, 0.55, 1.0],
      colors: [topColor, middleColor, bottomColor],
    ),
  );
}

BoxDecoration _buildGlassHighlightDecoration(
  ThemeData theme,
  double borderRadius,
) {
  final lightHighlight = theme.isMonochromeLightGorion
      ? Color.lerp(Colors.white, gorionAccent, 0.14)!
      : Colors.white;

  return BoxDecoration(
    borderRadius: BorderRadius.circular(borderRadius),
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      stops: const [0.0, 0.18, 0.62, 1.0],
      colors: [
        lightHighlight.withValues(alpha: 0.30),
        lightHighlight.withValues(alpha: 0.12),
        Colors.transparent,
        Colors.transparent,
      ],
    ),
  );
}

Color? _resolveLightGlassTintColor(ThemeData theme, Color baseColor) {
  if (!theme.isMonochromeLightGorion || theme.brightness != Brightness.light) {
    return null;
  }

  final scheme = theme.colorScheme;
  if (baseColor.toARGB32() == scheme.surface.toARGB32() ||
      baseColor.toARGB32() == scheme.onSurface.toARGB32()) {
    return gorionAccent;
  }

  return null;
}

class _GradientStrokePainter extends CustomPainter {
  const _GradientStrokePainter({
    required this.borderRadius,
    required this.strokeColor,
    required this.strokeOpacity,
    required this.strokeWidth,
    required this.strokeOutset,
    required this.showGlow,
    required this.glowBlur,
    required this.gradientBegin,
    required this.gradientEnd,
    required this.viewportSize,
    required this.globalOffset,
  });

  final double borderRadius;
  final Color strokeColor;
  final double strokeOpacity;
  final double strokeWidth;
  final double strokeOutset;
  final bool showGlow;
  final double glowBlur;
  final AlignmentGeometry gradientBegin;
  final AlignmentGeometry gradientEnd;
  final Size viewportSize;
  final Offset globalOffset;

  @override
  void paint(Canvas canvas, Size size) {
    final inset = strokeWidth / 2 - strokeOutset;
    final rect = Rect.fromLTWH(
      inset,
      inset,
      size.width + strokeOutset * 2 - strokeWidth,
      size.height + strokeOutset * 2 - strokeWidth,
    );
    final rRect = RRect.fromRectAndRadius(
      rect,
      Radius.circular(borderRadius + strokeOutset),
    );
    final shader = _createSharedShader();

    if (showGlow && glowBlur > 0) {
      final glowPaint = Paint()
        ..shader = shader
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..maskFilter = MaskFilter.blur(BlurStyle.outer, glowBlur);
      canvas.drawRRect(rRect, glowPaint);
    }

    final strokePaint = Paint()
      ..shader = shader
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawRRect(rRect, strokePaint);
  }

  Shader _createSharedShader() {
    final colors = [
      strokeColor.withValues(alpha: strokeOpacity),
      strokeColor.withValues(alpha: strokeOpacity * 0.72),
      strokeColor.withValues(alpha: strokeOpacity * 0.28),
      strokeColor.withValues(alpha: 0),
    ];
    const stops = [0.0, 0.24, 0.56, 1.0];

    if (viewportSize == Size.zero) {
      return LinearGradient(
        begin: gradientBegin,
        end: gradientEnd,
        colors: colors,
        stops: stops,
      ).createShader(const Rect.fromLTWH(0, 0, 1, 1));
    }

    final useFixedDiagonal =
        gradientBegin == Alignment.topLeft &&
        gradientEnd == Alignment.bottomRight;
    final viewportRect = Rect.fromLTWH(
      -globalOffset.dx,
      -globalOffset.dy,
      viewportSize.width,
      viewportSize.height,
    );

    if (useFixedDiagonal) {
      final span = math.max(
        260.0,
        math.min(viewportSize.width, viewportSize.height) * 0.52,
      );
      final start = viewportRect.topLeft;
      final end = start + Offset(span, span);
      return ui.Gradient.linear(start, end, colors, stops, TileMode.mirror);
    }

    final resolvedBegin = gradientBegin.resolve(TextDirection.ltr);
    final resolvedEnd = gradientEnd.resolve(TextDirection.ltr);
    return ui.Gradient.linear(
      resolvedBegin.withinRect(viewportRect),
      resolvedEnd.withinRect(viewportRect),
      colors,
      stops,
      TileMode.mirror,
    );
  }

  @override
  bool shouldRepaint(_GradientStrokePainter oldDelegate) =>
      oldDelegate.borderRadius != borderRadius ||
      oldDelegate.strokeColor != strokeColor ||
      oldDelegate.strokeOpacity != strokeOpacity ||
      oldDelegate.strokeWidth != strokeWidth ||
      oldDelegate.strokeOutset != strokeOutset ||
      oldDelegate.showGlow != showGlow ||
      oldDelegate.glowBlur != glowBlur ||
      oldDelegate.gradientBegin != gradientBegin ||
      oldDelegate.gradientEnd != gradientEnd ||
      oldDelegate.viewportSize != viewportSize ||
      oldDelegate.globalOffset != globalOffset;
}

class _LightGlassEdgePainter extends CustomPainter {
  const _LightGlassEdgePainter({
    required this.borderRadius,
    required this.strokeWidth,
    required this.edgeColor,
    required this.edgeOpacity,
  });

  final double borderRadius;
  final double strokeWidth;
  final Color edgeColor;
  final double edgeOpacity;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0 || edgeOpacity <= 0) {
      return;
    }

    final inset = strokeWidth / 2;
    final rect = Rect.fromLTWH(
      inset,
      inset,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );
    final rRect = RRect.fromRectAndRadius(rect, Radius.circular(borderRadius));
    final middleOpacity = math.min(edgeOpacity * 0.58, edgeOpacity);

    final strokePaint = Paint()
      ..shader = ui.Gradient.linear(
        rect.topLeft,
        rect.topRight,
        [
          edgeColor.withValues(alpha: edgeOpacity),
          edgeColor.withValues(alpha: middleOpacity),
          edgeColor.withValues(alpha: middleOpacity),
          edgeColor.withValues(alpha: edgeOpacity),
        ],
        const [0.0, 0.24, 0.76, 1.0],
      )
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    canvas.drawRRect(rRect, strokePaint);
  }

  @override
  bool shouldRepaint(_LightGlassEdgePainter oldDelegate) {
    return oldDelegate.borderRadius != borderRadius ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.edgeColor != edgeColor ||
        oldDelegate.edgeOpacity != edgeOpacity;
  }
}
