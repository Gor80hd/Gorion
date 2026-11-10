part of 'servers_panel.dart';

class _GlassTextField extends StatelessWidget {
  const _GlassTextField({
    required this.controller,
    required this.hint,
    this.prefixIcon,
  });

  final TextEditingController controller;
  final String hint;
  final Widget? prefixIcon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return GlassPanel(
      height: ServersPanelWidget.searchFieldHeight,
      borderRadius: ServersPanelWidget.searchFieldRadius,
      backgroundColor: _softAccentSurface(theme, emphasis: 0.70),
      opacity: 0.05,
      strokeOpacity: 0.04,
      strokeColor: theme.brandAccent,
      child: TextField(
        controller: controller,
        textAlignVertical: TextAlignVertical.center,
        style: TextStyle(
          color: scheme.onSurface,
          fontSize: 15,
          fontWeight: FontWeight.w600,
          height: 1.1,
        ),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(
            color: Theme.of(context).gorionTokens.onSurfaceMuted,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
          prefixIcon: prefixIcon,
          prefixIconConstraints: prefixIcon == null
              ? null
              : const BoxConstraints(
                  minWidth: 42,
                  minHeight: ServersPanelWidget.searchFieldHeight,
                ),
          contentPadding: prefixIcon == null
              ? const EdgeInsets.symmetric(horizontal: 18)
              : const EdgeInsets.only(right: 18),
          isDense: true,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          errorBorder: InputBorder.none,
          focusedErrorBorder: InputBorder.none,
        ),
      ),
    );
  }
}

class _SortDropdown extends StatelessWidget {
  const _SortDropdown({required this.value, required this.onChanged});

  final ServerSortMode value;
  final ValueChanged<ServerSortMode> onChanged;

  String get _label => switch (value) {
    ServerSortMode.none => 'Без сортировки',
    ServerSortMode.ping => 'По пингу',
    ServerSortMode.speed => 'По скорости',
    ServerSortMode.alpha => 'По алфавиту',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;
    final isActive = value != ServerSortMode.none;
    final accentColor = _softAccentForeground(
      theme,
      emphasis: theme.brightness == Brightness.dark ? 1.0 : 0.92,
    );

    return GlassPanel(
      height: 42,
      borderRadius: 15,
      backgroundColor: _softAccentSurface(
        theme,
        emphasis: isActive ? 0.95 : 0.74,
      ),
      opacity: isActive ? 0.08 : 0.05,
      strokeOpacity: isActive ? 0.12 : 0.04,
      strokeColor: theme.brandAccent,
      child: PopupMenuButton<ServerSortMode>(
        initialValue: value,
        tooltip: 'Сортировка',
        onSelected: onChanged,
        color: scheme.surface,
        elevation: 12,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        itemBuilder: (context) => [
          _sortMenuItem(context, ServerSortMode.none, 'Без сортировки', value),
          _sortMenuItem(context, ServerSortMode.ping, 'По пингу', value),
          _sortMenuItem(context, ServerSortMode.speed, 'По скорости', value),
          _sortMenuItem(context, ServerSortMode.alpha, 'По алфавиту', value),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Icon(
                Icons.tune_rounded,
                size: 15,
                color: isActive ? accentColor : muted.withValues(alpha: 0.9),
              ),
              const Gap(8),
              Expanded(
                child: Text(
                  _label,
                  style: TextStyle(
                    color: isActive
                        ? accentColor
                        : scheme.onSurface.withValues(alpha: 0.72),
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                color: muted.withValues(alpha: 0.85),
              ),
            ],
          ),
        ),
      ),
    );
  }

  PopupMenuItem<ServerSortMode> _sortMenuItem(
    BuildContext context,
    ServerSortMode mode,
    String label,
    ServerSortMode currentValue,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = mode == currentValue;

    return PopupMenuItem<ServerSortMode>(
      value: mode,
      child: Row(
        children: [
          Icon(
            selected ? Icons.check_rounded : Icons.circle_outlined,
            size: 16,
            color: selected
                ? scheme.primary
                : theme.gorionTokens.onSurfaceMuted.withValues(alpha: 0.9),
          ),
          const Gap(8),
          Text(
            label,
            style: TextStyle(
              color: selected
                  ? scheme.primary
                  : scheme.onSurface.withValues(alpha: 0.82),
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _SmallGlassButton extends StatelessWidget {
  const _SmallGlassButton({
    required this.icon,
    this.tooltip = '',
    this.isStop = false,
    this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool isStop;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = onTap != null;
    final iconColor = isStop
        ? scheme.error.withValues(alpha: 0.88)
        : enabled
        ? _softAccentForeground(theme, emphasis: 0.92)
        : theme.gorionTokens.onSurfaceMuted.withValues(alpha: 0.45);

    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: GlassPanel(
          width: 42,
          height: 42,
          borderRadius: 15,
          backgroundColor: isStop
              ? scheme.error
              : _softAccentSurface(theme, emphasis: enabled ? 0.92 : 0.55),
          opacity: isStop ? 0.1 : (enabled ? 0.06 : 0.03),
          strokeOpacity: isStop ? 0.14 : (enabled ? 0.08 : 0.03),
          strokeColor: isStop ? scheme.error : theme.brandAccent,
          child: Center(child: Icon(icon, size: 17, color: iconColor)),
        ),
      ),
    );
  }
}

enum _SubscriptionMenuAction { add, manage, update }

class _SubscriptionMenuButton extends StatelessWidget {
  const _SubscriptionMenuButton({
    required this.showUpdate,
    required this.updateRunning,
    this.onAdd,
    this.onManage,
    this.onUpdate,
  });

  final bool showUpdate;
  final bool updateRunning;
  final VoidCallback? onAdd;
  final VoidCallback? onManage;
  final VoidCallback? onUpdate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;
    final accent = _softAccentForeground(theme, emphasis: 0.92);

    return Tooltip(
      message: 'Подписки',
      child: GlassPanel(
        width: ServersPanelWidget.searchFieldHeight,
        height: ServersPanelWidget.searchFieldHeight,
        borderRadius: 18,
        backgroundColor: _softAccentSurface(theme, emphasis: 0.92),
        opacity: 0.08,
        strokeColor: theme.brandAccent,
        strokeOpacity: 0.10,
        child: PopupMenuButton<_SubscriptionMenuAction>(
          tooltip: 'Подписки',
          color: scheme.surface,
          elevation: 14,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          onSelected: (action) {
            switch (action) {
              case _SubscriptionMenuAction.add:
                onAdd?.call();
              case _SubscriptionMenuAction.manage:
                onManage?.call();
              case _SubscriptionMenuAction.update:
                onUpdate?.call();
            }
          },
          itemBuilder: (context) => [
            _subscriptionMenuItem(
              context,
              value: _SubscriptionMenuAction.add,
              icon: Icons.add_rounded,
              label: 'Добавить подписку',
              enabled: onAdd != null,
            ),
            _subscriptionMenuItem(
              context,
              value: _SubscriptionMenuAction.manage,
              icon: Icons.inventory_2_outlined,
              label: 'Управление подписками',
              enabled: onManage != null,
            ),
            if (showUpdate)
              _subscriptionMenuItem(
                context,
                value: _SubscriptionMenuAction.update,
                icon: updateRunning
                    ? Icons.sync_rounded
                    : Icons.refresh_rounded,
                label: updateRunning
                    ? 'Обновление выполняется'
                    : 'Обновить подписки',
                enabled: onUpdate != null,
              ),
          ],
          child: Center(
            child: Icon(
              Icons.tune_rounded,
              size: 21,
              color: onAdd != null || onManage != null || onUpdate != null
                  ? accent
                  : muted.withValues(alpha: 0.52),
            ),
          ),
        ),
      ),
    );
  }

  PopupMenuItem<_SubscriptionMenuAction> _subscriptionMenuItem(
    BuildContext context, {
    required _SubscriptionMenuAction value,
    required IconData icon,
    required String label,
    required bool enabled,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = enabled
        ? scheme.onSurface.withValues(alpha: 0.88)
        : theme.gorionTokens.onSurfaceMuted.withValues(alpha: 0.48);

    return PopupMenuItem<_SubscriptionMenuAction>(
      value: value,
      enabled: enabled,
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const Gap(10),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _PingTestProgress extends StatelessWidget {
  const _PingTestProgress({
    required this.completed,
    required this.total,
    required this.status,
    required this.elapsed,
  });

  final int completed;
  final int total;
  final String? status;
  final Duration elapsed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;
    final progress = total > 0 ? completed / total : null;
    final label =
        status ??
        (total > 0
            ? 'Проверено $completed из $total'
            : 'Подготовка benchmark…');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: scheme.onSurface.withValues(alpha: 0.72),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Gap(8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _softAccentFill(theme, emphasis: 0.95),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: _softAccentBorder(theme, emphasis: 0.95),
                  width: 0.7,
                ),
              ),
              child: Text(
                _formatElapsed(elapsed),
                style: TextStyle(
                  color: muted.withValues(alpha: 1),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ],
        ),
        const Gap(6),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            minHeight: 6,
            value: total > 0 ? progress : null,
            backgroundColor: _softAccentFill(theme, emphasis: 0.9),
            valueColor: AlwaysStoppedAnimation(scheme.primary),
          ),
        ),
      ],
    );
  }
}
