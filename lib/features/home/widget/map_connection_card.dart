part of 'map_view.dart';

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
