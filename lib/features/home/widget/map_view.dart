import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:gap/gap.dart';
import 'package:gorion_clean/core/widget/glass_panel.dart';
import 'package:gorion_clean/core/widget/page_reveal.dart';
import 'package:gorion_clean/features/runtime/model/connection_status.dart';
import 'package:gorion_clean/features/runtime/notifier/connection_notifier.dart';
import 'package:gorion_clean/features/home/notifier/auto_server_selection_progress.dart';
import 'package:gorion_clean/features/home/notifier/home_status_card_provider.dart';
import 'package:gorion_clean/features/home/widget/selected_server_preview_provider.dart';
import 'package:gorion_clean/features/intro/utils/region_detector.dart';
import 'package:gorion_clean/features/proxy/model/ip_info_entity.dart';
import 'package:gorion_clean/features/proxy/notifier/ip_info_notifier.dart';
import 'package:gorion_clean/core/preferences/general_preferences.dart';
import 'package:gorion_clean/features/stats/notifier/stats_notifier.dart';
import 'package:gorion_clean/features/proxy/model/outbound_models.dart';
import 'package:gorion_clean/features/settings/model/singbox_config_enum.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Approximate world-map SVG coordinates for a given (lat, lon).
/// The SVG asset matches a Web Mercator-like vertical layout better than a
/// linear equirectangular one, especially for northern latitudes.
Offset _latLonToSvg(double lat, double lon) {
  const double width = 750;
  const double height = 500;
  const double maxLatitude = 85.05112878;

  final clampedLat = lat.clamp(-maxLatitude, maxLatitude);
  final latitudeRadians = clampedLat * math.pi / 180;
  final double x = (lon + 180) / 360 * width;
  final mercatorY = math.log(math.tan((math.pi / 4) + (latitudeRadians / 2)));
  final double y = height * (0.5 - mercatorY / (2 * math.pi));
  return Offset(x, y);
}

/// Rough country-code → (lat, lon) mapping for common locations.
const Map<String, (double, double)> _countryLatLon = {
  'DE': (51.1, 10.4),
  'US': (38.9, -77.0),
  'FR': (46.2, 2.2),
  'GB': (55.4, -3.4),
  'NL': (52.1, 5.3),
  'LT': (55.2, 23.9),
  'BE': (50.8, 4.5),
  'RO': (45.9, 24.9),
  'SK': (48.7, 19.7),
  'RU': (55.7, 37.6),
  'IR': (32.4, 53.7),
  'TR': (38.9, 35.2),
  'JP': (36.2, 138.3),
  'CN': (35.9, 104.5),
  'SG': (1.3, 103.8),
  'CA': (56.1, -106.3),
  'AU': (-25.3, 133.8),
  'BR': (-14.2, -51.9),
  'IN': (20.6, 78.9),
  'KR': (35.9, 127.8),
  'PL': (51.9, 19.1),
  'SE': (60.1, 18.6),
  'NO': (60.5, 8.5),
  'CH': (46.8, 8.2),
  'AT': (47.5, 14.6),
  'UA': (48.4, 31.2),
  'FI': (61.9, 25.7),
  'IT': (41.9, 12.5),
  'ES': (40.5, -3.7),
  'PT': (39.4, -8.2),
  'AE': (23.4, 53.8),
  'HK': (22.3, 114.2),
  'TW': (23.7, 121.0),
};

const Map<String, (double, double)> _locationKeywords = {
  'lithuania': (55.2, 23.9),
  'литва': (55.2, 23.9),
  'vilnius': (54.6872, 25.2797),
  'вильнюс': (54.6872, 25.2797),
  'belgium': (50.8, 4.5),
  'бельгия': (50.8, 4.5),
  'brussels': (50.8503, 4.3517),
  'брюссель': (50.8503, 4.3517),
  'romania': (45.9, 24.9),
  'румыния': (45.9, 24.9),
  'bucharest': (44.4268, 26.1025),
  'бухарест': (44.4268, 26.1025),
  'slovakia': (48.7, 19.7),
  'словакия': (48.7, 19.7),
  'bratislava': (48.1486, 17.1077),
  'братислава': (48.1486, 17.1077),
  'germany': (51.1, 10.4),
  'германия': (51.1, 10.4),
  'frankfurt': (50.1109, 8.6821),
  'франкфурт': (50.1109, 8.6821),
  'switzerland': (46.8, 8.2),
  'швейцария': (46.8, 8.2),
  'zurich': (47.3769, 8.5417),
  'цюрих': (47.3769, 8.5417),
  'united kingdom': (55.4, -3.4),
  'great britain': (55.4, -3.4),
  'britain': (55.4, -3.4),
  'великобритания': (55.4, -3.4),
  'london': (51.5074, -0.1278),
  'лондон': (51.5074, -0.1278),
  'south korea': (35.9, 127.8),
  'korea': (35.9, 127.8),
  'южная корея': (35.9, 127.8),
  'seoul': (37.5665, 126.9780),
  'сеул': (37.5665, 126.9780),
  'canada': (56.1, -106.3),
  'канада': (56.1, -106.3),
  'toronto': (43.6532, -79.3832),
  'торонто': (43.6532, -79.3832),
  'netherlands': (52.1, 5.3),
  'amsterdam': (52.3676, 4.9041),
  'france': (46.2, 2.2),
  'paris': (48.8566, 2.3522),
  'us': (38.9, -77.0),
  'usa': (38.9, -77.0),
  'united states': (38.9, -77.0),
  'new york': (40.7128, -74.0060),
  'los angeles': (34.0549, -118.2426),
  'russia': (55.7, 37.6),
  'moscow': (55.7558, 37.6173),
  'iran': (32.4, 53.7),
  'tehran': (35.6892, 51.3890),
  'turkey': (38.9, 35.2),
  'istanbul': (41.0082, 28.9784),
  'japan': (36.2, 138.3),
  'tokyo': (35.6762, 139.6503),
  'china': (35.9, 104.5),
  'singapore': (1.3521, 103.8198),
  'australia': (-25.3, 133.8),
  'brazil': (-14.2, -51.9),
  'india': (20.6, 78.9),
  'poland': (51.9, 19.1),
  'sweden': (60.1, 18.6),
  'norway': (60.5, 8.5),
  'austria': (47.5, 14.6),
  'ukraine': (48.4, 31.2),
  'finland': (61.9, 25.7),
  'italy': (41.9, 12.5),
  'spain': (40.5, -3.7),
  'portugal': (39.4, -8.2),
  'uae': (23.4, 53.8),
  'dubai': (25.2048, 55.2708),
  'hong kong': (22.3193, 114.1694),
  'taiwan': (23.7, 121.0),
};

(double, double) _getLatLon(String? countryCode) {
  if (countryCode == null) return (51.5, 10.0); // fallback Europe
  return _countryLatLon[countryCode.toUpperCase()] ?? (20.0, 0.0);
}

String _sanitizeServerName(String value) {
  return value.replaceAll(RegExp('§[^§]*'), '').trimRight();
}

String? _extractCountryCode(String value) {
  final match = RegExp(r'\[([A-Z]{2})\]|\b([A-Z]{2})\b').firstMatch(value);
  final code = match?.group(1) ?? match?.group(2);
  if (code == null || !_countryLatLon.containsKey(code)) return null;
  return code;
}

String? _extractCountryCodeFromFlag(String value) {
  final runes = value.runes.toList(growable: false);
  for (var i = 0; i < runes.length - 1; i++) {
    final first = runes[i];
    final second = runes[i + 1];
    final isFirstIndicator = first >= 0x1F1E6 && first <= 0x1F1FF;
    final isSecondIndicator = second >= 0x1F1E6 && second <= 0x1F1FF;
    if (!isFirstIndicator || !isSecondIndicator) {
      continue;
    }

    final code = String.fromCharCodes([0x41 + first - 0x1F1E6, 0x41 + second - 0x1F1E6]);
    if (_countryLatLon.containsKey(code)) {
      return code;
    }
  }
  return null;
}

Offset? _extractLatLonFromKeyword(String value) {
  final normalized = value.toLowerCase();
  for (final entry in _locationKeywords.entries) {
    if (normalized.contains(entry.key)) {
      return Offset(entry.value.$1, entry.value.$2);
    }
  }
  return null;
}

(double, double) _fallbackLatLonForName(String value) {
  var hash = 0;
  for (final codeUnit in value.codeUnits) {
    hash = ((hash * 31) + codeUnit) & 0x7fffffff;
  }

  final lat = -45 + (hash % 9000) / 100;
  final lon = -170 + ((hash ~/ 9000) % 34000) / 100;
  return (lat, lon);
}

(double, double) _resolveDestinationLatLon(OutboundInfo? selectedProxy, String? destCountry) {
  if (selectedProxy == null) return _getLatLon(destCountry ?? 'DE');

  final rawName = selectedProxy.tagDisplay.isNotEmpty ? selectedProxy.tagDisplay : selectedProxy.tag;
  final keywordLatLon = _extractLatLonFromKeyword(rawName);
  if (keywordLatLon != null) {
    return (keywordLatLon.dx, keywordLatLon.dy);
  }

  final countryCode = _extractCountryCode(rawName) ?? _extractCountryCodeFromFlag(rawName);

  if (countryCode != null) {
    return _getLatLon(countryCode);
  }

  final sanitizedName = _sanitizeServerName(rawName);
  if (sanitizedName.isNotEmpty) {
    return _fallbackLatLonForName(sanitizedName);
  }

  return _getLatLon(destCountry ?? 'DE');
}

(double, double) _resolveSourceLatLon(IpInfo? ipInfo) {
  if (ipInfo == null) {
    return (55.7558, 37.6173);
  }

  final locationParts = [ipInfo.city, ipInfo.region, ipInfo.countryCode].whereType<String>().join(', ');
  final keywordLatLon = _extractLatLonFromKeyword(locationParts);
  if (keywordLatLon != null) {
    return (keywordLatLon.dx, keywordLatLon.dy);
  }

  return _getLatLon(ipInfo.countryCode);
}

(double, double) _resolveLocalFallbackLatLon() {
  final locales = WidgetsBinding.instance.platformDispatcher.locales;
  for (final locale in locales) {
    final code = locale.countryCode;
    if (code != null && _countryLatLon.containsKey(code.toUpperCase())) {
      return _getLatLon(code);
    }
  }

  final detectedCountry = RegionDetector.detect();
  if (_countryLatLon.containsKey(detectedCountry)) {
    return _getLatLon(detectedCountry);
  }

  return (51.5, 10.0);
}

bool _sameIpInfo(IpInfo? left, IpInfo? right) {
  return left?.ip == right?.ip &&
      left?.countryCode == right?.countryCode &&
      left?.region == right?.region &&
      left?.city == right?.city &&
      left?.org == right?.org;
}

class MapView extends HookConsumerWidget {
  const MapView({super.key, required this.contentPadding});

  // SVG canvas size
  static const double _svgW = 750;
  static const double _svgH = 490;

  final EdgeInsets contentPadding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(connectionNotifierProvider);
    final directIpInfo = ref.watch(directIpInfoNotifierProvider);
    final routedIpInfo = ref.watch(ipInfoNotifierProvider);
    final activeProxy = ref.watch(activeProxyNotifierProvider);
    final statusCard = ref.watch(homeStatusCardProvider);
    final statsAsync = ref.watch(statsNotifierProvider);
    final serviceMode = ref.watch(ConfigOptions.serviceMode);
    final isConnected = status.isConnected;
    final isConnecting = status is Connecting;
    final isSwitching = status.isSwitching;
    final isDisconnected = status.isDisconnected;
    final keepSourceAnchored = isConnected || isSwitching;
    final shouldUseLocalSource = serviceMode == ServiceMode.systemProxy;
    final sourceAnchor = useState<IpInfo?>(null);
    final mapTransition = useAnimationController(duration: const Duration(milliseconds: 1200));
    final packetTravel = useAnimationController(duration: const Duration(milliseconds: 3200));

    final sourceInfo = directIpInfo.asData?.value;
    final routedInfo = routedIpInfo.asData?.value;
    final activeProxyInfo = activeProxy.asData?.value;
    final selectedProxy = statusCard.displayProxy ?? (activeProxyInfo?.tag.isNotEmpty == true ? activeProxyInfo : null);
    final destCountry = routedInfo?.countryCode ?? sourceInfo?.countryCode ?? sourceAnchor.value?.countryCode;

    useEffect(
      () {
        if (sourceInfo != null && !_sameIpInfo(sourceAnchor.value, sourceInfo)) {
          sourceAnchor.value = sourceInfo;
        }
        return null;
      },
      [
        isDisconnected,
        isSwitching,
        sourceInfo?.ip,
        sourceInfo?.countryCode,
        sourceInfo?.region,
        sourceInfo?.city,
        sourceInfo?.org,
      ],
    );

    useEffect(() {
      if (keepSourceAnchored) {
        mapTransition.forward();
        if (!packetTravel.isAnimating) {
          packetTravel.repeat();
        }
      } else {
        mapTransition.reverse();
        packetTravel
          ..stop()
          ..value = 0;
      }
      return null;
    }, [keepSourceAnchored]);

    final mapProgress = useAnimation(mapTransition);
    final packetProgress = useAnimation(packetTravel);

    final uplink = statsAsync.asData?.value.uplink ?? 0;
    final downlink = statsAsync.asData?.value.downlink ?? 0;

    final srcLatLon = shouldUseLocalSource
        ? _resolveLocalFallbackLatLon()
        : _resolveSourceLatLon(sourceInfo ?? sourceAnchor.value);
    final dstLatLon = _resolveDestinationLatLon(selectedProxy, destCountry);

    // Points in SVG-space
    final srcSvg = _latLonToSvg(srcLatLon.$1, srcLatLon.$2);
    final dstSvg = _latLonToSvg(dstLatLon.$1, dstLatLon.$2);

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth == 0 || constraints.maxHeight == 0) {
          return const SizedBox.expand();
        }

        final screenW = constraints.maxWidth;
        final screenH = constraints.maxHeight;
        final contentWidth = math.max(220.0, screenW - contentPadding.horizontal);
        final contentHeight = math.max(220.0, screenH - contentPadding.vertical);

        const double fullMapInset = 72;
        final fullScale = math.min(
          math.max(0.4, (contentWidth - fullMapInset * 2) / _svgW),
          math.max(0.4, (contentHeight - fullMapInset * 2) / _svgH),
        );
        final fullTx = contentPadding.left + (contentWidth - _svgW * fullScale) / 2;
        final fullTy = contentPadding.top + (contentHeight - _svgH * fullScale) / 2;

        const double padding = 190; // extra space around the bounding box (SVG units)
        final minX = math.min(srcSvg.dx, dstSvg.dx) - padding;
        final maxX = math.max(srcSvg.dx, dstSvg.dx) + padding;
        final minY = math.min(srcSvg.dy, dstSvg.dy) - padding;
        final maxY = math.max(srcSvg.dy, dstSvg.dy) + padding;

        final boxW = (maxX - minX).clamp(200.0, _svgW);
        final boxH = (maxY - minY).clamp(160.0, _svgH);

        final zoomScale = math.min(
          fullScale * 2.55,
          math.max(fullScale, math.min(contentWidth / boxW, contentHeight / boxH)),
        );

        final centerSvgX = (minX + maxX) / 2;
        final centerSvgY = (minY + maxY) / 2;
        final focusCenterX = contentPadding.left + (contentWidth / 2);

        const outerR = 14.0;
        final zoomTx = focusCenterX - centerSvgX * zoomScale;
        final zoomTy = contentPadding.top + (contentHeight / 2) - centerSvgY * zoomScale;

        final focusProgress = Curves.easeInOutCubicEmphasized.transform(mapProgress);
        final revealProgress = Curves.easeOutCubic.transform(((mapProgress - 0.1) / 0.9).clamp(0.0, 1.0));
        final scale = ui.lerpDouble(fullScale, zoomScale, focusProgress) ?? fullScale;
        final tx = ui.lerpDouble(fullTx, zoomTx, focusProgress) ?? fullTx;
        final ty = ui.lerpDouble(fullTy, zoomTy, focusProgress) ?? fullTy;

        final srcScreen = Offset(srcSvg.dx * scale + tx, srcSvg.dy * scale + ty);
        final dstScreen = Offset(dstSvg.dx * scale + tx, dstSvg.dy * scale + ty);
        final destinationOpacity = ui.lerpDouble(0.4, 1.0, revealProgress) ?? 0.4;

        return SizedBox.expand(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Transform(
                transform: Matrix4.translationValues(tx, ty, 0)..scale(scale),
                child: SvgPicture.asset(
                  'assets/images/world_map_dots.svg',
                  width: _svgW,
                  height: _svgH,
                  fit: BoxFit.none,
                  alignment: Alignment.topLeft,
                  colorFilter: ColorFilter.mode(
                    isConnected
                        ? const Color(0xFF1EFFAC).withValues(alpha: 0.55)
                        : const Color(0xFF4B6B5B).withValues(alpha: 0.50),
                    BlendMode.srcIn,
                  ),
                ),
              ),
              if (mapProgress > 0)
                CustomPaint(
                  painter: _ConnectionPainter(
                    source: srcScreen,
                    destination: dstScreen,
                    color: const Color(0xFF1EFFAC),
                    revealProgress: revealProgress,
                    packetProgress: packetProgress,
                  ),
                ),
              Positioned(
                left: srcScreen.dx - outerR,
                top: srcScreen.dy - outerR,
                child: _LocationDot(
                  color: const Color(0xFF60A5FA),
                  opacity: ui.lerpDouble(0.88, 1.0, focusProgress) ?? 1.0,
                ),
              ),
              Positioned(
                left: dstScreen.dx - outerR,
                top: dstScreen.dy - outerR,
                child: _LocationDot(color: const Color(0xFF1EFFAC), opacity: destinationOpacity),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                bottom: 0,
                child: Padding(
                  padding: contentPadding,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: PageReveal(
                        delay: const Duration(milliseconds: 110),
                        duration: const Duration(milliseconds: 240),
                        offset: const Offset(0, 0.05),
                        child: _ServerInfoPopup(
                          model: statusCard,
                          isConnected: isConnected,
                          isConnecting: isConnecting,
                          isSwitching: isSwitching,
                          downlink: downlink,
                          uplink: uplink,
                          onToggle: () => ref.read(connectionNotifierProvider.notifier).toggleConnection(),
                          serviceMode: serviceMode,
                          onModeChanged: (mode) => ref.read(ConfigOptions.serviceMode.notifier).update(mode),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Draws the curved arc and animated dash between two points.
class _ConnectionPainter extends CustomPainter {
  _ConnectionPainter({
    required this.source,
    required this.destination,
    required this.color,
    required this.revealProgress,
    required this.packetProgress,
  });

  final Offset source;
  final Offset destination;
  final Color color;
  final double revealProgress;
  final double packetProgress;

  @override
  void paint(Canvas canvas, Size size) {
    final delta = destination - source;
    if (delta.distanceSquared < 1) {
      return;
    }

    final controlPoint = Offset(
      (source.dx + destination.dx) / 2,
      math.min(source.dy, destination.dy) - math.max(60.0, delta.distance * 0.18),
    );
    final path = Path()
      ..moveTo(source.dx, source.dy)
      ..quadraticBezierTo(controlPoint.dx, controlPoint.dy, destination.dx, destination.dy);

    final metric = path.computeMetrics().first;
    final visibleLength = metric.length * revealProgress.clamp(0.0, 1.0);
    if (visibleLength <= 0.5) {
      return;
    }

    final visiblePath = metric.extractPath(0, visibleLength);

    canvas.drawPath(
      visiblePath,
      Paint()
        ..color = color.withValues(alpha: 0.12)
        ..strokeWidth = 10
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );
    canvas.drawPath(
      visiblePath,
      Paint()
        ..color = color.withValues(alpha: 0.35)
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );
    canvas.drawPath(
      visiblePath,
      Paint()
        ..color = color
        ..strokeWidth = 1.4
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );

    if (visibleLength < 20) {
      return;
    }

    const packetOffsets = [0.0, 0.33, 0.66];
    for (var i = 0; i < packetOffsets.length; i++) {
      final travel = (packetProgress + packetOffsets[i]) % 1.0;
      final packetOffset = visibleLength * travel;
      final tangent = metric.getTangentForOffset(packetOffset);
      if (tangent == null) {
        continue;
      }

      final center = tangent.position;
      final glowRadius = 5.4 - i;
      final coreRadius = 2.4 - (i * 0.3);

      canvas.drawCircle(center, glowRadius, Paint()..color = color.withValues(alpha: 0.14 + (0.05 * (2 - i))));
      canvas.drawCircle(center, coreRadius, Paint()..color = color.withValues(alpha: 0.9 - (i * 0.12)));
    }
  }

  @override
  bool shouldRepaint(_ConnectionPainter old) =>
      old.source != source ||
      old.destination != destination ||
      old.color != color ||
      old.revealProgress != revealProgress ||
      old.packetProgress != packetProgress;
}

/// A pulsing marker dot (returns SizedBox, NOT Positioned — caller handles positioning).
class _LocationDot extends StatelessWidget {
  const _LocationDot({required this.color, this.opacity = 1.0});

  final Color color;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    const dotR = 6.0;
    const outerR = 14.0;

    return Opacity(
      opacity: opacity,
      child: SizedBox(
        width: outerR * 2,
        height: outerR * 2,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
                  width: outerR * 2,
                  height: outerR * 2,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: color.withValues(alpha: 0.4), width: 1.5),
                  ),
                )
                .animate(onPlay: (c) => c.repeat())
                .scale(begin: const Offset(0.7, 0.7), end: const Offset(1.2, 1.2), duration: 1800.ms)
                .fadeOut(begin: 0.6, duration: 1800.ms),
            Container(
              width: dotR * 2,
              height: dotR * 2,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
                boxShadow: [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 8)],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatSpeed(int bytesPerSec) {
  if (bytesPerSec <= 0) return '0 KB/S';
  if (bytesPerSec >= 1024 * 1024) {
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(0)} MB/S';
  }
  return '${(bytesPerSec / 1024).toStringAsFixed(0)} KB/S';
}

String _describeIpInfo(IpInfo? ipInfo, {required String fallback}) {
  if (ipInfo == null) return fallback;
  final city = ipInfo.city?.trim();
  return city == null || city.isEmpty ? fallback : city;
}

class _ServerInfoPopup extends ConsumerWidget {
  const _ServerInfoPopup({
    required this.model,
    required this.isConnected,
    required this.isConnecting,
    required this.isSwitching,
    required this.downlink,
    required this.uplink,
    required this.onToggle,
    required this.serviceMode,
    required this.onModeChanged,
  });

  final HomeStatusCardModel model;
  final bool isConnected;
  final bool isConnecting;
  final bool isSwitching;
  final int downlink;
  final int uplink;
  final VoidCallback onToggle;
  final ServiceMode serviceMode;
  final ValueChanged<ServiceMode> onModeChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isBenchmarking = ref.watch(benchmarkActiveProvider);
    final autoSelectionProgress = ref.watch(autoServerSelectionProgressProvider);
    final proxyInfo = model.displayProxy;
    final type = proxyInfo?.type.toUpperCase() ?? '';
    final ping = proxyInfo?.urlTestDelay ?? 0;
    final currentIpInfo = isConnected ? model.currentIp : null;
    final shouldAnimateProgressStroke = isBenchmarking || isSwitching || autoSelectionProgress != null;
    final progressStrokeColor = isSwitching ? const Color(0xFFFFB457) : const Color(0xFF1EFFAC);
    final routeName = model.isAutoMode ? model.routeName : null;
    final headerSummary = <String>[
      if (routeName != null && routeName.isNotEmpty) routeName,
      if (ping > 0) '$ping мс',
    ].join(' · ');
    final throughputSummary = isConnected ? '↓ ${_formatSpeed(downlink)} · ↑ ${_formatSpeed(uplink)}' : null;

    if (isBenchmarking) {
      return _ProgressStrokeFrame(
        active: true,
        borderRadius: 20,
        color: progressStrokeColor,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: GlassPanel(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
            borderRadius: 20,
            backgroundColor: Colors.white,
            opacity: 0.07,
            strokeOpacity: 0.18,
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.24), blurRadius: 28, offset: const Offset(0, 8)),
            ],
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1EFFAC)),
                ),
                const Gap(10),
                const Text(
                  'Идёт тест серверов…',
                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return _ProgressStrokeFrame(
      active: shouldAnimateProgressStroke,
      borderRadius: 24,
      color: progressStrokeColor,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: GlassPanel(
          padding: EdgeInsets.zero,
          borderRadius: 24,
          backgroundColor: isConnected ? const Color(0xFF121715) : Colors.white,
          opacity: isConnected ? 0.82 : 0.07,
          strokeColor: isConnected ? const Color(0xFFDDEAAB) : const Color(0xFF1EFFAC),
          strokeOpacity: isConnected ? 0.3 : 0.18,
          strokeWidth: isConnected ? 1.15 : 1.0,
          showGlow: isConnected,
          glowBlur: isConnected ? 18 : 8,
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.24), blurRadius: 28, offset: const Offset(0, 8)),
            if (isConnected)
              BoxShadow(
                color: const Color(0xFFEFF6CC).withValues(alpha: 0.16),
                blurRadius: 28,
                spreadRadius: -8,
                offset: const Offset(-14, -10),
              ),
          ],
          child: _ConnectionCardSurface(
            isConnected: isConnected,
            isSwitching: isSwitching,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 18),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final isCompact = constraints.maxWidth < 520;
                  final sourceBlock = _InfoBlock(
                    label: 'Исходный IP',
                    value: model.sourceIp?.ip ?? '—',
                    detail: _describeIpInfo(model.sourceIp, fallback: 'Определяем внешний адрес…'),
                    accent: const Color(0xFF60A5FA),
                  );
                  final currentBlock = _InfoBlock(
                    label: 'Текущий IP',
                    value: currentIpInfo?.ip ?? '—',
                    detail: _describeIpInfo(
                      currentIpInfo,
                      fallback: isConnected ? 'Получаем маршрут…' : 'Появится после подключения',
                    ),
                    accent: isConnected ? const Color(0xFF1EFFAC) : Colors.white.withValues(alpha: 0.42),
                  );

                  Widget infoContent() {
                    if (isCompact) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          sourceBlock,
                          const Gap(12),
                          Container(height: 1, color: Colors.white.withValues(alpha: 0.06)),
                          const Gap(12),
                          currentBlock,
                        ],
                      );
                    }

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: sourceBlock),
                        const _InfoDivider(),
                        const Gap(16),
                        Expanded(child: currentBlock),
                      ],
                    );
                  }

                  return SizedBox(
                    width: double.infinity,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      model.title,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 24,
                                        fontWeight: FontWeight.w800,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    if (type.isNotEmpty || model.isAutoMode) ...[
                                      const Gap(8),
                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 6,
                                        children: [
                                          if (type.isNotEmpty) _GlassBadge(label: type, color: const Color(0xFF60A5FA)),
                                          if (model.isAutoMode)
                                            const _GlassBadge(label: 'AUTO', color: Color(0xFF1EFFAC)),
                                        ],
                                      ),
                                    ],
                                    if (headerSummary.isNotEmpty) ...[
                                      const Gap(6),
                                      Text(
                                        headerSummary,
                                        style: TextStyle(
                                          color: Colors.white.withValues(alpha: 0.76),
                                          fontSize: 13.2,
                                          fontWeight: FontWeight.w600,
                                          height: 1.35,
                                        ),
                                      ),
                                    ],
                                    if (model.statusText case final statusText?) ...[
                                      const Gap(4),
                                      Text(
                                        statusText,
                                        style: TextStyle(
                                          color: Colors.white.withValues(alpha: 0.60),
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w500,
                                          height: 1.35,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const Gap(18),
                              _PowerButton(
                                isConnected: isConnected,
                                isConnecting: isConnecting,
                                isSwitching: isSwitching,
                                onTap: onToggle,
                              ),
                            ],
                          ),
                          const Gap(14),
                          Align(
                            alignment: Alignment.center,
                            child: Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 18,
                              runSpacing: 8,
                              children: ServiceMode.values.map((mode) {
                                final selected = mode == serviceMode;
                                return _ModeTextButton(
                                  label: switch (mode) {
                                    ServiceMode.mixed => 'Proxy',
                                    ServiceMode.systemProxy => 'System',
                                    ServiceMode.tun => 'TUN',
                                  },
                                  selected: selected,
                                  onTap: selected ? null : () => onModeChanged(mode),
                                );
                              }).toList(),
                            ),
                          ),
                          const Gap(16),
                          Container(height: 1, color: Colors.white.withValues(alpha: 0.08)),
                          const Gap(14),
                          infoContent(),
                          if (throughputSummary case final summary?) ...[
                            const Gap(14),
                            Text(
                              summary,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.58),
                                fontSize: 12.4,
                                fontWeight: FontWeight.w600,
                                height: 1.3,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ConnectionCardSurface extends StatelessWidget {
  const _ConnectionCardSurface({required this.isConnected, required this.isSwitching, required this.child});

  final bool isConnected;
  final bool isSwitching;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final highlighted = isConnected || isSwitching;
    final borderRadius = BorderRadius.circular(24);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: highlighted
              ? const [Color(0xFF181C1A), Color(0xFF17221E), Color(0xFF173228)]
              : const [Color(0xFF171918), Color(0xFF151817), Color(0xFF141715)],
          stops: const [0.0, 0.56, 1.0],
        ),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: borderRadius,
                  gradient: RadialGradient(
                    center: const Alignment(-1.05, -1.08),
                    radius: highlighted ? 1.1 : 0.88,
                    colors: [
                      const Color(0xFFF3F8D6).withValues(alpha: highlighted ? 0.16 : 0.08),
                      const Color(0xFFBDE894).withValues(alpha: highlighted ? 0.10 : 0.04),
                      const Color(0xFF1EFFAC).withValues(alpha: highlighted ? 0.05 : 0.02),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.18, 0.42, 1.0],
                  ),
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _ProgressStrokeFrame extends HookWidget {
  const _ProgressStrokeFrame({
    required this.active,
    required this.borderRadius,
    required this.color,
    required this.child,
  });

  final bool active;
  final double borderRadius;
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final controller = useAnimationController(duration: const Duration(milliseconds: 3400));

    useEffect(() {
      if (active) {
        controller.repeat(reverse: true);
      } else {
        controller
          ..stop()
          ..value = 0;
      }
      return null;
    }, [active]);

    final animationValue = useAnimation(controller);

    return CustomPaint(
      foregroundPainter: active
          ? _TravelStrokePainter(progress: animationValue, borderRadius: borderRadius, color: color)
          : null,
      child: child,
    );
  }
}

class _TravelStrokePainter extends CustomPainter {
  const _TravelStrokePainter({required this.progress, required this.borderRadius, required this.color});

  final double progress;
  final double borderRadius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final left = borderRadius * 0.72;
    final right = size.width - borderRadius * 0.72;
    const y = 1.35;
    if (right <= left) return;

    final rect = Rect.fromLTRB(left, y, right, y + 2);
    final easedProgress = Curves.easeInOutSine.transform(progress.clamp(0.0, 1.0));
    final travel = ui.lerpDouble(0.16, 0.42, easedProgress) ?? 0.28;
    final breath = math.sin(easedProgress * math.pi);
    final warmTone = Color.lerp(const Color(0xFFEFF7CA), color, 0.36) ?? const Color(0xFFEFF7CA);
    final coolTone = Color.lerp(const Color(0xFF8BE2B3), color, 0.52) ?? color;
    final basePaint = Paint()
      ..color = warmTone.withValues(alpha: 0.03 + (breath * 0.015))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(Offset(left, y), Offset(right, y), basePaint);

    final leftShoulder = (travel - 0.12).clamp(0.04, 0.24);
    final rightShoulder = (travel + 0.14).clamp(0.24, 0.56);
    final farFade = (travel + 0.26).clamp(0.34, 0.72);
    final warmAlpha = 0.18 + (breath * 0.04);
    final coolAlpha = 0.24 + (breath * 0.06);
    final peakAlpha = 0.30 + (breath * 0.06);

    final highlightPaint = Paint()
      ..shader = ui.Gradient.linear(
        rect.topLeft,
        rect.topRight,
        [
          warmTone.withValues(alpha: warmAlpha),
          coolTone.withValues(alpha: coolAlpha),
          color.withValues(alpha: peakAlpha),
          coolTone.withValues(alpha: 0.08 + (breath * 0.03)),
          Colors.transparent,
        ],
        [0.0, leftShoulder, travel, rightShoulder, farFade],
      )
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);

    canvas.drawLine(Offset(left, y), Offset(right, y), highlightPaint);
  }

  @override
  bool shouldRepaint(_TravelStrokePainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.borderRadius != borderRadius || oldDelegate.color != color;
}

class _InfoBlock extends StatelessWidget {
  const _InfoBlock({required this.label, required this.value, required this.detail, required this.accent});

  final String label;
  final String value;
  final String detail;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.46), fontSize: 10.5, fontWeight: FontWeight.w600),
        ),
        const Gap(5),
        Text(
          value,
          style: TextStyle(color: accent, fontSize: 19, fontWeight: FontWeight.w800),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const Gap(5),
        Text(
          detail,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.66), fontSize: 11.8, height: 1.38),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _InfoDivider extends StatelessWidget {
  const _InfoDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 58,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      color: Colors.white.withValues(alpha: 0.08),
    );
  }
}

class _ModeTextButton extends StatelessWidget {
  const _ModeTextButton({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: selected ? const Color(0xFF1EFFAC) : Colors.transparent, width: 1.6),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? const Color(0xFF1EFFAC) : Colors.white.withValues(alpha: 0.55),
            fontSize: 11.5,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _PowerButton extends StatelessWidget {
  const _PowerButton({
    required this.isConnected,
    required this.isConnecting,
    required this.isSwitching,
    required this.onTap,
  });

  final bool isConnected;
  final bool isConnecting;
  final bool isSwitching;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = switch ((isConnected, isSwitching)) {
      (_, true) => const Color(0xFFFFB457),
      (true, false) => const Color(0xFF1EFFAC),
      (false, false) => const Color(0xFFFF5F5F),
    };

    return GestureDetector(
      onTap: (isSwitching && !isConnecting) ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        width: 52,
        height: 52,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: color.withValues(alpha: isConnected ? 0.14 : 0.09),
          border: Border.all(color: color.withValues(alpha: 0.65)),
        ),
        child: isConnecting
            ? Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2, color: color.withValues(alpha: 0.92)),
                  ),
                  Icon(Icons.close_rounded, size: 16, color: color),
                ],
              )
            : SvgPicture.asset(
                'assets/images/power.svg',
                width: 22,
                height: 22,
                colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
              ),
      ),
    );
  }
}

class _GlassBadge extends StatelessWidget {
  const _GlassBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      backgroundColor: Colors.white,
      opacity: 0.04,
      borderRadius: 15,
      strokeColor: color,
      strokeOpacity: 0.34,
      strokeWidth: 0.9,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 0.3),
      ),
    );
  }
}

