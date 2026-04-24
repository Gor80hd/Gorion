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
            ],
          ),
        );
      },
    );
  }
}

String _formatSpeed(int bytesPerSec) {
  if (bytesPerSec <= 0) return '0 KB/s';
  if (bytesPerSec >= 1024 * 1024) {
    final value = bytesPerSec / (1024 * 1024);
    return '${value.toStringAsFixed(value >= 10 ? 1 : 2)} MB/s';
  }
  return '${(bytesPerSec / 1024).toStringAsFixed(0)} KB/s';
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
    ServiceMode.systemProxy => 'Proxy',
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
    final displayedIpInfo = isConnected ? currentIpInfo : model.sourceIp;
    final protocolLabel = type.isEmpty ? '—' : type;
    final protocolDetail = proxyInfo == null
        ? 'Сервер не выбран'
        : model.isAutoMode
        ? 'Автовыбор сервера'
        : 'Активный сервер';
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
    final statusAccent = isSwitching
        ? const Color(0xFFFFB457)
        : isConnected
        ? scheme.primary
        : muted.withValues(alpha: 0.82);
    final connectionLabel = isSwitching
        ? 'Переключаем маршрут'
        : isConnecting
        ? 'Подключаемся'
        : isConnected
        ? 'Подключение защищено'
        : 'Подключение отключено';

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
      borderRadius: 28,
      color: progressStrokeColor,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: GlassPanel(
          padding: EdgeInsets.zero,
          borderRadius: 28,
          backgroundColor: Colors.white,
          opacity: 0.055,
          strokeColor: Colors.white,
          strokeOpacity: 0.10,
          strokeWidth: 1,
          showGlow: false,
          glowBlur: 8,
          boxShadow: [
            BoxShadow(
              color: theme.shadowColor.withValues(alpha: 0.26),
              blurRadius: 30,
              offset: const Offset(0, 18),
            ),
          ],
          child: _ConnectionCardSurface(
            isConnected: isConnected,
            isSwitching: isSwitching,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(26, 22, 26, 22),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final isCompact = constraints.maxWidth < 620;
                  final isTiny = constraints.maxWidth < 420;
                  final needsScrollableCard =
                      isTiny || constraints.maxHeight < 420;
                  final ipBlock = _InfoBlock(
                    label: 'Ваш IP',
                    value: displayedIpInfo?.ip ?? '—',
                    detail: describeIpInfo(
                      displayedIpInfo,
                      fallback: isConnected
                          ? 'Получаем IP сервера…'
                          : 'Определяем внешний адрес…',
                    ),
                    accent: isConnected
                        ? scheme.primary
                        : const Color(0xFF60A5FA),
                  );
                  final protocolBlock = _InfoBlock(
                    label: 'Протокол',
                    value: protocolLabel,
                    detail: protocolDetail,
                    accent: const Color(0xFF60A5FA),
                  );
                  final modeBlock = _ModeControlBlock(
                    serviceMode: serviceMode,
                    modes: visibleServiceModes,
                    onModeChanged: onModeChanged,
                  );

                  Widget infoContent() {
                    if (isCompact) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ipBlock,
                          const Gap(12),
                          Container(
                            height: 1,
                            color: scheme.onSurface.withValues(alpha: 0.06),
                          ),
                          const Gap(12),
                          protocolBlock,
                          const Gap(12),
                          Container(
                            height: 1,
                            color: scheme.onSurface.withValues(alpha: 0.06),
                          ),
                          const Gap(12),
                          modeBlock,
                        ],
                      );
                    }

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: ipBlock),
                        const _InfoDivider(),
                        const Gap(16),
                        Expanded(child: protocolBlock),
                        const _InfoDivider(),
                        const Gap(16),
                        Expanded(child: modeBlock),
                      ],
                    );
                  }

                  final titleContent = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _ConnectionStateLabel(
                        label: connectionLabel,
                        color: statusAccent,
                        icon: isConnected
                            ? Icons.lock_outline_rounded
                            : isSwitching || isConnecting
                            ? Icons.sync_rounded
                            : Icons.lock_open_rounded,
                      ),
                      const Gap(12),
                      EmojiFlagText(
                        model.title,
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontSize: isTiny ? 22 : 28,
                          fontWeight: FontWeight.w800,
                          height: 1.04,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (showMetaTags) ...[
                        const Gap(10),
                        Wrap(
                          spacing: 7,
                          runSpacing: 7,
                          children: [
                            if (type.isNotEmpty)
                              _GlassBadge(
                                label: type,
                                color: const Color(0xFF60A5FA),
                              ),
                            if (model.isAutoMode)
                              _GlassBadge(label: 'AUTO', color: scheme.primary),
                            if (showSessionTimerTag)
                              _ConnectionTimerPill(
                                title: 'Сессия',
                                value: _formatElapsed(
                                  _elapsedSince(connectedAt, timerNow.value),
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
                        const Gap(7),
                        EmojiFlagText(
                          headerSummary,
                          style: TextStyle(
                            color: scheme.onSurface.withValues(alpha: 0.76),
                            fontSize: 13.2,
                            fontWeight: FontWeight.w600,
                            height: 1.35,
                          ),
                        ),
                      ],
                      if (model.statusText case final statusText?) ...[
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
                  );

                  final headerContent = isTiny
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            titleContent,
                            const Gap(16),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: _PowerButton(
                                isConnected: isConnected,
                                isConnecting: isConnecting,
                                isSwitching: isSwitching,
                                onTap: onToggle,
                              ),
                            ),
                          ],
                        )
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(child: titleContent),
                            const Gap(22),
                            _PowerButton(
                              isConnected: isConnected,
                              isConnecting: isConnecting,
                              isSwitching: isSwitching,
                              onTap: onToggle,
                            ),
                          ],
                        );

                  final cardContent = Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      headerContent,
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
                      const Gap(16),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                        decoration: BoxDecoration(
                          color: scheme.onSurface.withValues(
                            alpha: theme.brightness == Brightness.dark
                                ? 0.035
                                : 0.045,
                          ),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: scheme.onSurface.withValues(alpha: 0.07),
                            width: 0.8,
                          ),
                        ),
                        child: infoContent(),
                      ),
                      const Gap(16),
                      _TrafficPanel(
                        downlink: downlink,
                        uplink: uplink,
                        active: isConnected || isSwitching || isConnecting,
                        accent: scheme.primary,
                      ),
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

class _ConnectionStateLabel extends StatelessWidget {
  const _ConnectionStateLabel({
    required this.label,
    required this.color,
    required this.icon,
  });

  final String label;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const Gap(8),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
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

class _ModeControlBlock extends StatelessWidget {
  const _ModeControlBlock({
    required this.serviceMode,
    required this.modes,
    required this.onModeChanged,
  });

  final ServiceMode serviceMode;
  final List<ServiceMode> modes;
  final ValueChanged<ServiceMode> onModeChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.gorionTokens.onSurfaceMuted;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Режим',
          style: TextStyle(
            color: muted.withValues(alpha: 0.78),
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        const Gap(8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final mode in modes)
              _ModeChipButton(
                label: _serviceModeLabel(mode),
                icon: mode.usesTun
                    ? Icons.hub_outlined
                    : Icons.swap_horiz_rounded,
                selected: mode == serviceMode,
                onTap: mode == serviceMode ? null : () => onModeChanged(mode),
              ),
          ],
        ),
        const Gap(7),
        Text(
          'Маршрутизация трафика',
          style: TextStyle(
            color: muted.withValues(alpha: 0.95),
            fontSize: 11.8,
            height: 1.38,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _TrafficPanel extends StatelessWidget {
  const _TrafficPanel({
    required this.downlink,
    required this.uplink,
    required this.active,
    required this.accent,
  });

  final int downlink;
  final int uplink;
  final bool active;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final uploadAccent = theme.brightness == Brightness.dark
        ? const Color(0xFFFF7AA8)
        : const Color(0xFFC43C70);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 15, 18, 15),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(
          alpha: theme.brightness == Brightness.dark ? 0.035 : 0.045,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: scheme.onSurface.withValues(alpha: 0.07),
          width: 0.8,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isCompact = constraints.maxWidth < 460;
          final graph = SizedBox(
            height: 52,
            child: _TrafficSparkline(
              active: active,
              downlink: downlink,
              uplink: uplink,
              accent: accent,
              uploadAccent: uploadAccent,
            ),
          );

          if (isCompact) {
            return Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _TrafficValue(
                        icon: Icons.arrow_downward_rounded,
                        label: 'Загрузка',
                        value: _formatSpeed(downlink),
                        color: accent,
                      ),
                    ),
                    const Gap(12),
                    Expanded(
                      child: _TrafficValue(
                        icon: Icons.arrow_upward_rounded,
                        label: 'Отдача',
                        value: _formatSpeed(uplink),
                        color: uploadAccent,
                        alignEnd: true,
                      ),
                    ),
                  ],
                ),
                const Gap(10),
                graph,
              ],
            );
          }

          return Row(
            children: [
              SizedBox(
                width: 138,
                child: _TrafficValue(
                  icon: Icons.arrow_downward_rounded,
                  label: 'Загрузка',
                  value: _formatSpeed(downlink),
                  color: accent,
                ),
              ),
              const Gap(18),
              Expanded(child: graph),
              const Gap(18),
              SizedBox(
                width: 138,
                child: _TrafficValue(
                  icon: Icons.arrow_upward_rounded,
                  label: 'Отдача',
                  value: _formatSpeed(uplink),
                  color: uploadAccent,
                  alignEnd: true,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TrafficValue extends StatelessWidget {
  const _TrafficValue({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    this.alignEnd = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).gorionTokens.onSurfaceMuted;
    return LayoutBuilder(
      builder: (context, constraints) {
        final showIcon = constraints.maxWidth >= 48;
        final valueFontSize = constraints.maxWidth < 92 ? 16.0 : 22.0;

        return Column(
          crossAxisAlignment: alignEnd
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: alignEnd
                  ? MainAxisAlignment.end
                  : MainAxisAlignment.start,
              children: [
                if (showIcon) ...[
                  Icon(icon, size: 20, color: color),
                  const Gap(8),
                ],
                Flexible(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontSize: valueFontSize,
                      fontWeight: FontWeight.w800,
                      height: 1,
                    ),
                  ),
                ),
              ],
            ),
            const Gap(8),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: muted.withValues(alpha: 0.88),
                fontSize: constraints.maxWidth < 92 ? 10.5 : 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        );
      },
    );
  }
}

const _trafficHistoryLength = 32;

class _TrafficSample {
  const _TrafficSample({required this.downlink, required this.uplink});

  final int downlink;
  final int uplink;
}

List<_TrafficSample> _emptyTrafficHistory() => List<_TrafficSample>.filled(
  _trafficHistoryLength,
  const _TrafficSample(downlink: 0, uplink: 0),
);

class _TrafficSparkline extends HookWidget {
  const _TrafficSparkline({
    required this.active,
    required this.downlink,
    required this.uplink,
    required this.accent,
    required this.uploadAccent,
  });

  final bool active;
  final int downlink;
  final int uplink;
  final Color accent;
  final Color uploadAccent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final latestActive = useRef(active);
    final latestDownlink = useRef(downlink);
    final latestUplink = useRef(uplink);
    final samples = useState<List<_TrafficSample>>(_emptyTrafficHistory());

    void appendSample() {
      final sample = latestActive.value
          ? _TrafficSample(
              downlink: latestDownlink.value,
              uplink: latestUplink.value,
            )
          : const _TrafficSample(downlink: 0, uplink: 0);
      final next = [...samples.value, sample];
      if (next.length > _trafficHistoryLength) {
        next.removeRange(0, next.length - _trafficHistoryLength);
      }
      samples.value = List.unmodifiable(next);
    }

    useEffect(() {
      latestActive.value = active;
      latestDownlink.value = downlink;
      latestUplink.value = uplink;
      appendSample();
      return null;
    }, [active, downlink, uplink]);

    useEffect(() {
      final timer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => appendSample(),
      );
      return timer.cancel;
    }, const []);

    return CustomPaint(
      painter: _TrafficSparklinePainter(
        samples: samples.value,
        accent: active
            ? accent
            : theme.gorionTokens.onSurfaceMuted.withValues(alpha: 0.72),
        uploadAccent: active
            ? uploadAccent
            : theme.gorionTokens.onSurfaceMuted.withValues(alpha: 0.58),
        muted: theme.gorionTokens.onSurfaceMuted,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _TrafficSparklinePainter extends CustomPainter {
  const _TrafficSparklinePainter({
    required this.samples,
    required this.accent,
    required this.uploadAccent,
    required this.muted,
  });

  final List<_TrafficSample> samples;
  final Color accent;
  final Color uploadAccent;
  final Color muted;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final baselineY = size.height - 7;
    final maxValue = samples.fold<int>(
      1,
      (current, sample) =>
          math.max(current, math.max(sample.downlink, sample.uplink)),
    );
    final downlinkPoints = _pointsForSeries(
      samples.map((sample) => sample.downlink).toList(growable: false),
      size,
      maxValue,
    );
    final uplinkPoints = _pointsForSeries(
      samples.map((sample) => sample.uplink).toList(growable: false),
      size,
      maxValue,
    );
    final downlinkPath = _smoothPath(downlinkPoints);
    final uplinkPath = _smoothPath(uplinkPoints);

    final fillPath = Path.from(downlinkPath)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, 0),
          Offset(0, size.height),
          [
            accent.withValues(alpha: 0.14),
            accent.withValues(alpha: 0.02),
            Colors.transparent,
          ],
          const [0.0, 0.72, 1.0],
        ),
    );

    canvas.drawLine(
      Offset(0, baselineY),
      Offset(size.width, baselineY),
      Paint()
        ..color = muted.withValues(alpha: 0.08)
        ..strokeWidth = 1,
    );

    canvas.drawPath(
      downlinkPath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = accent.withValues(alpha: 0.11)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );
    canvas.drawPath(
      downlinkPath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = accent.withValues(alpha: 0.78),
    );
    canvas.drawPath(
      uplinkPath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = uploadAccent.withValues(alpha: 0.70),
    );
  }

  List<Offset> _pointsForSeries(List<int> values, Size size, int maxValue) {
    if (values.isEmpty) {
      return [Offset(0, size.height - 7), Offset(size.width, size.height - 7)];
    }

    final top = 5.0;
    final bottom = size.height - 7.0;
    final height = math.max(1.0, bottom - top);
    final denominator = math.max(1, maxValue).toDouble();
    return [
      for (var index = 0; index < values.length; index += 1)
        Offset(
          values.length == 1
              ? size.width
              : (index / (values.length - 1)) * size.width,
          bottom -
              ((values[index].clamp(0, maxValue) / denominator) * height).clamp(
                0.0,
                height,
              ),
        ),
    ];
  }

  Path _smoothPath(List<Offset> points) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var index = 1; index < points.length; index += 1) {
      final previous = points[index - 1];
      final current = points[index];
      final control = Offset((previous.dx + current.dx) / 2, previous.dy);
      final endControl = Offset((previous.dx + current.dx) / 2, current.dy);
      path.cubicTo(
        control.dx,
        control.dy,
        endControl.dx,
        endControl.dy,
        current.dx,
        current.dy,
      );
    }
    return path;
  }

  @override
  bool shouldRepaint(_TrafficSparklinePainter oldDelegate) =>
      oldDelegate.samples != samples ||
      oldDelegate.accent != accent ||
      oldDelegate.uploadAccent != uploadAccent ||
      oldDelegate.muted != muted;
}

class _ModeChipButton extends StatelessWidget {
  const _ModeChipButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = selected ? scheme.primary : scheme.onSurface;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.14)
              : scheme.onSurface.withValues(alpha: 0.055),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? scheme.primary.withValues(alpha: 0.34)
                : scheme.onSurface.withValues(alpha: 0.10),
            width: 0.8,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      icon,
                      size: 13,
                      color: selected
                          ? scheme.primary
                          : theme.gorionTokens.onSurfaceMuted.withValues(
                              alpha: 0.92,
                            ),
                    ),
                    const Gap(5),
                    Text(
                      label,
                      style: TextStyle(
                        color: selected
                            ? scheme.primary
                            : accent.withValues(alpha: 0.78),
                        fontSize: 11.5,
                        fontWeight: selected
                            ? FontWeight.w800
                            : FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
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
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final color = switch ((isConnected, isSwitching)) {
      (_, true) => const Color(0xFFFFB457),
      (true, false) => primary,
      (false, false) => const Color(0xFFFF5F5F),
    };
    final disabled = isSwitching && !isConnecting;

    return Tooltip(
      message: isConnected ? 'Отключиться' : 'Подключиться',
      child: GestureDetector(
        onTap: disabled ? null : onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          width: 96,
          height: 96,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                color.withValues(alpha: isConnected ? 0.22 : 0.13),
                color.withValues(alpha: isConnected ? 0.11 : 0.06),
                Colors.transparent,
              ],
              stops: const [0.0, 0.62, 1.0],
            ),
            border: Border.all(
              color: color.withValues(alpha: disabled ? 0.34 : 0.82),
              width: 2,
            ),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: isConnected ? 0.42 : 0.22),
                blurRadius: isConnected ? 34 : 22,
                spreadRadius: isConnected ? 2 : -3,
              ),
              BoxShadow(
                color: theme.shadowColor.withValues(alpha: 0.24),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: isConnecting
              ? Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 42,
                      height: 42,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: color.withValues(alpha: 0.92),
                      ),
                    ),
                    Icon(Icons.close_rounded, size: 22, color: color),
                  ],
                )
              : SvgPicture.asset(
                  'assets/images/power.svg',
                  width: 34,
                  height: 34,
                  colorFilter: ColorFilter.mode(
                    color.withValues(alpha: disabled ? 0.62 : 1),
                    BlendMode.srcIn,
                  ),
                ),
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
