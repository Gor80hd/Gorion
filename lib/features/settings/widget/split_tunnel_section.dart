import 'package:flutter/material.dart';
import 'package:gorion_clean/app/theme.dart';
import 'package:gorion_clean/core/widget/glass_panel.dart';
import 'package:gorion_clean/features/settings/data/split_tunnel_catalog.dart';
import 'package:gorion_clean/features/settings/model/split_tunnel_settings.dart';

part 'split_tunnel_dialogs.dart';
part 'split_tunnel_cards.dart';

const _splitTunnelActionOrder = <SplitTunnelAction>[
  SplitTunnelAction.direct,
  SplitTunnelAction.block,
  SplitTunnelAction.proxy,
];

Color _splitTunnelPrimaryInk(ThemeData theme) {
  return theme.brightness == Brightness.light
      ? Colors.black.withValues(alpha: 0.90)
      : gorionOnSurface;
}

Color _splitTunnelSecondaryInk(ThemeData theme) {
  return theme.brightness == Brightness.light
      ? Colors.black.withValues(alpha: 0.58)
      : gorionOnSurfaceMuted;
}

Color _splitTunnelIconInk(ThemeData theme, Color darkColor) {
  return theme.brightness == Brightness.light
      ? Colors.black.withValues(alpha: 0.86)
      : darkColor;
}

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
      borderRadius: 20,
      padding: const EdgeInsets.all(20),
      opacity: 0.06,
      backgroundColor: Colors.white,
      strokeColor: Colors.white,
      strokeOpacity: 0.05,
      strokeWidth: 1,
      showGlow: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.alt_route_rounded,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Маршрутизация трафика',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: _splitTunnelPrimaryInk(theme),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Что идёт в direct, что блокируется, а что остаётся на proxy. Пресеты добавляют готовые правила, ниже — свои домены и сети.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _splitTunnelSecondaryInk(theme),
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
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
              color: _splitTunnelPrimaryInk(theme),
              fontWeight: FontWeight.w700,
            ),
          ),
          subtitle: Text(
            'Автообновление built-in geosite/geoip и импорт custom rule-set.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: _splitTunnelSecondaryInk(theme),
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
                color: _splitTunnelSecondaryInk(theme),
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
                      color: _splitTunnelPrimaryInk(theme),
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
                  color: _splitTunnelSecondaryInk(theme),
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
    final selectedValues = await _showTagSelectionDialog(
      context,
      title: '${_actionTitle(action)}: добавить geosite',
      description:
          'Отметьте geosite-теги, которые должны участвовать в этом маршруте. Список фильтруется поиском, а при необходимости можно добавить свой тег прямо из строки поиска.',
      searchHintText: 'Россия, category-ru, apple, youtube',
      normalize: normalizeSplitTunnelTag,
      suggestions: splitTunnelSuggestedGeositeTags,
      initialValues: settings.groupFor(action).geositeTags,
    );
    if (selectedValues == null) {
      return;
    }

    _updateGroup(
      action,
      (group) => group.copyWith(geositeTags: selectedValues),
    );
  }

  Future<void> _addGeoipTag(
    BuildContext context,
    SplitTunnelAction action,
  ) async {
    final selectedValues = await _showTagSelectionDialog(
      context,
      title: '${_actionTitle(action)}: добавить geoip',
      description:
          'Отметьте geoip-теги, которые должны участвовать в этом маршруте. Список фильтруется поиском, а при необходимости можно добавить свой тег прямо из строки поиска.',
      searchHintText: 'Россия, ru, private, telegram',
      normalize: normalizeSplitTunnelTag,
      suggestions: splitTunnelSuggestedGeoipTags,
      initialValues: settings.groupFor(action).geoipTags,
    );
    if (selectedValues == null) {
      return;
    }

    _updateGroup(action, (group) => group.copyWith(geoipTags: selectedValues));
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
        final theme = Theme.of(context);
        return AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  description,
                  style: TextStyle(
                    color: theme.gorionTokens.onSurfaceMuted,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: controller,
                  decoration: InputDecoration(hintText: hintText),
                ),
                if (suggestions.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    'Быстрый выбор',
                    style: TextStyle(
                      color: theme.colorScheme.onSurface,
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

  static Future<List<String>?> _showTagSelectionDialog(
    BuildContext context, {
    required String title,
    required String description,
    required String searchHintText,
    required String Function(String value) normalize,
    required List<SplitTunnelTagSuggestion> suggestions,
    required List<String> initialValues,
  }) {
    return showDialog<List<String>>(
      context: context,
      builder: (context) {
        return _SplitTunnelTagSelectionDialog(
          title: title,
          description: description,
          searchHintText: searchHintText,
          normalize: normalize,
          suggestions: suggestions,
          initialValues: initialValues,
        );
      },
    );
  }
}
