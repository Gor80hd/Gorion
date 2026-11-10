part of 'split_tunnel_section.dart';

class _RoutingActionCard extends StatelessWidget {
  const _RoutingActionCard({
    required this.action,
    required this.group,
    required this.presets,
    required this.busy,
    required this.onApplyPreset,
    required this.onAddGeositePressed,
    required this.onAddGeoipPressed,
    required this.onAddDomainPressed,
    required this.onAddIpPressed,
    required this.onClearPressed,
    required this.onDeleteGeosite,
    required this.onDeleteGeoip,
    required this.onDeleteDomain,
    required this.onDeleteIp,
    required this.onDeleteImport,
  });

  final SplitTunnelAction action;
  final SplitTunnelRuleGroup group;
  final List<SplitTunnelPreset> presets;
  final bool busy;
  final ValueChanged<SplitTunnelPreset> onApplyPreset;
  final VoidCallback onAddGeositePressed;
  final VoidCallback onAddGeoipPressed;
  final VoidCallback onAddDomainPressed;
  final VoidCallback onAddIpPressed;
  final VoidCallback onClearPressed;
  final ValueChanged<String> onDeleteGeosite;
  final ValueChanged<String> onDeleteGeoip;
  final ValueChanged<String> onDeleteDomain;
  final ValueChanged<String> onDeleteIp;
  final ValueChanged<SplitTunnelCustomRuleSet> onDeleteImport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _actionColor(action);
    final primaryInk = _splitTunnelPrimaryInk(theme);
    final secondaryInk = _splitTunnelSecondaryInk(theme);
    final iconInk = _splitTunnelIconInk(theme, color);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: color.withValues(alpha: 0.20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(_actionIcon(action), color: iconInk),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _actionTitle(action),
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: primaryInk,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _actionDescription(action),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: secondaryInk,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _ActionSummaryChip(
                title: _actionTitle(action),
                count: group.ruleCount,
                color: color,
              ),
            ],
          ),
          if (presets.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              'Пресеты',
              style: theme.textTheme.labelLarge?.copyWith(
                color: primaryInk,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final preset in presets)
                  _PresetCard(
                    preset: preset,
                    color: color,
                    onPressed: busy ? null : () => onApplyPreset(preset),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: busy ? null : onAddGeositePressed,
                icon: const Icon(Icons.travel_explore_rounded),
                label: const Text('Выбрать geosite'),
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : onAddGeoipPressed,
                icon: const Icon(Icons.map_rounded),
                label: const Text('Выбрать geoip'),
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : onAddDomainPressed,
                icon: const Icon(Icons.language_rounded),
                label: const Text('Добавить домен'),
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : onAddIpPressed,
                icon: const Icon(Icons.lan_rounded),
                label: const Text('Добавить сеть'),
              ),
              if (group.hasRules)
                TextButton.icon(
                  onPressed: busy ? null : onClearPressed,
                  icon: const Icon(Icons.delete_sweep_rounded),
                  label: const Text('Очистить секцию'),
                ),
            ],
          ),
          const SizedBox(height: 14),
          if (!group.hasRules)
            Text(
              _emptyLabelForAction(action),
              style: theme.textTheme.bodySmall?.copyWith(
                color: secondaryInk,
                height: 1.45,
              ),
            )
          else ...[
            if (group.normalizedGeositeTags.isNotEmpty)
              _RuleChipSection(
                title: 'Built-in domain lists',
                children: [
                  for (final value in group.normalizedGeositeTags)
                    _RuleChip(
                      label: 'geosite:$value',
                      onDeleted: busy ? null : () => onDeleteGeosite(value),
                    ),
                ],
              ),
            if (group.normalizedGeoipTags.isNotEmpty)
              _RuleChipSection(
                title: 'Built-in IP lists',
                children: [
                  for (final value in group.normalizedGeoipTags)
                    _RuleChip(
                      label: 'geoip:$value',
                      onDeleted: busy ? null : () => onDeleteGeoip(value),
                    ),
                ],
              ),
            if (group.normalizedDomainSuffixes.isNotEmpty)
              _RuleChipSection(
                title: 'Manual domains',
                children: [
                  for (final value in group.normalizedDomainSuffixes)
                    _RuleChip(
                      label: value,
                      onDeleted: busy ? null : () => onDeleteDomain(value),
                    ),
                ],
              ),
            if (group.normalizedIpCidrs.isNotEmpty)
              _RuleChipSection(
                title: 'Manual networks',
                children: [
                  for (final value in group.normalizedIpCidrs)
                    _RuleChip(
                      label: value,
                      onDeleted: busy ? null : () => onDeleteIp(value),
                    ),
                ],
              ),
            if (group.activeCustomRuleSets.isNotEmpty)
              _RuleChipSection(
                title: 'Imported lists',
                children: [
                  for (final ruleSet in group.activeCustomRuleSets)
                    _RuleChip(
                      label: ruleSet.normalizedLabel.isEmpty
                          ? ruleSet.normalizedId
                          : ruleSet.normalizedLabel,
                      onDeleted: busy ? null : () => onDeleteImport(ruleSet),
                    ),
                ],
              ),
          ],
          if (group.normalizedCustomRuleSets.length >
              group.activeCustomRuleSets.length) ...[
            const SizedBox(height: 8),
            Text(
              'Есть отключённые imported rule-set. Управление ими находится в Advanced.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: secondaryInk,
                height: 1.45,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ImportedRuleSetCard extends StatelessWidget {
  const _ImportedRuleSetCard({
    required this.action,
    required this.ruleSet,
    required this.onToggle,
    required this.onDelete,
  });

  final SplitTunnelAction action;
  final SplitTunnelCustomRuleSet ruleSet;
  final ValueChanged<bool>? onToggle;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primaryInk = _splitTunnelPrimaryInk(theme);
    final secondaryInk = _splitTunnelSecondaryInk(theme);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
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
                      ruleSet.normalizedLabel.isEmpty
                          ? ruleSet.normalizedId
                          : ruleSet.normalizedLabel,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: primaryInk,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      ruleSet.isRemote
                          ? ruleSet.normalizedUrl
                          : ruleSet.normalizedPath,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: secondaryInk,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Switch.adaptive(value: ruleSet.enabled, onChanged: onToggle),
              IconButton(
                tooltip: 'Удалить import',
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _MetaChip(label: _actionTitle(action)),
              _MetaChip(label: ruleSet.isRemote ? 'Remote URL' : 'Local path'),
              _MetaChip(label: 'format ${ruleSet.format.jsonValue}'),
              _MetaChip(label: ruleSet.enabled ? 'Enabled' : 'Disabled'),
            ],
          ),
        ],
      ),
    );
  }
}

class _CustomRuleSetBinding {
  const _CustomRuleSetBinding({required this.action, required this.ruleSet});

  final SplitTunnelAction action;
  final SplitTunnelCustomRuleSet ruleSet;
}

class _PresetCard extends StatelessWidget {
  const _PresetCard({
    required this.preset,
    required this.color,
    required this.onPressed,
  });

  final SplitTunnelPreset preset;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primaryInk = _splitTunnelPrimaryInk(theme);
    final secondaryInk = _splitTunnelSecondaryInk(theme);

    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.all(14),
        minimumSize: const Size(220, 0),
        backgroundColor: Colors.white.withValues(alpha: 0.04),
        side: BorderSide(color: color.withValues(alpha: 0.22)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            preset.label,
            style: theme.textTheme.titleSmall?.copyWith(
              color: primaryInk,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            preset.description,
            style: theme.textTheme.bodySmall?.copyWith(
              color: secondaryInk,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class _RuleChipSection extends StatelessWidget {
  const _RuleChipSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.labelLarge?.copyWith(
              color: _splitTunnelPrimaryInk(theme),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: children),
        ],
      ),
    );
  }
}

class _RuleChip extends StatelessWidget {
  const _RuleChip({required this.label, required this.onDeleted});

  final String label;
  final VoidCallback? onDeleted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InputChip(
      label: Text(label),
      onDeleted: onDeleted,
      backgroundColor: Colors.white.withValues(alpha: 0.06),
      side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      deleteIconColor: _splitTunnelPrimaryInk(theme),
      labelStyle: theme.textTheme.bodySmall?.copyWith(
        color: _splitTunnelPrimaryInk(theme),
      ),
    );
  }
}

class _ActionSummaryChip extends StatelessWidget {
  const _ActionSummaryChip({
    required this.title,
    required this.count,
    required this.color,
  });

  final String title;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Text(
        '$title $count',
        style: theme.textTheme.labelLarge?.copyWith(
          color: _splitTunnelPrimaryInk(theme),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ToggleCard extends StatelessWidget {
  const _ToggleCard({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: value ? 0.08 : 0.04),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: value
              ? gorionAccent.withValues(alpha: 0.24)
              : Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: _splitTunnelPrimaryInk(theme),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _splitTunnelSecondaryInk(theme),
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Switch.adaptive(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: _splitTunnelSecondaryInk(theme),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

List<_CustomRuleSetBinding> _collectCustomRuleSetBindings(
  SplitTunnelSettings settings,
) {
  return [
    for (final action in _splitTunnelActionOrder)
      for (final ruleSet in settings.groupFor(action).normalizedCustomRuleSets)
        _CustomRuleSetBinding(action: action, ruleSet: ruleSet),
  ];
}

Color _actionColor(SplitTunnelAction action) {
  switch (action) {
    case SplitTunnelAction.direct:
      return const Color(0xFF1EFFAC);
    case SplitTunnelAction.block:
      return const Color(0xFFFF735C);
    case SplitTunnelAction.proxy:
      return const Color(0xFF72A8FF);
  }
}

IconData _actionIcon(SplitTunnelAction action) {
  switch (action) {
    case SplitTunnelAction.direct:
      return Icons.call_made_rounded;
    case SplitTunnelAction.block:
      return Icons.block_rounded;
    case SplitTunnelAction.proxy:
      return Icons.verified_outlined;
  }
}

String _actionTitle(SplitTunnelAction action) {
  switch (action) {
    case SplitTunnelAction.direct:
      return 'Direct';
    case SplitTunnelAction.block:
      return 'Block';
    case SplitTunnelAction.proxy:
      return 'Proxy';
  }
}

String _actionDescription(SplitTunnelAction action) {
  switch (action) {
    case SplitTunnelAction.direct:
      return 'Обойти прокси и отправить трафик напрямую. Подходит для LAN, локальных сервисов и безопасных исключений.';
    case SplitTunnelAction.block:
      return 'Полностью остановить трафик до отправки в outbound. Подходит для рекламы, трекинга и нежелательных направлений.';
    case SplitTunnelAction.proxy:
      return 'Принудительно держать трафик на активном proxy selector. Полезно для сервисов, которые нельзя выпускать в direct.';
  }
}

String _emptyLabelForAction(SplitTunnelAction action) {
  switch (action) {
    case SplitTunnelAction.direct:
      return 'Пока нет direct-исключений. Добавьте пресет или свой домен / сеть.';
    case SplitTunnelAction.block:
      return 'Пока нет block-правил. Добавьте пресет или свой домен / сеть.';
    case SplitTunnelAction.proxy:
      return 'Пока нет proxy-правил. Добавьте пресет или свой домен / сеть.';
  }
}

List<String> _addStringValue(
  List<String> current,
  String value,
  String Function(String value) normalize,
) {
  final normalized = normalize(value);
  if (normalized.isEmpty ||
      current.any((item) => normalize(item) == normalized)) {
    return current;
  }
  return [...current, normalized];
}

List<String> _removeStringValue(
  List<String> current,
  String value,
  String Function(String value) normalize,
) {
  final normalized = normalize(value);
  return [
    for (final item in current)
      if (normalize(item) != normalized) item,
  ];
}

String _formatRefreshTimestamp(DateTime? value) {
  if (value == null) {
    return 'never';
  }

  final local = value.toLocal();
  final year = local.year.toString().padLeft(4, '0');
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$year-$month-$day $hour:$minute';
}
