part of 'servers_panel.dart';

enum _ServerCardMenuAction { toggleAutoExclusion, details }

class _ServerPingChip extends StatelessWidget {
  const _ServerPingChip({
    required this.ping,
    required this.color,
    required this.selected,
  });

  final int ping;
  final Color color;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isUnavailable = ping == -1;
    final hasPing = ping > 0;
    final effectiveColor = isUnavailable ? const Color(0xFFEF4444) : color;
    final label = isUnavailable
        ? 'NO'
        : hasPing
        ? '$ping ms'
        : '— ms';

    return Text(
      label,
      style: TextStyle(
        color: selected
            ? scheme.onSurface.withValues(alpha: 0.92)
            : effectiveColor.withValues(
                alpha: theme.brightness == Brightness.dark ? 0.96 : 0.88,
              ),
        fontSize: 11.5,
        fontWeight: FontWeight.w800,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _ServerCard extends HookConsumerWidget {
  const _ServerCard({
    super.key,
    required this.server,
    required this.isSelected,
    required this.groupName,
    this.detailLines = const [],
    required this.groupTag,
    this.pingOverride,
    this.speedOverride,
    required this.hasSpeedResult,
    required this.isBenchmarking,
    this.badge,
    this.selectionProgress,
    this.isFavorite = false,
    this.onToggleFavorite,
    this.isAutoExcluded = false,
    this.onToggleAutoExclusion,
    this.onShowDetails,
    this.onSelect,
  });

  final OutboundInfo server;
  final bool isSelected;
  final String groupName;
  final List<String> detailLines;
  final String groupTag;
  final int? pingOverride;
  final int? speedOverride;
  final bool hasSpeedResult;
  final bool isBenchmarking;
  final Widget? badge;
  final AutoServerSelectionProgress? selectionProgress;
  final bool isFavorite;
  final VoidCallback? onToggleFavorite;
  final bool isAutoExcluded;
  final VoidCallback? onToggleAutoExclusion;
  final VoidCallback? onShowDetails;
  final VoidCallback? onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;
    final isLightTheme = theme.brightness == Brightness.light;

    final pulseCtrl = useAnimationController(
      duration: const Duration(milliseconds: 900),
    );
    final pulseValue = useAnimation(pulseCtrl);
    useEffect(() {
      if (isBenchmarking) {
        pulseCtrl.repeat(reverse: true);
      } else {
        pulseCtrl
          ..stop()
          ..value = 0;
      }
      return null;
    }, [isBenchmarking]);

    final name = _displayName(server);
    final cc = _extractCountryCode(name);
    final flag = cc != null ? _flagEmoji(cc) : '';
    final displayedName = cc != null ? _stripCountryPrefix(name) : name;
    final ping = pingOverride ?? server.urlTestDelay;
    final showAccent = isSelected;
    final selectedPrimaryInk = (isLightTheme ? Colors.black : Colors.white)
        .withValues(alpha: isLightTheme ? 0.88 : 0.96);
    final selectedSecondaryInk = (isLightTheme ? Colors.black : Colors.white)
        .withValues(alpha: isLightTheme ? 0.72 : 0.84);
    final selectedTertiaryInk = (isLightTheme ? Colors.black : Colors.white)
        .withValues(alpha: isLightTheme ? 0.62 : 0.76);
    final pingColor = _pingColor(ping);
    final throughput = speedOverride;
    final speedColor = switch (throughput ?? -1) {
      < 1 => const Color(0xFFEF4444),
      < 256 * 1024 => const Color(0xFFF59E0B),
      < 1024 * 1024 => const Color(0xFF22C55E),
      _ => theme.brandAccent,
    };
    final darkNeutralCardSurface = Color.lerp(
      const Color(0xFF050706),
      scheme.onSurface,
      0.05,
    )!;
    final baseCardBackgroundColor = isLightTheme
        ? isBenchmarking
              ? scheme.onSurface.withValues(alpha: 0.050)
              : isSelected
              ? scheme.onSurface.withValues(alpha: 0.036)
              : scheme.onSurface.withValues(alpha: 0.022)
        : darkNeutralCardSurface.withValues(
            alpha: isBenchmarking ? 0.92 : (isSelected ? 0.88 : 0.80),
          );
    final cardBackgroundColor = showAccent && !isBenchmarking
        ? Color.lerp(
            baseCardBackgroundColor,
            theme.brandAccent,
            isLightTheme ? 0.10 : 0.18,
          )!
        : baseCardBackgroundColor;
    final baseCardBorderColor = isLightTheme
        ? isBenchmarking
              ? scheme.onSurface.withValues(alpha: 0.22)
              : scheme.onSurface.withValues(alpha: isSelected ? 0.16 : 0.12)
        : scheme.onSurface.withValues(
            alpha: isBenchmarking ? 0.18 : (isSelected ? 0.16 : 0.10),
          );
    final cardBorderColor = showAccent && !isBenchmarking
        ? Color.lerp(
            baseCardBorderColor,
            theme.brandAccent,
            isLightTheme ? 0.50 : 0.72,
          )!
        : baseCardBorderColor;
    final cardShadowColor = showAccent
        ? theme.brandAccent.withValues(alpha: isLightTheme ? 0.12 : 0.18)
        : isLightTheme
        ? scheme.onSurface.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.22);
    final actionsButtonFillColor = showAccent
        ? theme.brandAccent.withValues(alpha: isLightTheme ? 0.14 : 0.22)
        : scheme.onSurface.withValues(alpha: isLightTheme ? 0.05 : 0.08);
    final actionsButtonBorderColor = showAccent
        ? theme.brandAccent.withValues(alpha: isLightTheme ? 0.28 : 0.42)
        : scheme.onSurface.withValues(alpha: isLightTheme ? 0.12 : 0.14);
    final actionsButtonIconColor = showAccent
        ? selectedPrimaryInk
        : scheme.onSurface.withValues(alpha: 0.88);
    final favoriteIconColor = isFavorite
        ? const Color(0xFFFFD43B)
        : actionsButtonIconColor.withValues(alpha: 0.72);
    final hasActionsMenu =
        onShowDetails != null || onToggleAutoExclusion != null;

    return GestureDetector(
      onTap: onSelect,
      child: Container(
        margin: const EdgeInsets.only(bottom: 7),
        decoration: isBenchmarking
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: scheme.primary.withValues(
                      alpha: 0.06 + pulseValue * 0.22,
                    ),
                    blurRadius: 12 + pulseValue * 14,
                    spreadRadius: -2,
                  ),
                ],
              )
            : null,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 15, sigmaY: 15),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                color: cardBackgroundColor,
                border: Border.all(
                  color: cardBorderColor,
                  width: isBenchmarking ? 1.3 : 0.7,
                ),
                boxShadow: (isSelected && !isBenchmarking)
                    ? [
                        BoxShadow(
                          color: cardShadowColor,
                          blurRadius: 18,
                          spreadRadius: -2,
                        ),
                      ]
                    : null,
              ),
              child: Stack(
                children: [
                  if (isSelected)
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      child: Container(width: 3.5, color: theme.brandAccent),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: 36,
                                    height:
                                        groupName.isNotEmpty ||
                                            detailLines.isNotEmpty
                                        ? 40
                                        : 30,
                                    child: Center(
                                      child: flag.isNotEmpty
                                          ? Text(
                                              flag,
                                              style: const TextStyle(
                                                fontSize: 30,
                                                fontFamily: 'Emoji',
                                                height: 1,
                                              ),
                                            )
                                          : Icon(
                                              Icons.bolt_rounded,
                                              size: 23,
                                              color: isSelected
                                                  ? selectedPrimaryInk
                                                  : theme.brandAccent
                                                        .withValues(
                                                          alpha: 0.86,
                                                        ),
                                            ),
                                    ),
                                  ),
                                  const Gap(10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          displayedName,
                                          style: TextStyle(
                                            color: isSelected
                                                ? selectedPrimaryInk
                                                : scheme.onSurface.withValues(
                                                    alpha: 0.9,
                                                  ),
                                            fontSize: 13.5,
                                            fontWeight: isSelected
                                                ? FontWeight.w800
                                                : FontWeight.w700,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        if (groupName.isNotEmpty) ...[
                                          const Gap(2),
                                          Text(
                                            groupName,
                                            style: TextStyle(
                                              color: isSelected
                                                  ? selectedSecondaryInk
                                                  : muted.withValues(
                                                      alpha: 0.78,
                                                    ),
                                              fontSize: 12,
                                              height: 1.12,
                                            ),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                        if (detailLines.isNotEmpty) ...[
                                          const Gap(5),
                                          for (
                                            var index = 0;
                                            index < detailLines.length;
                                            index += 1
                                          ) ...[
                                            Text(
                                              detailLines[index],
                                              style: TextStyle(
                                                color: isSelected
                                                    ? selectedTertiaryInk
                                                    : muted.withValues(
                                                        alpha: 0.95,
                                                      ),
                                                fontSize: 11,
                                                fontWeight: FontWeight.w500,
                                                height: 1.25,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            if (index != detailLines.length - 1)
                                              const Gap(2),
                                          ],
                                        ],
                                        if (isAutoExcluded) ...[
                                          const Gap(5),
                                          Text(
                                            'Исключён из автовыбора',
                                            style: TextStyle(
                                              color: const Color(
                                                0xFFFF6B6B,
                                              ).withValues(alpha: 0.95),
                                              fontSize: 10.5,
                                              fontWeight: FontWeight.w500,
                                              height: 1.15,
                                            ),
                                          ),
                                        ],
                                        if (selectionProgress != null) ...[
                                          const Gap(6),
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              999,
                                            ),
                                            child: SizedBox(
                                              height: 4,
                                              child: LinearProgressIndicator(
                                                value: selectionProgress!.value,
                                                backgroundColor:
                                                    _softAccentFill(
                                                      theme,
                                                      emphasis: 0.92,
                                                    ),
                                                valueColor:
                                                    AlwaysStoppedAnimation<
                                                      Color
                                                    >(theme.brandAccent),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const Gap(8),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (isBenchmarking)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: scheme.primary.withValues(
                                        alpha: 0.14,
                                      ),
                                      borderRadius: BorderRadius.circular(999),
                                      border: Border.all(
                                        color: scheme.primary.withValues(
                                          alpha: 0.38,
                                        ),
                                        width: 0.7,
                                      ),
                                    ),
                                    child: Text(
                                      'TEST',
                                      style: TextStyle(
                                        color: scheme.onSurface.withValues(
                                          alpha: 0.88,
                                        ),
                                        fontSize: 10,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                  )
                                else if (badge != null)
                                  badge!
                                else
                                  _ServerPingChip(
                                    ping: ping,
                                    color: pingColor,
                                    selected: isSelected,
                                  ),
                                if (onToggleFavorite != null) ...[
                                  const Gap(6),
                                  Tooltip(
                                    message: isFavorite
                                        ? 'Убрать из избранного'
                                        : 'Добавить в избранное',
                                    child: GestureDetector(
                                      onTap: onToggleFavorite,
                                      child: SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: Icon(
                                          isFavorite
                                              ? Icons.star_rounded
                                              : Icons.star_border_rounded,
                                          size: 17,
                                          color: favoriteIconColor,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                                if (hasActionsMenu) ...[
                                  const Gap(6),
                                  PopupMenuButton<_ServerCardMenuAction>(
                                    tooltip: 'Действия',
                                    color: scheme.surface,
                                    elevation: 12,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    onSelected: (action) {
                                      switch (action) {
                                        case _ServerCardMenuAction
                                            .toggleAutoExclusion:
                                          onToggleAutoExclusion?.call();
                                        case _ServerCardMenuAction.details:
                                          onShowDetails?.call();
                                      }
                                    },
                                    itemBuilder: (context) => [
                                      if (onToggleAutoExclusion != null)
                                        PopupMenuItem<_ServerCardMenuAction>(
                                          value: _ServerCardMenuAction
                                              .toggleAutoExclusion,
                                          child: Row(
                                            children: [
                                              Icon(
                                                isAutoExcluded
                                                    ? Icons
                                                          .playlist_add_check_circle_rounded
                                                    : Icons.block_rounded,
                                                size: 18,
                                                color: isAutoExcluded
                                                    ? scheme.primary
                                                    : const Color(0xFFEF4444),
                                              ),
                                              const Gap(10),
                                              Text(
                                                isAutoExcluded
                                                    ? 'Вернуть в автовыбор'
                                                    : 'Исключить из автовыбора',
                                                style: TextStyle(
                                                  color: scheme.onSurface
                                                      .withValues(alpha: 0.92),
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      if (onShowDetails != null)
                                        PopupMenuItem<_ServerCardMenuAction>(
                                          value: _ServerCardMenuAction.details,
                                          child: Row(
                                            children: [
                                              Icon(
                                                Icons.tune_rounded,
                                                size: 18,
                                                color: muted.withValues(
                                                  alpha: 0.95,
                                                ),
                                              ),
                                              const Gap(10),
                                              Text(
                                                'Параметры сервера',
                                                style: TextStyle(
                                                  color: scheme.onSurface
                                                      .withValues(alpha: 0.92),
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                    ],
                                    child: Container(
                                      width: 28,
                                      height: 28,
                                      decoration: BoxDecoration(
                                        color: actionsButtonFillColor,
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: isAutoExcluded
                                              ? const Color(
                                                  0xFFEF4444,
                                                ).withValues(alpha: 0.22)
                                              : actionsButtonBorderColor,
                                          width: 0.7,
                                        ),
                                      ),
                                      child: Icon(
                                        isAutoExcluded
                                            ? Icons.block_rounded
                                            : Icons.more_horiz_rounded,
                                        size: 15,
                                        color: isAutoExcluded
                                            ? const Color(
                                                0xFFFF8A8A,
                                              ).withValues(alpha: 0.96)
                                            : actionsButtonIconColor,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            if (isBenchmarking && !hasSpeedResult) ...[
                              const Gap(4),
                              Text(
                                'benchmark…',
                                style: TextStyle(
                                  color: scheme.onSurface.withValues(
                                    alpha: 0.82,
                                  ),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                            if (hasSpeedResult) ...[
                              const Gap(4),
                              Text(
                                throughput != null && throughput > 0
                                    ? _formatRate(throughput)
                                    : 'FAIL',
                                style: TextStyle(
                                  color: isSelected
                                      ? selectedPrimaryInk
                                      : throughput != null && throughput > 0
                                      ? speedColor
                                      : const Color(0xFFEF4444),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.2,
                                ),
                              ),
                              Text(
                                isBenchmarking
                                    ? 'live throughput'
                                    : 'throughput',
                                style: TextStyle(
                                  color: isSelected
                                      ? selectedSecondaryInk
                                      : muted.withValues(alpha: 0.82),
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.4,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
