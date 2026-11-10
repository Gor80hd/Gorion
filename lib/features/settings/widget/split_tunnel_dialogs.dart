part of 'split_tunnel_section.dart';

class _SplitTunnelTagOption {
  const _SplitTunnelTagOption({
    required this.tag,
    required this.label,
    required this.description,
    this.isCustom = false,
  });

  final String tag;
  final String label;
  final String description;
  final bool isCustom;

  String get compactSearchText =>
      _normalizeTagSearchText('$tag $label $description');

  String get plainSearchText => '$tag $label $description'.toLowerCase();
}

class _SplitTunnelTagSelectionDialog extends StatefulWidget {
  const _SplitTunnelTagSelectionDialog({
    required this.title,
    required this.description,
    required this.searchHintText,
    required this.normalize,
    required this.suggestions,
    required this.initialValues,
  });

  final String title;
  final String description;
  final String searchHintText;
  final String Function(String value) normalize;
  final List<SplitTunnelTagSuggestion> suggestions;
  final List<String> initialValues;

  @override
  State<_SplitTunnelTagSelectionDialog> createState() =>
      _SplitTunnelTagSelectionDialogState();
}

class _SplitTunnelTagSelectionDialogState
    extends State<_SplitTunnelTagSelectionDialog> {
  late final TextEditingController _searchController;
  late final Set<String> _selectedTags;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _selectedTags = {
      for (final value in widget.initialValues)
        if (widget.normalize(value).isNotEmpty) widget.normalize(value),
    };
    _searchController.addListener(_handleSearchChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_handleSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _handleSearchChanged() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final filteredOptions = _filteredOptions;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final maxDialogHeight = MediaQuery.sizeOf(context).height * 0.72;

    final theme = Theme.of(context);
    final muted = theme.gorionTokens.onSurfaceMuted;

    return AlertDialog(
      title: Text(widget.title),
      content: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560, maxHeight: maxDialogHeight),
        child: SizedBox(
          width: screenWidth > 640 ? 560 : screenWidth * 0.88,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.description,
                style: TextStyle(color: muted, height: 1.45),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search_rounded),
                  hintText: widget.searchHintText,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                _selectedTags.isEmpty
                    ? 'Ничего не выбрано'
                    : 'Выбрано: ${_selectedTags.length}',
                style: TextStyle(color: muted, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: filteredOptions.isEmpty
                    ? Center(
                        child: Text(
                          'Ничего не найдено. Уточните поиск или введите свой тег.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: muted, height: 1.45),
                        ),
                      )
                    : Scrollbar(
                        thumbVisibility: filteredOptions.length > 8,
                        child: ListView.separated(
                          itemCount: filteredOptions.length,
                          separatorBuilder: (_, _) => Divider(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.08,
                            ),
                            height: 1,
                          ),
                          itemBuilder: (context, index) {
                            final option = filteredOptions[index];
                            final selected = _selectedTags.contains(option.tag);
                            return CheckboxListTile(
                              value: selected,
                              dense: true,
                              controlAffinity: ListTileControlAffinity.leading,
                              activeColor: theme.colorScheme.primary,
                              checkColor: theme.colorScheme.onPrimary,
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                option.label,
                                style: TextStyle(
                                  color: theme.colorScheme.onSurface,
                                ),
                              ),
                              subtitle: Text(
                                option.description,
                                style: TextStyle(color: muted, height: 1.35),
                              ),
                              onChanged: (_) => _toggleOption(option.tag),
                            );
                          },
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _selectedTags.isEmpty
              ? null
              : () => setState(_selectedTags.clear),
          child: const Text('Снять всё'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_selectedValues),
          child: const Text('Применить'),
        ),
      ],
    );
  }

  List<String> get _selectedValues {
    final values = <String>[];
    final seen = <String>{};
    for (final option in _availableOptions) {
      if (_selectedTags.contains(option.tag) && seen.add(option.tag)) {
        values.add(option.tag);
      }
    }
    return values;
  }

  List<_SplitTunnelTagOption> get _filteredOptions {
    final query = _searchController.text.trim().toLowerCase();
    final compactQuery = _normalizeTagSearchText(_searchController.text);
    if (query.isEmpty && compactQuery.isEmpty) {
      return _availableOptions;
    }

    return [
      for (final option in _availableOptions)
        if (option.plainSearchText.contains(query) ||
            (compactQuery.isNotEmpty &&
                option.compactSearchText.contains(compactQuery)))
          option,
    ];
  }

  List<_SplitTunnelTagOption> get _availableOptions {
    final options = <_SplitTunnelTagOption>[];
    final seen = <String>{};

    for (final value in _selectedTags) {
      final normalizedValue = widget.normalize(value);
      if (normalizedValue.isEmpty || !seen.add(normalizedValue)) {
        continue;
      }
      final suggestion = _suggestionForTag(normalizedValue);
      options.add(
        _SplitTunnelTagOption(
          tag: normalizedValue,
          label: suggestion?.label ?? normalizedValue,
          description: suggestion?.description ?? 'Пользовательский тег.',
          isCustom: suggestion == null,
        ),
      );
    }

    for (final suggestion in widget.suggestions) {
      final normalizedTag = widget.normalize(suggestion.tag);
      if (normalizedTag.isEmpty || seen.contains(normalizedTag)) {
        continue;
      }
      options.add(
        _SplitTunnelTagOption(
          tag: normalizedTag,
          label: suggestion.label,
          description: suggestion.description,
        ),
      );
      seen.add(normalizedTag);
    }

    final normalizedQuery = widget.normalize(_searchController.text);
    if (normalizedQuery.isNotEmpty && !seen.contains(normalizedQuery)) {
      options.insert(
        0,
        _SplitTunnelTagOption(
          tag: normalizedQuery,
          label: normalizedQuery,
          description: 'Добавить пользовательский тег из строки поиска.',
          isCustom: true,
        ),
      );
    }

    return options;
  }

  SplitTunnelTagSuggestion? _suggestionForTag(String tag) {
    final normalizedTag = widget.normalize(tag);
    for (final suggestion in widget.suggestions) {
      if (widget.normalize(suggestion.tag) == normalizedTag) {
        return suggestion;
      }
    }
    return null;
  }

  void _toggleOption(String tag) {
    setState(() {
      if (_selectedTags.contains(tag)) {
        _selectedTags.remove(tag);
      } else {
        _selectedTags.add(tag);
      }
    });
  }
}

String _normalizeTagSearchText(String value) {
  return value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9а-я]+'), '');
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
      title: const Text('Новый imported rule-set'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Импорт можно привязать к direct, block или proxy. `.srs` используйте как `binary`, JSON rule-set как `source`.',
              style: TextStyle(
                color: Theme.of(context).gorionTokens.onSurfaceMuted,
                height: 1.45,
              ),
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
