part of 'map_view.dart';

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
              fontFeatures: const [FontFeature.tabularFigures()],
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
