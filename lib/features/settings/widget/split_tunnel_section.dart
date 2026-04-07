import 'package:flutter/material.dart';
import 'package:gorion_clean/app/theme.dart';
import 'package:gorion_clean/core/widget/glass_panel.dart';
import 'package:gorion_clean/features/settings/data/split_tunnel_catalog.dart';
import 'package:gorion_clean/features/settings/model/split_tunnel_settings.dart';

const _splitTunnelActionOrder = <SplitTunnelAction>[
  SplitTunnelAction.direct,
  SplitTunnelAction.block,
  SplitTunnelAction.proxy,
];

class SplitTunnelSection extends StatelessWidget {
  const SplitTunnelSection({
    super.key,
    required this.settings,
    required this.busy,
    required this.isConnected,
    required this.onChanged,
    required this.onRefreshRequested,
  });

  final SplitTunnelSettings settings;
  final bool busy;
  final bool isConnected;
  final ValueChanged<SplitTunnelSettings> onChanged;
  final Future<void> Function(SplitTunnelManagedSourceKind sourceKind)
  onRefreshRequested;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final importedBindings = _collectCustomRuleSetBindings(settings);

    return GlassPanel(
      borderRadius: 26,
      padding: const EdgeInsets.all(22),
      opacity: 0.06,
      backgroundColor: Colors.white,
      strokeColor: Colors.white,
      strokeOpacity: 0.08,
      strokeWidth: 1,
      showGlow: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Traffic routing',
            style: theme.textTheme.titleLarge?.copyWith(
              color: gorionOnSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Здесь задаётся понятная логика маршрутизации: что идёт в direct, что блокируется, а что принудительно остаётся на proxy. Пресеты добавляют готовые правила, а ниже можно вручную дописать свои домены и сети.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: gorionOnSurfaceMuted,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 18),
          _ToggleCard(
            title: 'Включить правила маршрутизации',
            subtitle: _buildEnabledSubtitle(),
            value: settings.enabled,
            onChanged: (value) => onChanged(settings.copyWith(enabled: value)),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final action in _splitTunnelActionOrder)
                _ActionSummaryChip(
                  title: _actionTitle(action),
                  count: settings.groupFor(action).ruleCount,
                  color: _actionColor(action),
                ),
              if (settings.hasManagedGeositeSources)
                _MetaChip(
                  label:
                      'geosite ${_formatRefreshTimestamp(settings.lastRefreshAtForManagedSource(SplitTunnelManagedSourceKind.geosite))}',
                ),
              if (settings.hasManagedGeoipSources)
                _MetaChip(
                  label:
                      'geoip ${_formatRefreshTimestamp(settings.lastRefreshAtForManagedSource(SplitTunnelManagedSourceKind.geoip))}',
                ),
              if (settings.hasManagedRemoteSources)
                _MetaChip(
                  label:
                      'автообновление geo-списков ${settings.normalizedRemoteUpdateInterval}',
                ),
            ],
          ),
          const SizedBox(height: 20),
          for (final action in _splitTunnelActionOrder) ...[
            _RoutingActionCard(
              action: action,
              group: settings.groupFor(action),
              presets: splitTunnelPresetsForAction(action),
              busy: busy,
              onApplyPreset: (preset) => onChanged(
                applySplitTunnelPreset(current: settings, preset: preset),
              ),
              onAddGeositePressed: () => _addGeositeTag(context, action),
              onAddGeoipPressed: () => _addGeoipTag(context, action),
              onAddDomainPressed: () => _addDomainSuffix(context, action),
              onAddIpPressed: () => _addIpCidr(context, action),
              onClearPressed: () => onChanged(
                settings.copyWithGroup(action, const SplitTunnelRuleGroup()),
              ),
              onDeleteGeosite: (value) => _removeGeositeTag(action, value),
              onDeleteGeoip: (value) => _removeGeoipTag(action, value),
              onDeleteDomain: (value) => _removeDomainSuffix(action, value),
              onDeleteIp: (value) => _removeIpCidr(action, value),
              onDeleteImport: (ruleSet) =>
                  _removeCustomRuleSet(action, ruleSet),
            ),
            if (action != _splitTunnelActionOrder.last)
              const SizedBox(height: 14),
          ],
          const SizedBox(height: 18),
          _buildAdvancedSection(context, importedBindings),
        ],
      ),
    );
  }

  String _buildEnabledSubtitle() {
    if (!settings.hasRules) {
      return 'Сначала примените пресет или добавьте свои домены и сети. Пока правил нет.';
    }
    if (settings.enabled) {
      return 'Правила активны и будут встроены в runtime-конфиг при следующем подключении.';
    }
    return 'Правила сохранены, но сейчас выключены и не будут применяться.';
  }

  Widget _buildAdvancedSection(
    BuildContext context,
    List<_CustomRuleSetBinding> importedBindings,
  ) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
          childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          collapsedShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: Text(
            'Advanced',
            style: theme.textTheme.titleMedium?.copyWith(
              color: gorionOnSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
          subtitle: Text(
            'Автообновление built-in geosite/geoip и импорт custom rule-set.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: gorionOnSurfaceMuted,
            ),
          ),
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                if (settings.hasManagedGeositeSources)
                  _MetaChip(
                    label:
                        'geosite ${_formatRefreshTimestamp(settings.lastRefreshAtForManagedSource(SplitTunnelManagedSourceKind.geosite))}',
                  ),
                if (settings.hasManagedGeoipSources)
                  _MetaChip(
                    label:
                        'geoip ${_formatRefreshTimestamp(settings.lastRefreshAtForManagedSource(SplitTunnelManagedSourceKind.geoip))}',
                  ),
                _MetaChip(
                  label:
                      'автообновление ${settings.normalizedRemoteUpdateInterval}',
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : () => _changeUpdateInterval(context),
                  icon: const Icon(Icons.schedule_rounded),
                  label: const Text('Интервал автообновления'),
                ),
                OutlinedButton.icon(
                  onPressed: busy || !settings.hasManagedGeositeSources
                      ? null
                      : () => onRefreshRequested(
                          SplitTunnelManagedSourceKind.geosite,
                        ),
                  icon: const Icon(Icons.travel_explore_rounded),
                  label: Text(
                    isConnected ? 'Обновить geosite' : 'Обновить geosite',
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: busy || !settings.hasManagedGeoipSources
                      ? null
                      : () => onRefreshRequested(
                          SplitTunnelManagedSourceKind.geoip,
                        ),
                  icon: const Icon(Icons.map_rounded),
                  label: Text(
                    isConnected ? 'Обновить geoip' : 'Обновить geoip',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              settings.hasManagedRemoteSources
                  ? 'Интервал автообновления задаёт, как часто sing-box перепроверяет remote geosite/geoip rule-set. Кнопки выше форсят одноразовое обновление нужного источника уже сейчас. Ручные домены и сети начинают работать без refresh.'
                  : 'Пока built-in geosite/geoip списки не используются. Если нужны сложные внешние правила, можно импортировать свой rule-set ниже.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: gorionOnSurfaceMuted,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Imported rule-set',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: gorionOnSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : () => _addCustomRuleSet(context),
                  icon: const Icon(Icons.library_add_rounded),
                  label: const Text('Добавить import'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (importedBindings.isEmpty)
              Text(
                'Импортированных rule-set пока нет.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: gorionOnSurfaceMuted,
                ),
              )
            else
              Column(
                children: [
                  for (final binding in importedBindings) ...[
                    _ImportedRuleSetCard(
                      action: binding.action,
                      ruleSet: binding.ruleSet,
                      onToggle: busy
                          ? null
                          : (value) => _toggleCustomRuleSet(
                              binding.action,
                              binding.ruleSet,
                              value,
                            ),
                      onDelete: busy
                          ? null
                          : () => _removeCustomRuleSet(
                              binding.action,
                              binding.ruleSet,
                            ),
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }

  void _removeGeositeTag(SplitTunnelAction action, String tag) {
    _updateGroup(
      action,
      (group) => group.copyWith(
        geositeTags: _removeStringValue(
          group.geositeTags,
          tag,
          normalizeSplitTunnelTag,
        ),
      ),
    );
  }

  void _removeGeoipTag(SplitTunnelAction action, String tag) {
    _updateGroup(
      action,
      (group) => group.copyWith(
        geoipTags: _removeStringValue(
          group.geoipTags,
          tag,
          normalizeSplitTunnelTag,
        ),
      ),
    );
  }

  void _removeDomainSuffix(SplitTunnelAction action, String value) {
    _updateGroup(
      action,
      (group) => group.copyWith(
        domainSuffixes: _removeStringValue(
          group.domainSuffixes,
          value,
          normalizeSplitTunnelDomainSuffix,
        ),
      ),
    );
  }

  void _removeIpCidr(SplitTunnelAction action, String value) {
    _updateGroup(
      action,
      (group) => group.copyWith(
        ipCidrs: _removeStringValue(
          group.ipCidrs,
          value,
          normalizeSplitTunnelIpCidr,
        ),
      ),
    );
  }

  void _toggleCustomRuleSet(
    SplitTunnelAction action,
    SplitTunnelCustomRuleSet target,
    bool enabled,
  ) {
    _updateGroup(
      action,
      (group) => group.copyWith(
        customRuleSets: [
          for (final ruleSet in group.customRuleSets)
            ruleSet.normalizedId == target.normalizedId
                ? ruleSet.copyWith(enabled: enabled)
                : ruleSet,
        ],
      ),
    );
  }

  void _removeCustomRuleSet(
    SplitTunnelAction action,
    SplitTunnelCustomRuleSet target,
  ) {
    _updateGroup(
      action,
      (group) => group.copyWith(
        customRuleSets: [
          for (final ruleSet in group.customRuleSets)
            if (ruleSet.normalizedId != target.normalizedId) ruleSet,
        ],
      ),
    );
  }

  Future<void> _changeUpdateInterval(BuildContext context) async {
    final value = await _showTextInputDialog(
      context,
      title: 'Интервал автообновления geosite/geoip',
      description:
          'Это интервал фоновой перепроверки remote geosite/geoip rule-set. Например: `12h`, `1d` или `30m`. Для немедленного обновления используйте отдельные кнопки geosite / geoip выше.',
      initialValue: settings.normalizedRemoteUpdateInterval,
      hintText: '1d',
      normalize: normalizeSplitTunnelUpdateInterval,
    );
    if (value == null || value.isEmpty) {
      return;
    }

    onChanged(settings.copyWith(remoteUpdateInterval: value));
  }

  Future<void> _addGeositeTag(
    BuildContext context,
    SplitTunnelAction action,
  ) async {
    final value = await _showTextInputDialog(
      context,
      title: '${_actionTitle(action)}: добавить geosite',
      description:
          'Выберите популярный geosite-тег ниже или введите свой вручную. Например: `cn`, `apple`, `category-ads-all`.',
      hintText: 'cn',
      normalize: normalizeSplitTunnelTag,
      suggestions: splitTunnelSuggestedGeositeTags,
    );
    if (value == null || value.isEmpty) {
      return;
    }

    _updateGroup(
      action,
      (group) => group.copyWith(
        geositeTags: _addStringValue(
          group.geositeTags,
          value,
          normalizeSplitTunnelTag,
        ),
      ),
    );
  }

  Future<void> _addGeoipTag(
    BuildContext context,
    SplitTunnelAction action,
  ) async {
    final value = await _showTextInputDialog(
      context,
      title: '${_actionTitle(action)}: добавить geoip',
      description:
          'Выберите популярный geoip-тег ниже или введите свой вручную. Например: `private`, `cn`, `telegram`, `google`.',
      hintText: 'private',
      normalize: normalizeSplitTunnelTag,
      suggestions: splitTunnelSuggestedGeoipTags,
    );
    if (value == null || value.isEmpty) {
      return;
    }

    _updateGroup(
      action,
      (group) => group.copyWith(
        geoipTags: _addStringValue(
          group.geoipTags,
          value,
          normalizeSplitTunnelTag,
        ),
      ),
    );
  }

  Future<void> _addDomainSuffix(
    BuildContext context,
    SplitTunnelAction action,
  ) async {
    final value = await _showTextInputDialog(
      context,
      title: '${_actionTitle(action)}: добавить домен',
      description:
          'Введите домен или suffix. Например: `corp.example.com`, `youtube.com`, `localhost`.',
      hintText: 'corp.example.com',
      normalize: normalizeSplitTunnelDomainSuffix,
    );
    if (value == null || value.isEmpty) {
      return;
    }

    _updateGroup(
      action,
      (group) => group.copyWith(
        domainSuffixes: _addStringValue(
          group.domainSuffixes,
          value,
          normalizeSplitTunnelDomainSuffix,
        ),
      ),
    );
  }

  Future<void> _addIpCidr(
    BuildContext context,
    SplitTunnelAction action,
  ) async {
    final value = await _showTextInputDialog(
      context,
      title: '${_actionTitle(action)}: добавить сеть',
      description: 'Например: `10.0.0.0/8` или `fd00::/8`.',
      hintText: '10.0.0.0/8',
      normalize: normalizeSplitTunnelIpCidr,
    );
    if (value == null || value.isEmpty) {
      return;
    }

    _updateGroup(
      action,
      (group) => group.copyWith(
        ipCidrs: _addStringValue(
          group.ipCidrs,
          value,
          normalizeSplitTunnelIpCidr,
        ),
      ),
    );
  }

  Future<void> _addCustomRuleSet(BuildContext context) async {
    final result = await showDialog<_CustomRuleSetDraft>(
      context: context,
      builder: (context) => const _CustomRuleSetDialog(),
    );
    if (result == null || !result.ruleSet.hasSource) {
      return;
    }

    _updateGroup(
      result.action,
      (group) => group.copyWith(
        customRuleSets: [...group.customRuleSets, result.ruleSet],
      ),
    );
  }

  void _updateGroup(
    SplitTunnelAction action,
    SplitTunnelRuleGroup Function(SplitTunnelRuleGroup group) transform,
  ) {
    final currentGroup = settings.groupFor(action);
    onChanged(settings.copyWithGroup(action, transform(currentGroup)));
  }

  static Future<String?> _showTextInputDialog(
    BuildContext context, {
    required String title,
    required String description,
    String initialValue = '',
    required String hintText,
    required String Function(String value) normalize,
    List<SplitTunnelTagSuggestion> suggestions = const [],
  }) async {
    final controller = TextEditingController(text: initialValue);
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: gorionSurface,
          title: Text(title, style: const TextStyle(color: gorionOnSurface)),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  description,
                  style: const TextStyle(
                    color: gorionOnSurfaceMuted,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    hintText: hintText,
                    hintStyle: const TextStyle(color: gorionOnSurfaceMuted),
                  ),
                ),
                if (suggestions.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  const Text(
                    'Быстрый выбор',
                    style: TextStyle(
                      color: gorionOnSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final suggestion in suggestions)
                        ActionChip(
                          onPressed: () => Navigator.of(
                            context,
                          ).pop(normalize(suggestion.tag)),
                          label: Text(suggestion.label),
                          tooltip: suggestion.description,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(normalize(controller.text)),
              child: const Text('Добавить'),
            ),
          ],
        );
      },
    );
  }
}

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
                child: Icon(_actionIcon(action), color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _actionTitle(action),
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: gorionOnSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _actionDescription(action),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: gorionOnSurfaceMuted,
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
                color: gorionOnSurface,
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
                label: const Text('Добавить geosite'),
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : onAddGeoipPressed,
                icon: const Icon(Icons.map_rounded),
                label: const Text('Добавить geoip'),
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
                color: gorionOnSurfaceMuted,
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
                color: gorionOnSurfaceMuted,
                height: 1.45,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CustomRuleSetDraft {
  const _CustomRuleSetDraft({required this.action, required this.ruleSet});

  final SplitTunnelAction action;
  final SplitTunnelCustomRuleSet ruleSet;
}

class _CustomRuleSetDialog extends StatefulWidget {
  const _CustomRuleSetDialog();

  @override
  State<_CustomRuleSetDialog> createState() => _CustomRuleSetDialogState();
}

class _CustomRuleSetDialogState extends State<_CustomRuleSetDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _sourceController;
  SplitTunnelAction _action = SplitTunnelAction.direct;
  SplitTunnelRuleSetSource _source = SplitTunnelRuleSetSource.remote;
  SplitTunnelRuleSetFormat _format = SplitTunnelRuleSetFormat.binary;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _sourceController = TextEditingController();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _sourceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final normalizedName = _nameController.text.trim();
    final normalizedSource = _sourceController.text.trim();
    final canSubmit = normalizedName.isNotEmpty && normalizedSource.isNotEmpty;

    return AlertDialog(
      backgroundColor: gorionSurface,
      title: const Text(
        'Новый imported rule-set',
        style: TextStyle(color: gorionOnSurface),
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Импорт можно привязать к direct, block или proxy. `.srs` используйте как `binary`, JSON rule-set как `source`.',
              style: TextStyle(color: gorionOnSurfaceMuted, height: 1.45),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<SplitTunnelAction>(
              initialValue: _action,
              decoration: const InputDecoration(labelText: 'Куда применять'),
              items: [
                for (final action in _splitTunnelActionOrder)
                  DropdownMenuItem(
                    value: action,
                    child: Text(_actionTitle(action)),
                  ),
              ],
              onChanged: (value) {
                if (value == null) {
                  return;
                }
                setState(() => _action = value);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Название',
                hintText: 'Corp routes',
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<SplitTunnelRuleSetSource>(
              initialValue: _source,
              decoration: const InputDecoration(labelText: 'Источник'),
              items: const [
                DropdownMenuItem(
                  value: SplitTunnelRuleSetSource.remote,
                  child: Text('Remote URL'),
                ),
                DropdownMenuItem(
                  value: SplitTunnelRuleSetSource.local,
                  child: Text('Local path'),
                ),
              ],
              onChanged: (value) {
                if (value == null) {
                  return;
                }
                setState(() => _source = value);
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<SplitTunnelRuleSetFormat>(
              initialValue: _format,
              decoration: const InputDecoration(labelText: 'Формат'),
              items: const [
                DropdownMenuItem(
                  value: SplitTunnelRuleSetFormat.binary,
                  child: Text('binary (.srs)'),
                ),
                DropdownMenuItem(
                  value: SplitTunnelRuleSetFormat.source,
                  child: Text('source (.json)'),
                ),
              ],
              onChanged: (value) {
                if (value == null) {
                  return;
                }
                setState(() => _format = value);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _sourceController,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: _source == SplitTunnelRuleSetSource.remote
                    ? 'URL'
                    : 'Путь',
                hintText: _source == SplitTunnelRuleSetSource.remote
                    ? 'https://example.com/corp.srs'
                    : r'C:\gorion\corp.srs',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: !canSubmit
              ? null
              : () => Navigator.of(context).pop(
                  _CustomRuleSetDraft(
                    action: _action,
                    ruleSet: SplitTunnelCustomRuleSet(
                      id: normalizeSplitTunnelRuleSetId(
                        '${_nameController.text.trim()}-${DateTime.now().microsecondsSinceEpoch}',
                      ),
                      label: _nameController.text.trim(),
                      source: _source,
                      url: _source == SplitTunnelRuleSetSource.remote
                          ? _sourceController.text.trim()
                          : '',
                      path: _source == SplitTunnelRuleSetSource.local
                          ? _sourceController.text.trim()
                          : '',
                      format: _format,
                    ),
                  ),
                ),
          child: const Text('Добавить'),
        ),
      ],
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
                        color: gorionOnSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      ruleSet.isRemote
                          ? ruleSet.normalizedUrl
                          : ruleSet.normalizedPath,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: gorionOnSurfaceMuted,
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
              color: gorionOnSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            preset.description,
            style: theme.textTheme.bodySmall?.copyWith(
              color: gorionOnSurfaceMuted,
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
              color: gorionOnSurface,
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
    return InputChip(
      label: Text(label),
      onDeleted: onDeleted,
      backgroundColor: Colors.white.withValues(alpha: 0.06),
      side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      labelStyle: Theme.of(
        context,
      ).textTheme.bodySmall?.copyWith(color: gorionOnSurface),
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Text(
        '$title $count',
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: gorionOnSurface,
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
                    color: gorionOnSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: gorionOnSurfaceMuted,
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: gorionOnSurfaceMuted,
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
