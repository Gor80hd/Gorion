import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gorion_clean/features/home/utils/map_location_resolver.dart';

const Color _cobeMarkerColor = Color(0xFF33CCDD);
const Color _cobeArcColor = Color(0xFF4CD8F2);
const Color _cobeLandColor = Color(0xFFDCE1E5);
const Color _cobeLightSphereColor = Colors.white;
const Color _cobeLightLandColor = Colors.black;
const int _cobeMapSamples = 16000;
const double _maxTiltAngle = 0.86;

Future<List<_GlobeLandDot>>? _cachedLandDotsFuture;

class CobeStyleGlobe extends HookWidget {
  const CobeStyleGlobe({
    super.key,
    required this.contentPadding,
    required this.sourceLatLon,
    required this.destinationLatLon,
    required this.focusProgress,
    required this.revealProgress,
    required this.packetProgress,
    required this.showConnection,
    required this.isConnected,
    required this.sourceColor,
    required this.destinationColor,
  });

  final EdgeInsets contentPadding;
  final LatLon sourceLatLon;
  final LatLon destinationLatLon;
  final double focusProgress;
  final double revealProgress;
  final double packetProgress;
  final bool showConnection;
  final bool isConnected;
  final Color sourceColor;
  final Color destinationColor;

  @override
  Widget build(BuildContext context) {
    final isLightTheme = Theme.of(context).brightness == Brightness.light;
    final rotationController = useAnimationController(
      duration: const Duration(seconds: 180),
    );
    final pulseController = useAnimationController(
      duration: const Duration(seconds: 2),
    );
    final dragStart = useRef<Offset?>(null);
    final dragOffset = useRef(Offset.zero);
    final accumulatedPhi = useRef<double>(0);
    final accumulatedTheta = useRef<double>(0);
    final isDragging = useState(false);
    final previousShowConnection = useRef(showConnection);
    final landDotsFuture = useMemoized(_loadGlobeLandDots);
    final landDotsSnapshot = useFuture(landDotsFuture);

    useEffect(() {
      rotationController.repeat();
      pulseController.repeat();
      return null;
    }, const []);

    useEffect(() {
      final wasShowingConnection = previousShowConnection.value;
      previousShowConnection.value = showConnection;
      if (wasShowingConnection && !showConnection) {
        dragStart.value = null;
        dragOffset.value = Offset.zero;
        accumulatedPhi.value = 0;
        accumulatedTheta.value = 0;
        isDragging.value = false;
        rotationController
          ..value = 0
          ..repeat();
      }
      return null;
    }, [showConnection]);

    final rotationValue = useAnimation(rotationController);
    final pulseValue = useAnimation(pulseController);
    final sourcePhi = -_degToRad(sourceLatLon.$2);
    final sourceTheta = _degToRad(sourceLatLon.$1).clamp(-0.72, 0.72);
    final focusLatLon = _midpointLatLon(sourceLatLon, destinationLatLon);
    final focusPhi = -_degToRad(focusLatLon.$2);
    final focusTheta = _degToRad(focusLatLon.$1).clamp(-0.72, 0.72);
    final idlePhi = sourcePhi + (rotationValue * math.pi * 2);
    final driftPhi = math.sin(rotationValue * math.pi * 2) * 0.04;
    final driftTheta = math.sin(rotationValue * math.pi * 2 * 0.65) * 0.018;

    final basePhi =
        ui.lerpDouble(idlePhi, focusPhi + driftPhi, focusProgress) ?? idlePhi;
    final baseTheta =
        ui.lerpDouble(sourceTheta, focusTheta + driftTheta, focusProgress) ??
        sourceTheta;
    final autoAlignProgress = isDragging.value
        ? 0.0
        : Curves.easeInOutCubicEmphasized.transform(
            focusProgress.clamp(0.0, 1.0),
          );
    final manualPhi =
        (accumulatedPhi.value + dragOffset.value.dx) * (1 - autoAlignProgress);
    final manualTheta =
        (accumulatedTheta.value + dragOffset.value.dy) *
        (1 - autoAlignProgress);
    final phi = basePhi + manualPhi;
    final theta = _clampTiltAngle(baseTheta + manualTheta);

    void finishDrag() {
      if (!isDragging.value) {
        return;
      }
      accumulatedPhi.value += dragOffset.value.dx;
      accumulatedTheta.value = _clampTiltAngle(
        accumulatedTheta.value + dragOffset.value.dy,
      );
      dragOffset.value = Offset.zero;
      dragStart.value = null;
      isDragging.value = false;
      rotationController.repeat();
    }

    return MouseRegion(
      cursor: isDragging.value
          ? SystemMouseCursors.grabbing
          : SystemMouseCursors.grab,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) {
          dragStart.value = details.localPosition;
          dragOffset.value = Offset.zero;
          isDragging.value = true;
          rotationController.stop(canceled: false);
        },
        onPanUpdate: (details) {
          if (dragStart.value == null) {
            return;
          }
          final nextPhiOffset = dragOffset.value.dx + (details.delta.dx / 240);
          final nextThetaOffset =
              dragOffset.value.dy + (details.delta.dy / 320);
          final minThetaOffset =
              (-_maxTiltAngle) - baseTheta - accumulatedTheta.value;
          final maxThetaOffset =
              _maxTiltAngle - baseTheta - accumulatedTheta.value;
          dragOffset.value += Offset(
            nextPhiOffset - dragOffset.value.dx,
            nextThetaOffset.clamp(minThetaOffset, maxThetaOffset).toDouble() -
                dragOffset.value.dy,
          );
        },
        onPanEnd: (_) => finishDrag(),
        onPanCancel: finishDrag,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 1200),
          curve: Curves.easeOutCubic,
          opacity: landDotsSnapshot.connectionState == ConnectionState.waiting
              ? 0
              : 1,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _CobeStyleGlobePainter(
                landDots: landDotsSnapshot.data ?? const <_GlobeLandDot>[],
                contentPadding: contentPadding,
                sourceLatLon: sourceLatLon,
                destinationLatLon: destinationLatLon,
                phi: phi,
                theta: theta,
                focusProgress: focusProgress,
                revealProgress: revealProgress,
                packetProgress: packetProgress,
                pulseProgress: pulseValue,
                showConnection: showConnection,
                isConnected: isConnected,
                isLightTheme: isLightTheme,
                sourceColor: sourceColor,
                destinationColor: destinationColor,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }
}

class _CobeStyleGlobePainter extends CustomPainter {
  const _CobeStyleGlobePainter({
    required this.landDots,
    required this.contentPadding,
    required this.sourceLatLon,
    required this.destinationLatLon,
    required this.phi,
    required this.theta,
    required this.focusProgress,
    required this.revealProgress,
    required this.packetProgress,
    required this.pulseProgress,
    required this.showConnection,
    required this.isConnected,
    required this.isLightTheme,
    required this.sourceColor,
    required this.destinationColor,
  });

  final List<_GlobeLandDot> landDots;
  final EdgeInsets contentPadding;
  final LatLon sourceLatLon;
  final LatLon destinationLatLon;
  final double phi;
  final double theta;
  final double focusProgress;
  final double revealProgress;
  final double packetProgress;
  final double pulseProgress;
  final bool showConnection;
  final bool isConnected;
  final bool isLightTheme;
  final Color sourceColor;
  final Color destinationColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }

    final contentRect = Rect.fromLTWH(
      contentPadding.left,
      contentPadding.top,
      math.max(1, size.width - contentPadding.horizontal),
      math.max(1, size.height - contentPadding.vertical),
    );
    final globeSize = math.min(contentRect.width, contentRect.height);
    final diameter =
        ui.lerpDouble(globeSize * 0.82, globeSize * 0.98, focusProgress) ??
        globeSize * 0.82;
    final radius = diameter / 2;
    final sourceVector = _vectorFromLatLon(sourceLatLon.$1, sourceLatLon.$2);
    final destinationVector = _vectorFromLatLon(
      destinationLatLon.$1,
      destinationLatLon.$2,
    );
    final routeFocusVector = sourceVector.add(destinationVector).normalize();
    final baseCenter = Offset(
      contentRect.center.dx,
      contentRect.center.dy -
          (ui.lerpDouble(
                contentRect.height * 0.04,
                contentRect.height * 0.06,
                focusProgress,
              ) ??
              (contentRect.height * 0.04)),
    );
    final desiredFocusOffset = Offset(
      contentRect.center.dx,
      contentRect.center.dy - (contentRect.height * 0.03),
    );
    final baseFocusProjection = _projectVector(
      routeFocusVector,
      center: baseCenter,
      radius: radius,
      phi: phi,
      theta: theta,
    );
    final center = baseFocusProjection == null
        ? baseCenter
        : baseCenter +
              ((desiredFocusOffset - baseFocusProjection.offset) *
                  focusProgress.clamp(0.0, 1.0));
    final sphereRect = Rect.fromCircle(center: center, radius: radius);
    final arcColor = Color.lerp(_cobeArcColor, destinationColor, 0.32)!;

    _paintSphereBase(canvas, center, sphereRect);

    canvas.save();
    canvas.clipPath(Path()..addOval(sphereRect));
    _paintLandDots(canvas, center, radius);
    canvas.restore();

    _paintSphereRim(canvas, center, radius, arcColor);

    final sourceProjection = _projectVector(
      sourceVector,
      center: center,
      radius: radius,
      phi: phi,
      theta: theta,
    );
    final destinationProjection = _projectVector(
      destinationVector,
      center: center,
      radius: radius,
      phi: phi,
      theta: theta,
    );

    if (showConnection && revealProgress > 0.02) {
      _paintConnectionArc(
        canvas,
        center: center,
        radius: radius,
        sourceVector: sourceVector,
        destinationVector: destinationVector,
        arcColor: arcColor,
      );
    }

    if (sourceProjection != null) {
      _paintMarker(
        canvas,
        projection: sourceProjection,
        color: sourceColor,
        pulseSeed: 0.0,
        opacity: ui.lerpDouble(0.92, 1.0, focusProgress) ?? 1.0,
      );
    }

    if (destinationProjection != null) {
      _paintMarker(
        canvas,
        projection: destinationProjection,
        color: isConnected ? destinationColor : _cobeMarkerColor,
        pulseSeed: 0.45,
        opacity: ui.lerpDouble(0.84, 1.0, revealProgress) ?? 1.0,
      );
    }
  }

  void _paintSphereBase(Canvas canvas, Offset center, Rect sphereRect) {
    canvas.drawCircle(
      center,
      sphereRect.width / 2,
      Paint()
        ..color = isLightTheme
            ? _cobeLightSphereColor
            : const Color(0xFF070A0B),
    );
  }

  void _paintSphereRim(
    Canvas canvas,
    Offset center,
    double radius,
    Color rimColor,
  ) {
    final rimBaseColor = isLightTheme ? Colors.black : rimColor;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.9, radius * 0.0042)
        ..color = rimBaseColor.withValues(alpha: isLightTheme ? 0.12 : 0.13),
    );
  }

  void _paintLandDots(Canvas canvas, Offset center, double radius) {
    if (landDots.isEmpty) {
      return;
    }

    final surfaceDots = <Offset>[];

    for (final dot in landDots) {
      final projection = _projectVector(
        dot.vector,
        center: center,
        radius: radius,
        phi: phi,
        theta: theta,
      );
      if (projection == null) {
        continue;
      }
      surfaceDots.add(projection.offset);
    }

    if (surfaceDots.isNotEmpty) {
      final landColor = isLightTheme
          ? _cobeLightLandColor
          : isConnected
          ? Color.lerp(_cobeLandColor, destinationColor, 0.72) ??
                destinationColor
          : _cobeLandColor;

      if (isConnected && !isLightTheme) {
        canvas.drawPoints(
          ui.PointMode.points,
          surfaceDots,
          Paint()
            ..color = destinationColor.withValues(alpha: 0.18)
            ..strokeCap = StrokeCap.round
            ..strokeWidth = math.max(2.2, radius * 0.012),
        );
      }

      canvas.drawPoints(
        ui.PointMode.points,
        surfaceDots,
        Paint()
          ..color = landColor.withValues(alpha: isConnected ? 0.94 : 0.78)
          ..strokeCap = StrokeCap.round
          ..strokeWidth = math.max(0.95, radius * 0.0048),
      );
    }
  }

  void _paintConnectionArc(
    Canvas canvas, {
    required Offset center,
    required double radius,
    required _Vector3 sourceVector,
    required _Vector3 destinationVector,
    required Color arcColor,
  }) {
    final distance = _angularDistance(sourceVector, destinationVector);
    final lift = ui.lerpDouble(0.08, 0.2, (distance / math.pi).clamp(0, 1))!;
    final visibleProgress = revealProgress.clamp(0.0, 1.0);
    final steps = 72;
    final segments = <List<Offset>>[];
    var activeSegment = <Offset>[];

    for (var i = 0; i <= steps; i += 1) {
      final t = (i / steps) * visibleProgress;
      final arcVector = _slerp(sourceVector, destinationVector, t);
      final elevated = arcVector
          .scale(1 + math.sin(math.pi * t) * lift)
          .normalize();
      final projection = _projectVector(
        elevated,
        center: center,
        radius: radius,
        phi: phi,
        theta: theta,
      );

      if (projection == null || projection.depth < -0.04) {
        if (activeSegment.length > 1) {
          segments.add(activeSegment);
        }
        activeSegment = <Offset>[];
        continue;
      }

      activeSegment.add(projection.offset);
    }

    if (activeSegment.length > 1) {
      segments.add(activeSegment);
    }

    for (final segment in segments) {
      final path = Path()..moveTo(segment.first.dx, segment.first.dy);
      for (var i = 1; i < segment.length; i += 1) {
        path.lineTo(segment[i].dx, segment[i].dy);
      }

      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = math.max(4.0, radius * 0.028)
          ..color = arcColor.withValues(alpha: 0.13),
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = math.max(1.8, radius * 0.0105)
          ..color = arcColor.withValues(alpha: 0.34),
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = math.max(1.1, radius * 0.0046)
          ..color = arcColor.withValues(alpha: 0.96),
      );
    }

    const packetOffsets = [0.0, 0.33, 0.66];
    for (var index = 0; index < packetOffsets.length; index += 1) {
      final travel = (packetProgress + packetOffsets[index]) % 1.0;
      if (travel > visibleProgress) {
        continue;
      }

      final arcVector = _slerp(sourceVector, destinationVector, travel);
      final elevated = arcVector
          .scale(1 + math.sin(math.pi * travel) * lift)
          .normalize();
      final projection = _projectVector(
        elevated,
        center: center,
        radius: radius,
        phi: phi,
        theta: theta,
      );
      if (projection == null || projection.depth < 0) {
        continue;
      }

      final glowRadius = math.max(3.2, radius * (0.018 - index * 0.003));
      final coreRadius = math.max(1.8, radius * (0.008 - index * 0.0014));
      canvas.drawCircle(
        projection.offset,
        glowRadius,
        Paint()
          ..color = arcColor.withValues(alpha: 0.16 + (0.06 * (2 - index))),
      );
      canvas.drawCircle(
        projection.offset,
        coreRadius,
        Paint()..color = arcColor.withValues(alpha: 0.92 - (index * 0.12)),
      );
    }
  }

  void _paintMarker(
    Canvas canvas, {
    required _Projection projection,
    required Color color,
    required double pulseSeed,
    required double opacity,
  }) {
    final frontness = ((projection.visibility - 0.14) / 0.86).clamp(0.0, 1.0);
    if (frontness <= 0.01) {
      return;
    }

    final center = projection.offset;
    final visibleOpacity = opacity.clamp(0.0, 1.0);
    final depthScale = ui.lerpDouble(0.92, 1.04, frontness) ?? 1.0;
    final baseRadius =
        (math.max(4.2, projection.visualRadius * 0.023) * depthScale);
    final auraRadius =
        (math.max(10.5, projection.visualRadius * 0.058) * depthScale);

    for (final extraSeed in [pulseSeed, pulseSeed + 0.5]) {
      final progress = (pulseProgress + extraSeed) % 1.0;
      final ringRadius = ui.lerpDouble(
        baseRadius * 1.1,
        auraRadius * 1.8,
        progress,
      )!;
      final ringOpacity = (1 - progress) * 0.72 * visibleOpacity * frontness;
      canvas.drawCircle(
        center,
        ringRadius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.0, projection.visualRadius * 0.008)
          ..color = color.withValues(alpha: ringOpacity),
      );
    }

    canvas.drawCircle(
      center,
      auraRadius * 0.82,
      Paint()..color = color.withValues(alpha: 0.10 * visibleOpacity),
    );
    canvas.drawCircle(
      center,
      baseRadius + 2.6,
      Paint()..color = Colors.black.withValues(alpha: 0.98 * visibleOpacity),
    );
    canvas.drawCircle(
      center,
      baseRadius + 0.9,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.1, projection.visualRadius * 0.007)
        ..color = color.withValues(alpha: 1.0 * visibleOpacity),
    );
    canvas.drawCircle(
      center,
      baseRadius,
      Paint()..color = color.withValues(alpha: 1.0 * visibleOpacity),
    );
  }

  @override
  bool shouldRepaint(covariant _CobeStyleGlobePainter oldDelegate) {
    return oldDelegate.landDots != landDots ||
        oldDelegate.contentPadding != contentPadding ||
        oldDelegate.sourceLatLon != sourceLatLon ||
        oldDelegate.destinationLatLon != destinationLatLon ||
        oldDelegate.phi != phi ||
        oldDelegate.theta != theta ||
        oldDelegate.focusProgress != focusProgress ||
        oldDelegate.revealProgress != revealProgress ||
        oldDelegate.packetProgress != packetProgress ||
        oldDelegate.pulseProgress != pulseProgress ||
        oldDelegate.showConnection != showConnection ||
        oldDelegate.isConnected != isConnected ||
        oldDelegate.isLightTheme != isLightTheme ||
        oldDelegate.sourceColor != sourceColor ||
        oldDelegate.destinationColor != destinationColor;
  }
}

class _GlobeLandDot {
  const _GlobeLandDot({required this.vector});

  final _Vector3 vector;
}

class _Projection {
  const _Projection({
    required this.offset,
    required this.depth,
    required this.visibility,
    required this.visualRadius,
  });

  final Offset offset;
  final double depth;
  final double visibility;
  final double visualRadius;
}

class _Vector3 {
  const _Vector3(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;

  double dot(_Vector3 other) => x * other.x + y * other.y + z * other.z;

  _Vector3 add(_Vector3 other) =>
      _Vector3(x + other.x, y + other.y, z + other.z);

  _Vector3 scale(double factor) => _Vector3(x * factor, y * factor, z * factor);

  double get length => math.sqrt((x * x) + (y * y) + (z * z));

  _Vector3 normalize() {
    final value = length;
    if (value <= 0.000001) {
      return const _Vector3(0, 0, 1);
    }
    return _Vector3(x / value, y / value, z / value);
  }
}

Future<List<_GlobeLandDot>> _loadGlobeLandDots() {
  return _cachedLandDotsFuture ??= _parseGlobeLandDots();
}

Future<List<_GlobeLandDot>> _parseGlobeLandDots() async {
  final data = await rootBundle.load('assets/images/cobe_map.png');
  final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final rawData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (rawData == null) {
    return const <_GlobeLandDot>[];
  }

  final bytes = rawData.buffer.asUint8List();
  final width = image.width;
  final height = image.height;
  final goldenAngle = math.pi * (3 - math.sqrt(5));
  final dots = <_GlobeLandDot>[];
  for (var index = 0; index < _cobeMapSamples; index += 1) {
    final t = (index + 0.5) / _cobeMapSamples;
    final y = 1 - (2 * t);
    final radial = math.sqrt(math.max(0.0, 1 - (y * y)));
    final angle = goldenAngle * index;
    final x = math.cos(angle) * radial;
    final z = math.sin(angle) * radial;

    final lon = math.atan2(x, z);
    final lat = math.asin(y);
    final u = ((lon + math.pi) / (2 * math.pi)) % 1.0;
    final v = ((math.pi / 2 - lat) / math.pi).clamp(0.0, 1.0);

    final px = (u * (width - 1)).round().clamp(0, width - 1);
    final py = (v * (height - 1)).round().clamp(0, height - 1);
    final pixelIndex = ((py * width) + px) * 4;
    if (pixelIndex + 3 >= bytes.length) {
      continue;
    }

    final luminance =
        (bytes[pixelIndex] + bytes[pixelIndex + 1] + bytes[pixelIndex + 2]) /
        (255 * 3);
    if (luminance < 0.45) {
      continue;
    }

    dots.add(_GlobeLandDot(vector: _Vector3(x, y, z)));
  }

  image.dispose();
  return dots;
}

_Projection? _projectVector(
  _Vector3 vector, {
  required Offset center,
  required double radius,
  required double phi,
  required double theta,
}) {
  final cosPhi = math.cos(phi);
  final sinPhi = math.sin(phi);
  final x1 = (vector.x * cosPhi) + (vector.z * sinPhi);
  final z1 = (-vector.x * sinPhi) + (vector.z * cosPhi);

  final cosTheta = math.cos(theta);
  final sinTheta = math.sin(theta);
  final y2 = (vector.y * cosTheta) - (z1 * sinTheta);
  final z2 = (vector.y * sinTheta) + (z1 * cosTheta);

  if (z2 <= 0) {
    return null;
  }

  final screen = Offset(center.dx + (x1 * radius), center.dy - (y2 * radius));
  final visibility = z2.clamp(0.0, 1.0);

  return _Projection(
    offset: screen,
    depth: z2,
    visibility: visibility,
    visualRadius: radius,
  );
}

_Vector3 _vectorFromLatLon(double lat, double lon) {
  final latRad = _degToRad(lat);
  final lonRad = _degToRad(lon);
  final cosLat = math.cos(latRad);
  return _Vector3(
    cosLat * math.sin(lonRad),
    math.sin(latRad),
    cosLat * math.cos(lonRad),
  );
}

double _angularDistance(_Vector3 start, _Vector3 end) {
  final dot = start.dot(end).clamp(-1.0, 1.0);
  return math.acos(dot);
}

_Vector3 _slerp(_Vector3 start, _Vector3 end, double t) {
  final dot = start.dot(end).clamp(-1.0, 1.0);
  final angle = math.acos(dot);
  if (angle.abs() < 0.00001) {
    return start;
  }

  final sinAngle = math.sin(angle);
  final startScale = math.sin((1 - t) * angle) / sinAngle;
  final endScale = math.sin(t * angle) / sinAngle;
  return start.scale(startScale).add(end.scale(endScale)).normalize();
}

LatLon _midpointLatLon(LatLon first, LatLon second) {
  final vector = _vectorFromLatLon(
    first.$1,
    first.$2,
  ).add(_vectorFromLatLon(second.$1, second.$2)).normalize();
  final lat =
      math.atan2(
        vector.y,
        math.sqrt((vector.x * vector.x) + (vector.z * vector.z)),
      ) *
      180 /
      math.pi;
  final lon = math.atan2(vector.x, vector.z) * 180 / math.pi;
  return (lat, lon);
}

double _degToRad(double value) => value * math.pi / 180;

double _clampTiltAngle(double value) =>
    value.clamp(-_maxTiltAngle, _maxTiltAngle).toDouble();
