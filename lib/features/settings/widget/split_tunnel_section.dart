import 'package:flutter/material.dart';
import 'package:gorion_clean/app/theme.dart';
import 'package:gorion_clean/core/widget/glass_panel.dart';
import 'package:gorion_clean/features/settings/data/split_tunnel_catalog.dart';
import 'package:gorion_clean/features/settings/model/split_tunnel_settings.dart';

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
  final Future<void> Function() onRefreshRequested;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
            'Split tunneling',
            style: theme.textTheme.titleLarge?.copyWith(
              color: gorionOnSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Совпавшие geosite, geoip, custom rule-set и вручную добавленные домены/IP уходят в DIRECT. Остальной трафик остаётся на активном proxy selector.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: gorionOnSurfaceMuted,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 18),
          _ToggleCard(
            title: 'Включить split tunneling',
            subtitle: settings.hasRules
                ? settings.enabled
                      ? 'Правила активны и будут вставлены в route.rule_set / route.rules при следующем connect.'
                      : 'Правила сохранены, но сейчас выключены и не попадут в runtime.'
                : 'Сначала добавьте хотя бы один geosite, geoip, custom rule-set, domain suffix или IP CIDR.',
            value: settings.enabled,
            onChanged: (value) => onChanged(settings.copyWith(enabled: value)),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _MetaChip(
                label:
                    'update_interval ${settings.normalizedRemoteUpdateInterval}',
              ),
              _MetaChip(
                label:
                    'last refresh ${_formatRefreshTimestamp(settings.lastRemoteRefreshAt)}',
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : () => _changeUpdateInterval(context),
                icon: const Icon(Icons.schedule_rounded),
                label: const Text('Изменить интервал'),
              ),
              OutlinedButton.icon(
                onPressed: busy || !settings.hasManagedRemoteSources
                    ? null
                    : onRefreshRequested,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(
                  isConnected
                      ? 'Обновить geosite/geoip и переподключить'
                      : 'Обновить geosite/geoip',
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _SubsectionTitle(
            title: 'Пресеты',
            description:
                'Кнопки ниже сразу добавят строки в split tunneling конфиг и включат секцию.',
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final preset in splitTunnelPresets)
                OutlinedButton.icon(
                  onPressed: busy
                      ? null
                      : () => onChanged(
                          applySplitTunnelPreset(
                            current: settings,
                            preset: preset,
                          ),
                        ),
                  icon: const Icon(Icons.auto_awesome_rounded),
                  label: Text(preset.label),
                ),
            ],
          ),
          const SizedBox(height: 18),
          _SubsectionTitle(
            title: 'Built-in geosite',
            description:
                'Предлагаемые geosite тянут готовые `.srs` из MetaCubeX sing branch. Можно включить подсказки или добавить свой tag вручную.',
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final entry in splitTunnelSuggestedGeositeEntries)
                FilterChip(
                  selected: settings.normalizedGeositeTags.contains(entry.tag),
                  label: Text(entry.label),
                  onSelected: busy ? null : (_) => _toggleGeositeTag(entry.tag),
                  tooltip: entry.description,
                  selectedColor: gorionAccent.withValues(alpha: 0.18),
                  backgroundColor: Colors.white.withValues(alpha: 0.05),
                  labelStyle: theme.textTheme.bodySmall?.copyWith(
                    color: gorionOnSurface,
                    fontWeight: FontWeight.w600,
                  ),
                  side: BorderSide(
                    color: settings.normalizedGeositeTags.contains(entry.tag)
                        ? gorionAccent.withValues(alpha: 0.34)
                        : Colors.white.withValues(alpha: 0.08),
                  ),
                ),
              ActionChip(
                onPressed: busy ? null : () => _addGeositeTag(context),
                label: const Text('Добавить geosite tag'),
                avatar: const Icon(Icons.add_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _TokenWrap(
            values: settings.normalizedGeositeTags,
            emptyLabel: 'Пока нет geosite правил.',
            tokenBuilder: (tag) => 'geosite:$tag',
            onDeleted: busy ? null : _removeGeositeTag,
          ),
          const SizedBox(height: 18),
          _SubsectionTitle(
            title: 'Built-in geoip',
            description:
                'GeoIP подборки тоже используют готовые `.srs`. Хорошо подходят для private/LAN, страновых диапазонов и крупных сервисов.',
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final entry in splitTunnelSuggestedGeoipEntries)
                FilterChip(
                  selected: settings.normalizedGeoipTags.contains(entry.tag),
                  label: Text(entry.label),
                  onSelected: busy ? null : (_) => _toggleGeoipTag(entry.tag),
                  tooltip: entry.description,
                  selectedColor: gorionAccent.withValues(alpha: 0.18),
                  backgroundColor: Colors.white.withValues(alpha: 0.05),
                  labelStyle: theme.textTheme.bodySmall?.copyWith(
                    color: gorionOnSurface,
                    fontWeight: FontWeight.w600,
                  ),
                  side: BorderSide(
                    color: settings.normalizedGeoipTags.contains(entry.tag)
                        ? gorionAccent.withValues(alpha: 0.34)
                        : Colors.white.withValues(alpha: 0.08),
                  ),
                ),
              ActionChip(
                onPressed: busy ? null : () => _addGeoipTag(context),
                label: const Text('Добавить geoip tag'),
                avatar: const Icon(Icons.add_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _TokenWrap(
            values: settings.normalizedGeoipTags,
            emptyLabel: 'Пока нет geoip правил.',
            tokenBuilder: (tag) => 'geoip:$tag',
            onDeleted: busy ? null : _removeGeoipTag,
          ),
          const SizedBox(height: 18),
          _SubsectionTitle(
            title: 'Вручную: domain suffix / IP CIDR',
            description:
                'Эти значения собираются в inline rule-set и сразу мачтятся в split tunnel без внешних источников.',
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              ActionChip(
                onPressed: busy ? null : () => _addDomainSuffix(context),
                label: const Text('Добавить domain suffix'),
                avatar: const Icon(Icons.language_rounded, size: 18),
              ),
              ActionChip(
                onPressed: busy ? null : () => _addIpCidr(context),
                label: const Text('Добавить IP CIDR'),
                avatar: const Icon(Icons.lan_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _TokenWrap(
            values: settings.normalizedDomainSuffixes,
            emptyLabel: 'Domain suffix пока пустой.',
            tokenBuilder: (value) => 'suffix:$value',
            onDeleted: busy ? null : _removeDomainSuffix,
          ),
          const SizedBox(height: 10),
          _TokenWrap(
            values: settings.normalizedIpCidrs,
            emptyLabel: 'IP CIDR пока пустой.',
            tokenBuilder: (value) => 'cidr:$value',
            onDeleted: busy ? null : _removeIpCidr,
          ),
          const SizedBox(height: 18),
          _SubsectionTitle(
            title: 'Свои rule-set',
            description:
                'Можно добавить свой remote URL (`.srs` / `.json`) или локальный путь к rule-set. Они тоже попадут в DIRECT.',
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: busy ? null : () => _addCustomRuleSet(context),
            icon: const Icon(Icons.library_add_rounded),
            label: const Text('Добавить custom rule-set'),
          ),
          const SizedBox(height: 10),
          if (settings.normalizedCustomRuleSets.isEmpty)
            Text(
              'Пользовательские rule-set пока не добавлены.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: gorionOnSurfaceMuted,
              ),
            )
          else
            Column(
              children: [
                for (final ruleSet in settings.normalizedCustomRuleSets) ...[
                  _CustomRuleSetCard(
                    ruleSet: ruleSet,
                    onToggle: busy
                        ? null
                        : (value) => _toggleCustomRuleSet(ruleSet, value),
                    onDelete: busy ? null : () => _removeCustomRuleSet(ruleSet),
                  ),
                  const SizedBox(height: 10),
                ],
              ],
            ),
        ],
      ),
    );
  }

  void _toggleGeositeTag(String tag) {
    onChanged(
      settings.copyWith(
        geositeTags: _toggleStringValue(
          settings.geositeTags,
          tag,
          normalizeSplitTunnelTag,
        ),
      ),
    );
  }

  void _toggleGeoipTag(String tag) {
    onChanged(
      settings.copyWith(
        geoipTags: _toggleStringValue(
          settings.geoipTags,
          tag,
          normalizeSplitTunnelTag,
        ),
      ),
    );
  }

  void _removeGeositeTag(String tag) {
    onChanged(
      settings.copyWith(
        geositeTags: _removeStringValue(
          settings.geositeTags,
          tag,
          normalizeSplitTunnelTag,
        ),
      ),
    );
  }

  void _removeGeoipTag(String tag) {
    onChanged(
      settings.copyWith(
        geoipTags: _removeStringValue(
          settings.geoipTags,
          tag,
          normalizeSplitTunnelTag,
        ),
      ),
    );
  }

  void _removeDomainSuffix(String value) {
    onChanged(
      settings.copyWith(
        domainSuffixes: _removeStringValue(
          settings.domainSuffixes,
          value,
          normalizeSplitTunnelDomainSuffix,
        ),
      ),
    );
  }

  void _removeIpCidr(String value) {
    onChanged(
      settings.copyWith(
        ipCidrs: _removeStringValue(
          settings.ipCidrs,
          value,
          normalizeSplitTunnelIpCidr,
        ),
      ),
    );
  }

  void _toggleCustomRuleSet(SplitTunnelCustomRuleSet target, bool enabled) {
    onChanged(
      settings.copyWith(
        customRuleSets: [
          for (final ruleSet in settings.customRuleSets)
            ruleSet.normalizedId == target.normalizedId
                ? ruleSet.copyWith(enabled: enabled)
                : ruleSet,
        ],
      ),
    );
  }

  void _removeCustomRuleSet(SplitTunnelCustomRuleSet target) {
    onChanged(
      settings.copyWith(
        customRuleSets: [
          for (final ruleSet in settings.customRuleSets)
            if (ruleSet.normalizedId != target.normalizedId) ruleSet,
        ],
      ),
    );
  }

  Future<void> _changeUpdateInterval(BuildContext context) async {
    final value = await _showTextInputDialog(
      context,
      title: 'Интервал обновления remote rule-set',
      description:
          'Введите значение в формате sing-box, например `12h`, `1d` или `30m`.',
      initialValue: settings.normalizedRemoteUpdateInterval,
      hintText: '1d',
      normalize: normalizeSplitTunnelUpdateInterval,
    );
    if (value == null || value.isEmpty) {
      return;
    }

    onChanged(settings.copyWith(remoteUpdateInterval: value));
  }

  Future<void> _addGeositeTag(BuildContext context) async {
    final value = await _showTextInputDialog(
      context,
      title: 'Добавить geosite tag',
      description:
          'Например: `cn`, `apple`, `steam@cn`. Для built-in geosite используется MetaCubeX sing `.srs`.',
      hintText: 'cn',
      normalize: normalizeSplitTunnelTag,
    );
    if (value == null || value.isEmpty) {
      return;
    }
    onChanged(
      settings.copyWith(
        geositeTags: _addStringValue(
          settings.geositeTags,
          value,
          normalizeSplitTunnelTag,
        ),
      ),
    );
  }

  Future<void> _addGeoipTag(BuildContext context) async {
    final value = await _showTextInputDialog(
      context,
      title: 'Добавить geoip tag',
      description: 'Например: `private`, `ru`, `telegram`, `google`.',
      hintText: 'private',
      normalize: normalizeSplitTunnelTag,
    );
    if (value == null || value.isEmpty) {
      return;
    }
    onChanged(
      settings.copyWith(
        geoipTags: _addStringValue(
          settings.geoipTags,
          value,
          normalizeSplitTunnelTag,
        ),
      ),
    );
  }

  Future<void> _addDomainSuffix(BuildContext context) async {
    final value = await _showTextInputDialog(
      context,
      title: 'Добавить domain suffix',
      description: 'Например: `corp.example.com`, `local`, `internal`.',
      hintText: 'corp.example.com',
      normalize: normalizeSplitTunnelDomainSuffix,
    );
    if (value == null || value.isEmpty) {
      return;
    }
    onChanged(
      settings.copyWith(
        domainSuffixes: _addStringValue(
          settings.domainSuffixes,
          value,
          normalizeSplitTunnelDomainSuffix,
        ),
      ),
    );
  }

  Future<void> _addIpCidr(BuildContext context) async {
    final value = await _showTextInputDialog(
      context,
      title: 'Добавить IP CIDR',
      description: 'Например: `10.0.0.0/8` или `fd00::/8`.',
      hintText: '10.0.0.0/8',
      normalize: normalizeSplitTunnelIpCidr,
    );
    if (value == null || value.isEmpty) {
      return;
    }
    onChanged(
      settings.copyWith(
        ipCidrs: _addStringValue(
          settings.ipCidrs,
          value,
          normalizeSplitTunnelIpCidr,
        ),
      ),
    );
  }

  Future<void> _addCustomRuleSet(BuildContext context) async {
    final result = await showDialog<SplitTunnelCustomRuleSet>(
      context: context,
      builder: (context) => const _CustomRuleSetDialog(),
    );
    if (result == null || !result.hasSource) {
      return;
    }

    onChanged(
      settings.copyWith(customRuleSets: [...settings.customRuleSets, result]),
    );
  }

  static Future<String?> _showTextInputDialog(
    BuildContext context, {
    required String title,
    required String description,
    String initialValue = '',
    required String hintText,
    required String Function(String value) normalize,
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

class _CustomRuleSetDialog extends StatefulWidget {
  const _CustomRuleSetDialog();

  @override
  State<_CustomRuleSetDialog> createState() => _CustomRuleSetDialogState();
}

class _CustomRuleSetDialogState extends State<_CustomRuleSetDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _sourceController;
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
        'Новый custom rule-set',
        style: TextStyle(color: gorionOnSurface),
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Добавьте свой remote URL или local path. `.srs` используйте как `binary`, headless JSON rule-set как `source`.',
              style: TextStyle(color: gorionOnSurfaceMuted, height: 1.45),
            ),
            const SizedBox(height: 14),
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
              value: _source,
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
              value: _format,
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
                  SplitTunnelCustomRuleSet(
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
          child: const Text('Добавить'),
        ),
      ],
    );
  }
}

class _CustomRuleSetCard extends StatelessWidget {
  const _CustomRuleSetCard({
    required this.ruleSet,
    required this.onToggle,
    required this.onDelete,
  });

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
                tooltip: 'Удалить rule-set',
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

class _TokenWrap extends StatelessWidget {
  const _TokenWrap({
    required this.values,
    required this.emptyLabel,
    required this.tokenBuilder,
    required this.onDeleted,
  });

  final List<String> values;
  final String emptyLabel;
  final String Function(String value) tokenBuilder;
  final ValueChanged<String>? onDeleted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (values.isEmpty) {
      return Text(
        emptyLabel,
        style: theme.textTheme.bodySmall?.copyWith(color: gorionOnSurfaceMuted),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final value in values)
          InputChip(
            label: Text(tokenBuilder(value)),
            onDeleted: onDeleted == null ? null : () => onDeleted!(value),
            backgroundColor: Colors.white.withValues(alpha: 0.06),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
            labelStyle: theme.textTheme.bodySmall?.copyWith(
              color: gorionOnSurface,
            ),
          ),
      ],
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

class _SubsectionTitle extends StatelessWidget {
  const _SubsectionTitle({required this.title, required this.description});

  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            color: gorionOnSurface,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          description,
          style: theme.textTheme.bodySmall?.copyWith(
            color: gorionOnSurfaceMuted,
            height: 1.45,
          ),
        ),
      ],
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

List<String> _toggleStringValue(
  List<String> current,
  String value,
  String Function(String value) normalize,
) {
  final normalized = normalize(value);
  if (normalized.isEmpty) {
    return current;
  }

  final existingIndex = current.indexWhere(
    (item) => normalize(item) == normalized,
  );
  if (existingIndex >= 0) {
    return [
      for (var index = 0; index < current.length; index++)
        if (index != existingIndex) current[index],
    ];
  }

  return [...current, normalized];
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
