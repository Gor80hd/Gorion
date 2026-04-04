import 'dart:math' as math;
import 'dart:ui';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

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
    this.backgroundColor = const Color(0xFF454545),
    this.boxShadow,
    this.strokeColor = const Color(0xFF1EFFAC),
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
  final Color backgroundColor;
  final List<BoxShadow>? boxShadow;
  final Color strokeColor;
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

    return Container(
      width: widget.width,
      height: widget.height,
      margin: widget.margin,
      child: CustomPaint(
        painter: _GradientStrokePainter(
          borderRadius: widget.borderRadius,
          strokeColor: widget.strokeColor,
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
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
            child: Container(
              padding: widget.padding,
              decoration: BoxDecoration(
                color: widget.backgroundColor.withValues(alpha: widget.opacity),
                borderRadius: BorderRadius.circular(widget.borderRadius),
                boxShadow: widget.boxShadow,
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
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
    final rRect = RRect.fromRectAndRadius(rect, Radius.circular(borderRadius + strokeOutset));
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

    final useFixedDiagonal = gradientBegin == Alignment.topLeft && gradientEnd == Alignment.bottomRight;
    final viewportRect = Rect.fromLTWH(-globalOffset.dx, -globalOffset.dy, viewportSize.width, viewportSize.height);

    if (useFixedDiagonal) {
      final span = math.max(260.0, math.min(viewportSize.width, viewportSize.height) * 0.52);
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
