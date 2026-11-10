part of 'servers_panel.dart';

class _ServerListWindow extends StatelessWidget {
  const _ServerListWindow({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      borderRadius: 24,
      backgroundColor: _softAccentSurface(theme, emphasis: 0.64),
      opacity: 0.07,
      strokeOpacity: 0.09,
      strokeColor: theme.brandAccent,
      showGlow: false,
      child: child,
    );
  }
}

class _ServerSectionLabel extends StatelessWidget {
  const _ServerSectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.gorionTokens.onSurfaceMuted.withValues(alpha: 0.86),
          fontWeight: FontWeight.w900,
          letterSpacing: 0.35,
        ),
      ),
    );
  }
}

class _SubscriptionCompactRow extends StatelessWidget {
  const _SubscriptionCompactRow({
    required this.name,
    required this.serverCount,
    required this.isActive,
    required this.isExpanded,
    required this.onTap,
  });

  final String name;
  final int serverCount;
  final bool isActive;
  final bool isExpanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;
    final accent = isActive
        ? _softAccentForeground(theme, emphasis: 0.96)
        : scheme.onSurface.withValues(alpha: 0.72);
    final badgeFill = isActive
        ? _softAccentFill(theme, emphasis: 1.30)
        : _softAccentFill(theme, emphasis: 0.78);
    final badgeBorder = isActive
        ? _softAccentBorder(theme, emphasis: 1.20)
        : _softAccentBorder(theme, emphasis: 0.82);
    final countColor = isActive
        ? _softAccentForeground(theme, emphasis: 0.96)
        : muted.withValues(alpha: 0.84);
    final indicatorColor = isActive
        ? theme.brandAccent.withValues(alpha: 0.92)
        : Colors.transparent;

    return Material(
      color: Colors.transparent,
      child: SizedBox(
        height: 42,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          hoverColor: scheme.onSurface.withValues(
            alpha: theme.brightness == Brightness.dark ? 0.035 : 0.045,
          ),
          splashColor: theme.brandAccent.withValues(alpha: 0.08),
          highlightColor: theme.brandAccent.withValues(alpha: 0.05),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 3,
                  height: 22,
                  decoration: BoxDecoration(
                    color: indicatorColor,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const Gap(9),
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: badgeFill,
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(color: badgeBorder, width: 0.8),
                  ),
                  child: Icon(Icons.layers_rounded, size: 12.5, color: accent),
                ),
                const Gap(10),
                Expanded(
                  child: Text(
                    name,
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 13,
                      fontWeight: isActive ? FontWeight.w800 : FontWeight.w700,
                      height: 1,
                      letterSpacing: 0.15,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '$serverCount',
                  style: TextStyle(
                    color: countColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    height: 1,
                  ),
                ),
                const Gap(8),
                AnimatedRotation(
                  turns: isExpanded ? 0.25 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    size: 16,
                    color: isActive
                        ? scheme.primary.withValues(alpha: 0.82)
                        : muted.withValues(alpha: 0.72),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SubscriptionServersPlaceholder extends StatelessWidget {
  const _SubscriptionServersPlaceholder({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).gorionTokens.onSurfaceMuted;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 0, 2),
      child: Text(
        message,
        style: TextStyle(
          color: muted.withValues(alpha: 0.95),
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _SubscriptionActionChip extends StatelessWidget {
  const _SubscriptionActionChip({
    required this.icon,
    required this.label,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _softAccentForeground(theme, emphasis: 0.86);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: _softAccentFill(theme, emphasis: 1.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _softAccentBorder(theme, emphasis: 1.05),
            width: 0.7,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: color),
            const Gap(6),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SubscriptionsHiddenHint extends StatelessWidget {
  const _SubscriptionsHiddenHint({required this.onManage});

  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      borderRadius: 15,
      backgroundColor: _softAccentSurface(theme, emphasis: 0.74),
      opacity: 0.05,
      strokeOpacity: 0.07,
      strokeColor: theme.brandAccent,
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Все подписки скрыты. Включите нужные в настройках подписок.',
              style: TextStyle(
                color: scheme.onSurface.withValues(alpha: 0.68),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const Gap(10),
          _SubscriptionActionChip(
            icon: Icons.tune_rounded,
            label: 'Открыть',
            onTap: onManage,
          ),
        ],
      ),
    );
  }
}

class _EmptyServersCard extends StatelessWidget {
  const _EmptyServersCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return GlassPanel(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      borderRadius: 15,
      backgroundColor: Colors.white,
      opacity: 0.05,
      strokeOpacity: 0.09,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.satellite_alt_rounded,
            size: 16,
            color: theme.gorionTokens.onSurfaceMuted.withValues(alpha: 0.48),
          ),
          const Gap(8),
          Text(
            'Нет серверов',
            style: TextStyle(
              color: scheme.onSurface.withValues(alpha: 0.72),
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
