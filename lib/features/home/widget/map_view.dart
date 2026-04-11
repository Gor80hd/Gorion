import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:gap/gap.dart';
import 'package:gorion_clean/app/theme.dart';
import 'package:gorion_clean/core/widget/emoji_flag_text.dart';
import 'package:gorion_clean/core/widget/glass_panel.dart';
import 'package:gorion_clean/core/widget/page_reveal.dart';
import 'package:gorion_clean/features/auto_select/model/auto_select_state.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/home/utils/map_location_resolver.dart';
import 'package:gorion_clean/features/runtime/model/connection_status.dart';
import 'package:gorion_clean/features/runtime/notifier/connection_notifier.dart';
import 'package:gorion_clean/features/home/notifier/auto_server_selection_progress.dart';
import 'package:gorion_clean/features/home/widget/cobe_style_globe.dart';
import 'package:gorion_clean/features/home/notifier/home_status_card_provider.dart';
import 'package:gorion_clean/features/home/widget/selected_server_preview_provider.dart';
import 'package:gorion_clean/features/intro/utils/region_detector.dart';
import 'package:gorion_clean/features/proxy/model/ip_info_entity.dart';
import 'package:gorion_clean/features/proxy/notifier/ip_info_notifier.dart';
import 'package:gorion_clean/features/proxy/utils/ip_info_display.dart';
import 'package:gorion_clean/core/preferences/general_preferences.dart';
import 'package:gorion_clean/features/stats/notifier/stats_notifier.dart';
import 'package:gorion_clean/features/settings/model/singbox_config_enum.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

(double, double) _resolveLocalFallbackLatLon() {
  final locales = WidgetsBinding.instance.platformDispatcher.locales;
  for (final locale in locales) {
    final code = locale.countryCode;
    if (hasCountryLatLon(code)) {
      return lookupCountryLatLon(code);
    }
  }

  final detectedCountry = RegionDetector.detect();
  if (hasCountryLatLon(detectedCountry)) {
    return lookupCountryLatLon(detectedCountry);
  }

  return defaultMapFallbackLatLon;
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

  final EdgeInsets contentPadding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
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
    final keepSourceAnchored = isConnected || isSwitching;
    final shouldUseLocalSource = serviceMode == ServiceMode.systemProxy;
    final sourceAnchor = useState<IpInfo?>(null);
    final mapTransition = useAnimationController(
      duration: const Duration(milliseconds: 1200),
    );
    final packetTravel = useAnimationController(
      duration: const Duration(milliseconds: 3200),
    );

    final sourceInfo = directIpInfo.valueOrNull;
    final routedInfo = routedIpInfo.valueOrNull;
    final activeProxyInfo = activeProxy.valueOrNull;
    final selectedProxy =
        statusCard.displayProxy ??
        (activeProxyInfo?.tag.isNotEmpty == true ? activeProxyInfo : null);
    final destCountry =
        routedInfo?.countryCode ??
        sourceInfo?.countryCode ??
        sourceAnchor.value?.countryCode;

    useEffect(
      () {
        if (sourceInfo != null &&
            !_sameIpInfo(sourceAnchor.value, sourceInfo)) {
          sourceAnchor.value = sourceInfo;
        }
        return null;
      },
      [
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

    final uplink = statsAsync.valueOrNull?.uplink ?? 0;
    final downlink = statsAsync.valueOrNull?.downlink ?? 0;

    final srcLatLon = shouldUseLocalSource
        ? _resolveLocalFallbackLatLon()
        : resolveSourceLatLon(sourceInfo ?? sourceAnchor.value);
    final dstLatLon = resolveDestinationLatLon(selectedProxy, destCountry);

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth == 0 || constraints.maxHeight == 0) {
          return const SizedBox.expand();
        }

        final focusProgress = Curves.easeInOutCubicEmphasized.transform(
          mapProgress,
        );
        final revealProgress = Curves.easeOutCubic.transform(
          ((mapProgress - 0.1) / 0.9).clamp(0.0, 1.0),
        );

        return SizedBox.expand(
          child: Stack(
            fit: StackFit.expand,
            children: [
              CobeStyleGlobe(
                contentPadding: contentPadding,
                sourceLatLon: srcLatLon,
                destinationLatLon: dstLatLon,
                focusProgress: focusProgress,
                revealProgress: revealProgress,
                packetProgress: packetProgress,
                showConnection: keepSourceAnchored,
                isConnected: isConnected,
                sourceColor: const Color(0xFF60A5FA),
                destinationColor: theme.brandAccent,
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
                          onToggle: () => ref
                              .read(connectionNotifierProvider.notifier)
                              .toggleConnection(),
                          serviceMode: serviceMode,
                          onModeChanged: (mode) => ref
                              .read(ConfigOptions.serviceMode.notifier)
                              .update(mode),
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

String _formatSpeed(int bytesPerSec) {
  if (bytesPerSec <= 0) return '0 KB/S';
  if (bytesPerSec >= 1024 * 1024) {
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(0)} MB/S';
  }
  return '${(bytesPerSec / 1024).toStringAsFixed(0)} KB/S';
}

List<ServiceMode> _visibleServiceModes() {
  if (defaultTargetPlatform == TargetPlatform.windows) {
    return const [ServiceMode.systemProxy, ServiceMode.tun];
  }
  return const [ServiceMode.mixed, ServiceMode.tun];
}

String _serviceModeLabel(ServiceMode mode) {
  return switch (mode) {
    ServiceMode.mixed => 'Proxy',
    ServiceMode.systemProxy => 'Системный прокси',
    ServiceMode.tun => 'TUN',
  };
}

class _ServerInfoPopup extends HookConsumerWidget {
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;
    final dashboardState = ref.watch(dashboardControllerProvider);
    final visibleServiceModes = _visibleServiceModes();
    final isBenchmarking = ref.watch(benchmarkActiveProvider);
    final autoSelectionProgress = ref.watch(
      autoServerSelectionProgressProvider,
    );
    final connectedAt = dashboardState.connectedAt;
    final lastBestServerCheckAt = dashboardState.lastBestServerCheckAt;
    final bestServerCheckRunning = _isBestServerCheckActivity(
      dashboardState.autoSelectActivity,
    );
    final proxyInfo = model.displayProxy;
    final type = proxyInfo?.type.toUpperCase() ?? '';
    final showSessionTimerTag = isConnected && connectedAt != null;
    final showBestServerCheck =
        isConnected &&
        (lastBestServerCheckAt != null || bestServerCheckRunning);
    final showMetaTags =
        type.isNotEmpty ||
        model.isAutoMode ||
        showSessionTimerTag ||
        showBestServerCheck;
    final timerNow = useState(DateTime.now());
    final ping = model.showTargetSummary ? proxyInfo?.urlTestDelay ?? 0 : 0;
    final currentIpInfo = isConnected ? model.currentIp : null;
    final shouldAnimateProgressStroke =
        isBenchmarking || isSwitching || autoSelectionProgress != null;
    final progressStrokeColor = isSwitching
        ? const Color(0xFFFFB457)
        : scheme.primary;
    final routeName = model.isAutoMode && model.showTargetSummary
        ? model.routeName
        : null;
    final headerSummary = <String>[
      if (routeName != null && routeName.isNotEmpty) routeName,
      if (ping > 0) '$ping мс',
    ].join(' · ');
    final throughputSummary = isConnected
        ? '↓ ${_formatSpeed(downlink)} · ↑ ${_formatSpeed(uplink)}'
        : null;

    useEffect(
      () {
        if (!showSessionTimerTag && !showBestServerCheck) {
          return null;
        }

        timerNow.value = DateTime.now();
        final timer = Timer.periodic(const Duration(seconds: 1), (_) {
          timerNow.value = DateTime.now();
        });
        return timer.cancel;
      },
      [
        showSessionTimerTag,
        showBestServerCheck,
        connectedAt,
        lastBestServerCheckAt,
        bestServerCheckRunning,
      ],
    );

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
              BoxShadow(
                color: theme.shadowColor.withValues(alpha: 0.24),
                blurRadius: 28,
                offset: const Offset(0, 8),
              ),
            ],
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
                const Gap(10),
                Text(
                  'Идёт тест серверов…',
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
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
          backgroundColor: Colors.white,
          opacity: 0.05,
          strokeColor: Colors.white,
          strokeOpacity: 0.08,
          strokeWidth: 1,
          showGlow: false,
          glowBlur: 8,
          boxShadow: [
            BoxShadow(
              color: theme.shadowColor.withValues(alpha: 0.22),
              blurRadius: 20,
              offset: const Offset(0, 14),
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
                  final needsScrollableCard =
                      constraints.maxWidth < 280 || constraints.maxHeight < 360;
                  final sourceBlock = _InfoBlock(
                    label: 'Исходный IP',
                    value: model.sourceIp?.ip ?? '—',
                    detail: describeIpInfo(
                      model.sourceIp,
                      fallback: 'Определяем внешний адрес…',
                    ),
                    accent: const Color(0xFF60A5FA),
                  );
                  final currentBlock = _InfoBlock(
                    label: 'Текущий IP',
                    value: currentIpInfo?.ip ?? '—',
                    detail: describeIpInfo(
                      currentIpInfo,
                      fallback: isConnected
                          ? 'Получаем маршрут…'
                          : 'Появится после подключения',
                    ),
                    accent: isConnected
                        ? scheme.primary
                        : muted.withValues(alpha: 0.7),
                  );

                  Widget infoContent() {
                    if (isCompact) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          sourceBlock,
                          const Gap(12),
                          Container(
                            height: 1,
                            color: scheme.onSurface.withValues(alpha: 0.06),
                          ),
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

                  final cardContent = Column(
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
                                EmojiFlagText(
                                  model.title,
                                  style: TextStyle(
                                    color: scheme.onSurface,
                                    fontSize: 24,
                                    fontWeight: FontWeight.w800,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (showMetaTags) ...[
                                  const Gap(8),
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    children: [
                                      if (type.isNotEmpty)
                                        _GlassBadge(
                                          label: type,
                                          color: const Color(0xFF60A5FA),
                                        ),
                                      if (model.isAutoMode)
                                        _GlassBadge(
                                          label: 'AUTO',
                                          color: scheme.primary,
                                        ),
                                      if (showSessionTimerTag)
                                        _ConnectionTimerPill(
                                          title: 'Сессия',
                                          value: _formatElapsed(
                                            _elapsedSince(
                                              connectedAt,
                                              timerNow.value,
                                            ),
                                          ),
                                          color: scheme.primary,
                                        ),
                                      if (showBestServerCheck)
                                        _ConnectionTimerPill(
                                          title: 'Best server',
                                          value: lastBestServerCheckAt != null
                                              ? _formatElapsed(
                                                  _elapsedSince(
                                                    lastBestServerCheckAt,
                                                    timerNow.value,
                                                  ),
                                                )
                                              : 'идёт',
                                          color: bestServerCheckRunning
                                              ? const Color(0xFFFFB457)
                                              : const Color(0xFF60A5FA),
                                        ),
                                    ],
                                  ),
                                ],
                                if (headerSummary.isNotEmpty) ...[
                                  const Gap(6),
                                  EmojiFlagText(
                                    headerSummary,
                                    style: TextStyle(
                                      color: scheme.onSurface.withValues(
                                        alpha: 0.76,
                                      ),
                                      fontSize: 13.2,
                                      fontWeight: FontWeight.w600,
                                      height: 1.35,
                                    ),
                                  ),
                                ],
                                if (model.statusText
                                    case final statusText?) ...[
                                  const Gap(4),
                                  EmojiFlagText(
                                    statusText,
                                    style: TextStyle(
                                      color: muted.withValues(alpha: 0.95),
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
                      if (model.alertText case final alertText?) ...[
                        const Gap(14),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0x33FF8A80),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: const Color(0x66FF8A80)),
                          ),
                          child: EmojiFlagText(
                            alertText,
                            style: const TextStyle(
                              color: Color(0xFFFFD8D4),
                              fontSize: 12.8,
                              fontWeight: FontWeight.w600,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                      const Gap(14),
                      Align(
                        alignment: Alignment.center,
                        child: Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 18,
                          runSpacing: 8,
                          children: visibleServiceModes.map((mode) {
                            final selected = mode == serviceMode;
                            return _ModeTextButton(
                              label: _serviceModeLabel(mode),
                              selected: selected,
                              onTap: selected
                                  ? null
                                  : () => onModeChanged(mode),
                            );
                          }).toList(),
                        ),
                      ),
                      const Gap(16),
                      Container(
                        height: 1,
                        color: scheme.onSurface.withValues(alpha: 0.08),
                      ),
                      const Gap(14),
                      infoContent(),
                      if (throughputSummary case final summary?) ...[
                        const Gap(14),
                        Text(
                          summary,
                          style: TextStyle(
                            color: muted.withValues(alpha: 0.95),
                            fontSize: 12.4,
                            fontWeight: FontWeight.w600,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ],
                  );

                  return SizedBox(
                    width: double.infinity,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      child: needsScrollableCard
                          ? SingleChildScrollView(
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  minWidth: constraints.maxWidth,
                                ),
                                child: cardContent,
                              ),
                            )
                          : cardContent,
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
  const _ConnectionCardSurface({
    required this.isConnected,
    required this.isSwitching,
    required this.child,
  });

  final bool isConnected;
  final bool isSwitching;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return child;
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
    final controller = useAnimationController(
      duration: const Duration(milliseconds: 3400),
    );

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
          ? _TravelStrokePainter(
              progress: animationValue,
              borderRadius: borderRadius,
              color: color,
            )
          : null,
      child: child,
    );
  }
}

class _TravelStrokePainter extends CustomPainter {
  const _TravelStrokePainter({
    required this.progress,
    required this.borderRadius,
    required this.color,
  });

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
    final easedProgress = Curves.easeInOutSine.transform(
      progress.clamp(0.0, 1.0),
    );
    final travel = ui.lerpDouble(0.16, 0.42, easedProgress) ?? 0.28;
    final breath = math.sin(easedProgress * math.pi);
    final warmTone =
        Color.lerp(const Color(0xFFEFF7CA), color, 0.36) ??
        const Color(0xFFEFF7CA);
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
      oldDelegate.progress != progress ||
      oldDelegate.borderRadius != borderRadius ||
      oldDelegate.color != color;
}

class _InfoBlock extends StatelessWidget {
  const _InfoBlock({
    required this.label,
    required this.value,
    required this.detail,
    required this.accent,
  });

  final String label;
  final String value;
  final String detail;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: theme.gorionTokens.onSurfaceMuted.withValues(alpha: 0.78),
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        const Gap(5),
        Text(
          value,
          style: TextStyle(
            color: accent,
            fontSize: 19,
            fontWeight: FontWeight.w800,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const Gap(5),
        Text(
          detail,
          style: TextStyle(
            color: theme.gorionTokens.onSurfaceMuted.withValues(alpha: 0.95),
            fontSize: 11.8,
            height: 1.38,
          ),
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
    final color = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.08);
    return Container(
      width: 1,
      height: 58,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      color: color,
    );
  }
}

class _ModeTextButton extends StatelessWidget {
  const _ModeTextButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? scheme.primary : Colors.transparent,
              width: 1.6,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected
                ? scheme.primary
                : theme.gorionTokens.onSurfaceMuted.withValues(alpha: 0.9),
            fontSize: 11.5,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _ConnectionTimerPill extends StatelessWidget {
  const _ConnectionTimerPill({
    required this.title,
    required this.value,
    required this.color,
  });

  final String title;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).gorionTokens.onSurfaceMuted;
    return GlassPanel(
      backgroundColor: Colors.white,
      opacity: 0.04,
      borderRadius: 15,
      strokeColor: color,
      strokeOpacity: 0.3,
      strokeWidth: 0.9,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: TextStyle(
              color: muted.withValues(alpha: 0.95),
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
          const Gap(6),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 10.9,
              fontWeight: FontWeight.w800,
              height: 1,
              letterSpacing: 0.2,
            ),
          ),
        ],
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
    final primary = Theme.of(context).colorScheme.primary;
    final color = switch ((isConnected, isSwitching)) {
      (_, true) => const Color(0xFFFFB457),
      (true, false) => primary,
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
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: color.withValues(alpha: 0.92),
                    ),
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
        style: TextStyle(
          color: color,
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

bool _isBestServerCheckActivity(AutoSelectActivityState activity) {
  if (!activity.active) {
    return false;
  }

  return activity.label == 'Pre-connect auto-select' ||
      activity.label == 'Manual auto-select' ||
      activity.label == 'Automatic maintenance';
}

Duration _elapsedSince(DateTime start, DateTime now) {
  final elapsed = now.difference(start);
  return elapsed.isNegative ? Duration.zero : elapsed;
}

String _formatElapsed(Duration value) {
  String two(int n) => n.toString().padLeft(2, '0');
  final hours = value.inHours;
  final minutes = value.inMinutes.remainder(60);
  final seconds = value.inSeconds.remainder(60);
  if (hours > 0) {
    return '${two(hours)}:${two(minutes)}:${two(seconds)}';
  }
  return '${two(minutes)}:${two(seconds)}';
}
