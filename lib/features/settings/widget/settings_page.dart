import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/app/theme_preferences.dart';
import 'package:gorion_clean/app/theme.dart';
import 'package:gorion_clean/app/theme_settings.dart';
import 'package:gorion_clean/features/auto_select/model/auto_select_state.dart';
import 'package:gorion_clean/core/widget/glass_panel.dart';
import 'package:gorion_clean/core/widget/page_reveal.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';
import 'package:gorion_clean/features/settings/application/desktop_settings_controller.dart';
import 'package:gorion_clean/features/settings/model/connection_tuning_settings.dart';
import 'package:gorion_clean/features/settings/model/split_tunnel_settings.dart';
import 'package:gorion_clean/features/settings/widget/split_tunnel_section.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key, this.animateOnMount = true});

  final bool animateOnMount;

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

enum _SettingsGroup {
  appearance(
    title: 'Тема приложения',
    description: 'Режим system/light/dark и выбор цветовой гаммы интерфейса.',
    detailDescription:
        'Влияет на весь интерфейс приложения и применяется сразу, без отдельного сохранения.',
    icon: Icons.palette_outlined,
    accentColor: Color(0xFF57E3D0),
  ),
  tls(
    title: 'TLS маскировка',
    description:
        'uTLS fingerprint, SNI donor и record fragment для TLS outbound.',
    detailDescription:
        'Параметры маскировки TLS handshake и anti-DPI override поверх активного профиля.',
    icon: Icons.shield_outlined,
    accentColor: Color(0xFF6DD3FF),
  ),
  vless(
    title: 'VLESS transport',
    description: 'Vision flow, xudp и mux для VLESS / Reality серверов.',
    detailDescription:
        'Принудительные transport-поля для VLESS outbound, когда нужен совместимый профиль под Reality и Xray.',
    icon: Icons.hub_outlined,
    accentColor: Color(0xFFFFC857),
  ),
  autoSelect(
    title: 'Автовыбор сервера',
    description: 'Интервал фоновой проверки лучшего сервера и замены текущего.',
    detailDescription:
        'Фоновая maintenance-проверка current best server. Изменения сохраняются сразу и не требуют переподключения.',
    icon: Icons.auto_awesome_outlined,
    accentColor: Color(0xFF8B9CFF),
  ),
  splitTunnel(
    title: 'Split tunneling',
    description:
        'Понятные правила direct, block и proxy с пресетами и ручными доменами.',
    detailDescription:
        'Управление route.rule_set для bypass, block и принудительного proxy-маршрута без перегруженного low-level UI.',
    icon: Icons.alt_route_rounded,
    accentColor: Color(0xFF1EFFAC),
  ),
  desktop(
    title: 'Запуск и трей',
    description:
        'Автозапуск Windows, скрытый старт в трей и автоподключение после старта.',
    detailDescription:
        'Параметры поведения приложения при логине в Windows и при обычном запуске на рабочем столе.',
    icon: Icons.desktop_windows_outlined,
    accentColor: Color(0xFF72A8FF),
  );

  const _SettingsGroup({
    required this.title,
    required this.description,
    required this.detailDescription,
    required this.icon,
    required this.accentColor,
  });

  final String title;
  final String description;
  final String detailDescription;
  final IconData icon;
  final Color accentColor;
}

class _SettingsGroupSnapshot {
  const _SettingsGroupSnapshot({
    required this.badgeLabel,
    required this.supportingLabel,
    required this.hasPendingChanges,
  });

  final String badgeLabel;
  final String supportingLabel;
  final bool hasPendingChanges;
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final TextEditingController _sniController;
  late final ScrollController _scrollController;
  ConnectionTuningSettings _draft = const ConnectionTuningSettings();
  ConnectionTuningSettings? _syncedSettings;
  int? _autoSelectIntervalDraftMinutes;
  int? _syncedAutoSelectIntervalMinutes;
  ConnectionTuningSettings? _failedConnectionSettings;
  int? _failedAutoSelectIntervalMinutes;
  Timer? _connectionAutoSaveTimer;
  Timer? _autoSelectAutoSaveTimer;
  bool _autoSaveFlushScheduled = false;
  _SettingsGroup? _selectedGroup;

  @override
  void initState() {
    super.initState();
    _sniController = TextEditingController();
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
    _connectionAutoSaveTimer?.cancel();
    _autoSelectAutoSaveTimer?.cancel();
    _sniController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dashboardState = ref.watch(dashboardControllerProvider);
    final appThemeSettings = ref.watch(appThemeSettingsProvider);
    final desktopSettingsState = ref.watch(desktopSettingsControllerProvider);
    _syncDraft(dashboardState.connectionTuningSettings);

    final savedBestServerCheckIntervalMinutes =
        dashboardState.autoSelectSettings.bestServerCheckIntervalMinutes;
    _syncAutoSelectInterval(savedBestServerCheckIntervalMinutes);

    final bestServerCheckIntervalMinutes =
        _autoSelectIntervalDraftMinutes ?? savedBestServerCheckIntervalMinutes;
    final hasPendingConnectionChanges =
        _draft != dashboardState.connectionTuningSettings;
    final hasPendingAutoSelectChanges =
        bestServerCheckIntervalMinutes != savedBestServerCheckIntervalMinutes;
    final hasPendingChanges =
        hasPendingConnectionChanges || hasPendingAutoSelectChanges;
    final hasFailedConnectionSave =
        hasPendingConnectionChanges && _failedConnectionSettings == _draft;
    final hasFailedAutoSelectSave =
        hasPendingAutoSelectChanges &&
        _failedAutoSelectIntervalMinutes == bestServerCheckIntervalMinutes;
    final hasFailedSaves = hasFailedConnectionSave || hasFailedAutoSelectSave;
    final isConnected =
        dashboardState.connectionStage == ConnectionStage.connected;
    final canManualSave = !dashboardState.busy && hasFailedSaves;

    if (!dashboardState.busy) {
      _scheduleAutoSaveFlush();
    }

    final content = LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 1080;
        final cardWidth = isWide
            ? (constraints.maxWidth - 18) / 2
            : constraints.maxWidth;

        final sectionContent = _selectedGroup == null
            ? _buildOverview(
                context,
                dashboardState: dashboardState,
                appThemeSettings: appThemeSettings,
                desktopSettingsState: desktopSettingsState,
                isWide: isWide,
                bestServerCheckIntervalMinutes: bestServerCheckIntervalMinutes,
              )
            : _buildGroupPage(
                context,
                dashboardState: dashboardState,
                appThemeSettings: appThemeSettings,
                desktopSettingsState: desktopSettingsState,
                bestServerCheckIntervalMinutes: bestServerCheckIntervalMinutes,
              );

        return SingleChildScrollView(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(0, 0, 0, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _HeroPanel(
                busy: dashboardState.busy,
                activeGroup: _selectedGroup,
                hasPendingChanges: hasPendingChanges,
                hasFailedSaves: hasFailedSaves,
                canManualSave: canManualSave,
                isConnected: isConnected,
                onSave: canManualSave ? _savePendingChanges : null,
                onBack: _selectedGroup == null ? null : _closeGroup,
              ),
              const SizedBox(height: 10),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                layoutBuilder: (currentChild, previousChildren) {
                  return Stack(
                    alignment: Alignment.topLeft,
                    children: [...previousChildren, ?currentChild],
                  );
                },
                child: sectionContent,
              ),
            ],
          ),
        );
      },
    );

    if (!widget.animateOnMount) {
      return content;
    }

    return PageReveal(
      duration: const Duration(milliseconds: 240),
      offset: const Offset(0.02, 0.02),
      child: content,
    );
  }

  Iterable<_SettingsGroup> get _visibleGroups sync* {
    yield _SettingsGroup.appearance;
    yield _SettingsGroup.tls;
    yield _SettingsGroup.vless;
    yield _SettingsGroup.autoSelect;
    yield _SettingsGroup.splitTunnel;
    if (Platform.isWindows) {
      yield _SettingsGroup.desktop;
    }
  }

  Widget _buildOverview(
    BuildContext context, {
    required DashboardState dashboardState,
    required AppThemeSettings appThemeSettings,
    required DesktopSettingsState desktopSettingsState,
    required bool isWide,
    required int bestServerCheckIntervalMinutes,
  }) {
    final groups = _visibleGroups.toList(growable: false);

    Widget buildCard(_SettingsGroup group) {
      return _SettingsGroupCard(
        group: group,
        snapshot: _buildGroupSnapshot(
          group,
          dashboardState,
          appThemeSettings,
          desktopSettingsState,
          bestServerCheckIntervalMinutes,
        ),
        onTap: () => _openGroup(group),
      );
    }

    if (!isWide) {
      return Column(
        key: const ValueKey('settings-overview'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < groups.length; index += 1) ...[
            buildCard(groups[index]),
            if (index != groups.length - 1) const SizedBox(height: 18),
          ],
        ],
      );
    }

    return GridView.builder(
      key: const ValueKey('settings-overview'),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 18,
        mainAxisSpacing: 18,
        mainAxisExtent: 282,
      ),
      itemCount: groups.length,
      itemBuilder: (context, index) => buildCard(groups[index]),
    );
  }

  Widget _buildGroupPage(
    BuildContext context, {
    required DashboardState dashboardState,
    required AppThemeSettings appThemeSettings,
    required DesktopSettingsState desktopSettingsState,
    required int bestServerCheckIntervalMinutes,
  }) {
    final group = _selectedGroup!;
    final isConnected =
        dashboardState.connectionStage == ConnectionStage.connected;

    return Column(
      key: ValueKey('settings-group-${group.name}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (group == _SettingsGroup.appearance)
          _buildThemeSection(appThemeSettings),
        if (group == _SettingsGroup.tls) _buildTlsSection(),
        if (group == _SettingsGroup.vless) _buildVlessSection(),
        if (group == _SettingsGroup.autoSelect)
          _buildAutoSelectSection(
            dashboardState,
            bestServerCheckIntervalMinutes,
          ),
        if (group == _SettingsGroup.splitTunnel)
          _buildSplitTunnelSection(dashboardState, isConnected),
        if (group == _SettingsGroup.desktop)
          _buildDesktopSection(desktopSettingsState),
      ],
    );
  }

  Widget _buildThemeSection(AppThemeSettings appThemeSettings) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;
    final themeNotifier = ref.read(appThemeSettingsProvider.notifier);

    return _SettingsSection(
      title: 'Тема приложения',
      description:
          'Режим интерфейса и акцентная палитра сохраняются отдельно от сетевых настроек и применяются сразу во всём приложении.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Режим',
            style: theme.textTheme.titleMedium?.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final mode in AppThemeModePreference.values)
                SizedBox(
                  width: 240,
                  child: _ThemeChoiceCard(
                    title: mode.title,
                    subtitle: mode.description,
                    selected: appThemeSettings.mode == mode,
                    accentColor: scheme.primary,
                    onTap: () => themeNotifier.setMode(mode),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            'Цветовая гамма',
            style: theme.textTheme.titleMedium?.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final palette in AppThemePalette.values)
                SizedBox(
                  width: 240,
                  child: _ThemePaletteCard(
                    title: palette.title,
                    subtitle: palette.description,
                    previewColor: describeAppThemePalette(palette).previewColor,
                    selected: appThemeSettings.palette == palette,
                    onTap: () => themeNotifier.setPalette(palette),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Если выбран системный режим, приложение автоматически переключится между светлой и тёмной темой вместе с ОС, но сохранит выбранную палитру акцентов.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: muted,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTlsSection() {
    return _SettingsSection(
      title: 'TLS маскировка',
      description:
          'Применяется только к узлам, где TLS уже включён в профиле. Выключенный тумблер не удаляет существующие параметры из подписки.',
      child: Column(
        children: [
          _ToggleTile(
            title: 'uTLS fingerprint = chrome',
            subtitle:
                'Форсирует tls.utls.enabled и tls.utls.fingerprint=chrome для совместимых TLS outbound.',
            value: _draft.forceChromeUtls,
            onChanged: (value) {
              _updateDraft(_draft.copyWith(forceChromeUtls: value));
            },
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _sniController,
            onChanged: (value) {
              _updateDraft(
                _draft.copyWith(sniDonor: value),
                debounce: const Duration(milliseconds: 650),
              );
            },
            decoration: InputDecoration(
              labelText: 'SNI-донор',
              hintText: 'cdn.example.com',
              helperText: 'Если задан, подставляется в tls.server_name.',
              suffixIcon: _draft.normalizedSniDonor.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Очистить',
                      onPressed: () {
                        _sniController.clear();
                        _updateDraft(_draft.copyWith(sniDonor: ''));
                      },
                      icon: const Icon(Icons.close_rounded),
                    ),
            ),
          ),
          const SizedBox(height: 14),
          _ToggleTile(
            title: 'TLS record fragment',
            subtitle:
                'Включает tls.record_fragment для TLS handshake. Полезно как anti-DPI fallback.',
            value: _draft.enableTlsRecordFragment,
            onChanged: (value) {
              _updateDraft(_draft.copyWith(enableTlsRecordFragment: value));
            },
          ),
        ],
      ),
    );
  }

  Widget _buildVlessSection() {
    return _SettingsSection(
      title: 'VLESS transport',
      description:
          'Эти override накладываются только на VLESS outbound. Нужны в основном для Reality и Xray-совместимых серверов.',
      child: Column(
        children: [
          _ToggleTile(
            title: 'flow = xtls-rprx-vision',
            subtitle: 'Форсирует Vision flow на VLESS outbound.',
            value: _draft.forceVisionFlow,
            onChanged: (value) {
              _updateDraft(_draft.copyWith(forceVisionFlow: value));
            },
          ),
          const SizedBox(height: 14),
          _ToggleTile(
            title: 'packet_encoding = xudp',
            subtitle:
                'Форсирует xudp для UDP packet encoding на VLESS outbound.',
            value: _draft.forceXudpPacketEncoding,
            onChanged: (value) {
              _updateDraft(_draft.copyWith(forceXudpPacketEncoding: value));
            },
          ),
          const SizedBox(height: 14),
          _ToggleTile(
            title: 'Multiplex (mux)',
            subtitle:
                'Включает multiplex.enabled на VLESS outbound и оставляет существующие mux-поля нетронутыми.',
            value: _draft.enableMultiplex,
            onChanged: (value) {
              _updateDraft(_draft.copyWith(enableMultiplex: value));
            },
          ),
        ],
      ),
    );
  }

  Widget _buildAutoSelectSection(
    DashboardState dashboardState,
    int bestServerCheckIntervalMinutes,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;
    final draftMinutes =
        _autoSelectIntervalDraftMinutes ?? bestServerCheckIntervalMinutes;

    return _SettingsSection(
      title: 'Автовыбор сервера',
      description:
          'Частота фоновой проверки best server сохраняется отдельно от transport overrides и начинает действовать сразу, без переподключения.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            decoration: BoxDecoration(
              color: scheme.onSurface.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: scheme.onSurface.withValues(alpha: 0.08),
              ),
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
                            'Частота проверки best server',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: scheme.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Maintenance-проверка текущего сервера и поиск замены будут идти с этим интервалом.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: muted,
                              height: 1.45,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 14),
                    _Badge(
                      label: _formatBestServerCheckIntervalBadge(draftMinutes),
                      backgroundColor: const Color(
                        0xFF6DD3FF,
                      ).withValues(alpha: 0.14),
                      foregroundColor: const Color(0xFF6DD3FF),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Slider(
                  value: draftMinutes.toDouble(),
                  min: autoSelectBestServerCheckIntervalMinMinutes.toDouble(),
                  max: autoSelectBestServerCheckIntervalMaxMinutes.toDouble(),
                  divisions:
                      autoSelectBestServerCheckIntervalMaxMinutes -
                      autoSelectBestServerCheckIntervalMinMinutes,
                  label: _formatBestServerCheckIntervalLabel(draftMinutes),
                  onChanged: dashboardState.busy
                      ? null
                      : (value) {
                          _updateAutoSelectIntervalDraft(value.round());
                          _scheduleAutoSelectIntervalSave();
                        },
                  onChangeEnd: dashboardState.busy
                      ? null
                      : (value) {
                          _updateAutoSelectIntervalDraft(value.round());
                          _scheduleAutoSelectIntervalSave(
                            debounce: Duration.zero,
                          );
                        },
                ),
                Row(
                  children: [
                    Text(
                      '$autoSelectBestServerCheckIntervalMinMinutes мин',
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                    const Spacer(),
                    Text(
                      _formatBestServerCheckIntervalLabel(
                        autoSelectBestServerCheckIntervalMaxMinutes,
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Минимум 15 минут, максимум 3 часа. Значение по умолчанию: 40 минут. Сохраняется автоматически.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: muted,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Этот параметр не входит в transport overrides. После отпускания ползунка новое значение сохраняется и начинает работать сразу.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: muted,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSplitTunnelSection(
    DashboardState dashboardState,
    bool isConnected,
  ) {
    return SplitTunnelSection(
      settings: _draft.splitTunnel,
      busy: dashboardState.busy,
      isConnected: isConnected,
      onChanged: (nextSplitTunnel) {
        _updateDraft(
          _draft.copyWith(splitTunnel: nextSplitTunnel),
          debounce: const Duration(milliseconds: 260),
        );
      },
      onRefreshRequested: (sourceKind) =>
          _refreshSplitTunnelSources(dashboardState, sourceKind),
    );
  }

  Widget _buildDesktopSection(DesktopSettingsState desktopSettingsState) {
    final controller = ref.read(desktopSettingsControllerProvider.notifier);
    final settings = desktopSettingsState.settings;
    final busy = desktopSettingsState.busy;
    final theme = Theme.of(context);
    final muted = theme.gorionTokens.onSurfaceMuted;

    return _SettingsSection(
      title: 'Запуск и трей',
      description:
          'Настройки применяются сразу. Автозапуск меняет Windows startup entry, а скрытый старт и автоподключение начнут работать на следующем запуске приложения.',
      child: Column(
        children: [
          _ToggleTile(
            title: 'Автозапуск с Windows',
            subtitle:
                'Добавляет gorion в автозагрузку текущего пользователя Windows, чтобы приложение можно было поднимать сразу после входа в систему.',
            value: desktopSettingsState.launchAtStartupEnabled,
            onChanged: busy
                ? null
                : (value) {
                    unawaited(controller.setLaunchAtStartupEnabled(value));
                  },
          ),
          const SizedBox(height: 14),
          _ToggleTile(
            title: 'Запускать скрыто в трей',
            subtitle:
                'При следующем запуске окно не откроется поверх рабочего стола: приложение сразу уйдёт в системный трей и продолжит работать в фоне.',
            value: settings.launchMinimized,
            onChanged: busy
                ? null
                : (value) {
                    unawaited(controller.setLaunchMinimized(value));
                  },
          ),
          const SizedBox(height: 14),
          _ToggleTile(
            title: 'Автоподключение при запуске',
            subtitle:
                'После загрузки сохранённого состояния gorion автоматически запустит connect для активного профиля, если он уже выбран.',
            value: settings.autoConnectOnLaunch,
            onChanged: busy
                ? null
                : (value) {
                    unawaited(controller.setAutoConnectOnLaunch(value));
                  },
          ),
          if (desktopSettingsState.errorMessage case final errorMessage?) ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0x22EF4444),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0x55EF4444)),
              ),
              child: Text(
                errorMessage,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFFFFB4B4),
                  height: 1.45,
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Text(
            'Закрытие окна на Windows не завершает приложение: gorion остаётся в трее, а полный выход доступен через меню иконки.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: muted,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }

  _SettingsGroupSnapshot _buildGroupSnapshot(
    _SettingsGroup group,
    DashboardState dashboardState,
    AppThemeSettings appThemeSettings,
    DesktopSettingsState desktopSettingsState,
    int bestServerCheckIntervalMinutes,
  ) {
    final savedSettings = dashboardState.connectionTuningSettings;

    switch (group) {
      case _SettingsGroup.appearance:
        return _SettingsGroupSnapshot(
          badgeLabel: appThemeSettings.palette.title,
          supportingLabel:
              '${appThemeSettings.mode.title} · ${appThemeSettings.palette.description}',
          hasPendingChanges: false,
        );
      case _SettingsGroup.tls:
        final activeCount = _countTlsOverrides(_draft);
        return _SettingsGroupSnapshot(
          badgeLabel: activeCount == 0
              ? 'Без override'
              : 'Активно: $activeCount',
          supportingLabel: _draft.normalizedSniDonor.isNotEmpty
              ? 'SNI donor задан'
              : activeCount > 0
              ? 'Переопределения наложатся поверх профиля'
              : 'TLS берётся из подписки без изменений',
          hasPendingChanges: _hasTlsChanges(savedSettings),
        );
      case _SettingsGroup.vless:
        final activeLabels = <String>[
          if (_draft.forceVisionFlow) 'Vision',
          if (_draft.forceXudpPacketEncoding) 'xudp',
          if (_draft.enableMultiplex) 'mux',
        ];
        return _SettingsGroupSnapshot(
          badgeLabel: activeLabels.isEmpty
              ? 'Без override'
              : 'Активно: ${activeLabels.length}',
          supportingLabel: activeLabels.isEmpty
              ? 'Transport берётся из подписки'
              : activeLabels.join(' · '),
          hasPendingChanges: _hasVlessChanges(savedSettings),
        );
      case _SettingsGroup.autoSelect:
        return _SettingsGroupSnapshot(
          badgeLabel: _formatBestServerCheckIntervalBadge(
            bestServerCheckIntervalMinutes,
          ),
          supportingLabel:
              bestServerCheckIntervalMinutes ==
                  dashboardState
                      .autoSelectSettings
                      .bestServerCheckIntervalMinutes
              ? 'Применяется без переподключения'
              : 'Новое значение отправляется автоматически',
          hasPendingChanges:
              bestServerCheckIntervalMinutes !=
              dashboardState.autoSelectSettings.bestServerCheckIntervalMinutes,
        );
      case _SettingsGroup.splitTunnel:
        final splitTunnel = _draft.splitTunnel;
        final ruleCount = _countSplitTunnelRules(splitTunnel);
        final directCount = splitTunnel.direct.ruleCount;
        final blockCount = splitTunnel.block.ruleCount;
        final proxyCount = splitTunnel.proxy.ruleCount;
        return _SettingsGroupSnapshot(
          badgeLabel: ruleCount == 0 ? 'Правил нет' : 'Правил: $ruleCount',
          supportingLabel: !splitTunnel.hasRules
              ? 'Правила маршрутизации не заданы'
              : splitTunnel.enabled
              ? 'D $directCount · B $blockCount · P $proxyCount'
              : 'Правила сохранены, но выключены',
          hasPendingChanges: splitTunnel != savedSettings.splitTunnel,
        );
      case _SettingsGroup.desktop:
        final desktopSettings = desktopSettingsState.settings;
        final activeFlags = <String>[
          if (desktopSettingsState.launchAtStartupEnabled) 'Автостарт',
          if (desktopSettings.launchMinimized) 'Трей',
          if (desktopSettings.autoConnectOnLaunch) 'Автоподключение',
        ];
        return _SettingsGroupSnapshot(
          badgeLabel: desktopSettingsState.launchAtStartupEnabled
              ? 'Windows startup'
              : 'Ручной старт',
          supportingLabel: activeFlags.isEmpty
              ? 'Обычный запуск без фоновой автоматизации'
              : activeFlags.join(' · '),
          hasPendingChanges: false,
        );
    }
  }

  int _countTlsOverrides(ConnectionTuningSettings settings) {
    var count = 0;
    if (settings.forceChromeUtls) {
      count += 1;
    }
    if (settings.normalizedSniDonor.isNotEmpty) {
      count += 1;
    }
    if (settings.enableTlsRecordFragment) {
      count += 1;
    }
    return count;
  }

  int _countSplitTunnelRules(SplitTunnelSettings splitTunnelSettings) {
    return splitTunnelSettings.ruleCount;
  }

  bool _hasTlsChanges(ConnectionTuningSettings settings) {
    return _draft.forceChromeUtls != settings.forceChromeUtls ||
        _draft.normalizedSniDonor != settings.normalizedSniDonor ||
        _draft.enableTlsRecordFragment != settings.enableTlsRecordFragment;
  }

  bool _hasVlessChanges(ConnectionTuningSettings settings) {
    return _draft.forceVisionFlow != settings.forceVisionFlow ||
        _draft.forceXudpPacketEncoding != settings.forceXudpPacketEncoding ||
        _draft.enableMultiplex != settings.enableMultiplex;
  }

  void _openGroup(_SettingsGroup group) {
    setState(() {
      _selectedGroup = group;
    });
    _scrollToTop();
  }

  void _closeGroup() {
    setState(() {
      _selectedGroup = null;
    });
    _scrollToTop();
  }

  void _scrollToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) {
        return;
      }

      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _updateDraft(
    ConnectionTuningSettings next, {
    Duration debounce = const Duration(milliseconds: 360),
  }) {
    final normalized = next.copyWith();
    setState(() {
      _draft = normalized;
      if (_failedConnectionSettings != normalized) {
        _failedConnectionSettings = null;
      }
    });
    _scheduleConnectionAutoSave(debounce: debounce);
  }

  void _updateAutoSelectIntervalDraft(int minutes) {
    final clamped = clampAutoSelectBestServerCheckIntervalMinutes(minutes);
    setState(() {
      _autoSelectIntervalDraftMinutes = clamped;
      if (_failedAutoSelectIntervalMinutes != clamped) {
        _failedAutoSelectIntervalMinutes = null;
      }
    });
  }

  void _scheduleConnectionAutoSave({
    Duration debounce = const Duration(milliseconds: 360),
  }) {
    _connectionAutoSaveTimer?.cancel();
    _connectionAutoSaveTimer = Timer(debounce, () {
      unawaited(_tryAutoSaveConnectionSettings(ignoreDebounce: true));
    });
  }

  void _scheduleAutoSelectIntervalSave({
    Duration debounce = const Duration(milliseconds: 180),
  }) {
    _autoSelectAutoSaveTimer?.cancel();
    _autoSelectAutoSaveTimer = Timer(debounce, () {
      unawaited(_tryAutoSaveAutoSelectInterval(ignoreDebounce: true));
    });
  }

  void _scheduleAutoSaveFlush() {
    if (_autoSaveFlushScheduled) {
      return;
    }
    _autoSaveFlushScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoSaveFlushScheduled = false;
      if (!mounted) {
        return;
      }
      unawaited(_tryAutoSaveConnectionSettings());
      unawaited(_tryAutoSaveAutoSelectInterval());
    });
  }

  Future<bool> _tryAutoSaveConnectionSettings({
    bool ignoreDebounce = false,
  }) async {
    if (!mounted) {
      return false;
    }
    if (!ignoreDebounce && (_connectionAutoSaveTimer?.isActive ?? false)) {
      return false;
    }

    final state = ref.read(dashboardControllerProvider);
    final target = _draft.copyWith();
    if (state.busy ||
        state.connectionTuningSettings == target ||
        _failedConnectionSettings == target) {
      return state.connectionTuningSettings == target;
    }

    return _saveConnectionSettings(target, reconnectAfterSave: true);
  }

  Future<bool> _tryAutoSaveAutoSelectInterval({
    bool ignoreDebounce = false,
  }) async {
    if (!mounted) {
      return false;
    }
    if (!ignoreDebounce && (_autoSelectAutoSaveTimer?.isActive ?? false)) {
      return false;
    }

    final state = ref.read(dashboardControllerProvider);
    final target =
        _autoSelectIntervalDraftMinutes ??
        state.autoSelectSettings.bestServerCheckIntervalMinutes;
    if (state.busy ||
        state.autoSelectSettings.bestServerCheckIntervalMinutes == target ||
        _failedAutoSelectIntervalMinutes == target) {
      return state.autoSelectSettings.bestServerCheckIntervalMinutes == target;
    }

    return _saveAutoSelectInterval(target);
  }

  Future<bool> _saveConnectionSettings(
    ConnectionTuningSettings settings, {
    required bool reconnectAfterSave,
  }) async {
    final normalized = settings.copyWith();
    final state = ref.read(dashboardControllerProvider);
    if (state.busy) {
      return false;
    }
    if (state.connectionTuningSettings == normalized) {
      if (_failedConnectionSettings == normalized) {
        setState(() {
          _failedConnectionSettings = null;
        });
      }
      return true;
    }

    final controller = ref.read(dashboardControllerProvider.notifier);
    await controller.saveConnectionTuningSettings(normalized);
    if (!mounted) {
      return false;
    }

    final updatedState = ref.read(dashboardControllerProvider);
    final saved =
        updatedState.errorMessage == null &&
        updatedState.connectionTuningSettings == normalized;
    if (!saved) {
      setState(() {
        _failedConnectionSettings = normalized;
      });
      return false;
    }

    if (_failedConnectionSettings == normalized) {
      setState(() {
        _failedConnectionSettings = null;
      });
    }

    if (reconnectAfterSave &&
        updatedState.connectionStage == ConnectionStage.connected &&
        _draft == normalized) {
      await controller.reconnect();
    }
    return true;
  }

  Future<bool> _saveAutoSelectInterval(int minutes) async {
    final clamped = clampAutoSelectBestServerCheckIntervalMinutes(minutes);
    final state = ref.read(dashboardControllerProvider);
    if (state.busy) {
      return false;
    }
    if (state.autoSelectSettings.bestServerCheckIntervalMinutes == clamped) {
      if (_failedAutoSelectIntervalMinutes == clamped) {
        setState(() {
          _failedAutoSelectIntervalMinutes = null;
        });
      }
      return true;
    }

    await ref
        .read(dashboardControllerProvider.notifier)
        .setAutoSelectBestServerCheckIntervalMinutes(clamped);
    if (!mounted) {
      return false;
    }

    final updatedState = ref.read(dashboardControllerProvider);
    final saved =
        updatedState.errorMessage == null &&
        updatedState.autoSelectSettings.bestServerCheckIntervalMinutes ==
            clamped;
    if (!saved) {
      setState(() {
        _failedAutoSelectIntervalMinutes = clamped;
      });
      return false;
    }

    if (_failedAutoSelectIntervalMinutes == clamped) {
      setState(() {
        _failedAutoSelectIntervalMinutes = null;
      });
    }
    return true;
  }

  Future<void> _savePendingChanges() async {
    FocusScope.of(context).unfocus();
    _connectionAutoSaveTimer?.cancel();
    _autoSelectAutoSaveTimer?.cancel();

    final autoSelectSaved = await _tryAutoSaveAutoSelectInterval(
      ignoreDebounce: true,
    );
    if (!mounted || !autoSelectSaved) {
      return;
    }

    await _tryAutoSaveConnectionSettings(ignoreDebounce: true);
  }

  Future<void> _refreshSplitTunnelSources(
    DashboardState state,
    SplitTunnelManagedSourceKind sourceKind,
  ) async {
    FocusScope.of(context).unfocus();

    _connectionAutoSaveTimer?.cancel();
    var effectiveState = state;
    final requestedSettings = _draft.copyWith();
    if (requestedSettings != state.connectionTuningSettings) {
      final saved = await _saveConnectionSettings(
        requestedSettings,
        reconnectAfterSave: false,
      );
      effectiveState = ref.read(dashboardControllerProvider);
      if (!mounted ||
          !saved ||
          effectiveState.errorMessage != null ||
          effectiveState.connectionTuningSettings != requestedSettings) {
        return;
      }
    }

    final controller = ref.read(dashboardControllerProvider.notifier);
    final previousRevision = effectiveState.connectionTuningSettings.splitTunnel
        .revisionForManagedSource(sourceKind);
    await controller.refreshSplitTunnelSources(sourceKind);
    final refreshedState = ref.read(dashboardControllerProvider);
    if (!mounted || refreshedState.errorMessage != null) {
      return;
    }

    final revisionChanged =
        refreshedState.connectionTuningSettings.splitTunnel
            .revisionForManagedSource(sourceKind) !=
        previousRevision;
    if (!revisionChanged ||
        refreshedState.connectionStage != ConnectionStage.connected) {
      return;
    }

    await controller.reconnect();
  }

  void _syncDraft(ConnectionTuningSettings settings) {
    if (_syncedSettings == settings) {
      if (_draft == settings) {
        _failedConnectionSettings = null;
      }
      return;
    }

    final previousSyncedSettings = _syncedSettings;
    _syncedSettings = settings;
    final shouldAdoptSavedSettings =
        previousSyncedSettings == null || _draft == previousSyncedSettings;
    if (shouldAdoptSavedSettings) {
      _draft = settings;
    }
    if (_draft == settings) {
      _failedConnectionSettings = null;
    }

    final effectiveSniDonor = _draft.normalizedSniDonor;
    if (_sniController.text != effectiveSniDonor) {
      _sniController.value = TextEditingValue(
        text: effectiveSniDonor,
        selection: TextSelection.collapsed(offset: effectiveSniDonor.length),
      );
    }
  }

  void _syncAutoSelectInterval(int minutes) {
    if (_syncedAutoSelectIntervalMinutes == minutes) {
      if (_autoSelectIntervalDraftMinutes == minutes) {
        _failedAutoSelectIntervalMinutes = null;
      }
      return;
    }

    final previousSyncedMinutes = _syncedAutoSelectIntervalMinutes;
    _syncedAutoSelectIntervalMinutes = minutes;
    final shouldAdoptSavedInterval =
        previousSyncedMinutes == null ||
        _autoSelectIntervalDraftMinutes == null ||
        _autoSelectIntervalDraftMinutes == previousSyncedMinutes;
    if (shouldAdoptSavedInterval) {
      _autoSelectIntervalDraftMinutes = minutes;
    }
    if (_autoSelectIntervalDraftMinutes == minutes) {
      _failedAutoSelectIntervalMinutes = null;
    }
  }
}

String _formatBestServerCheckIntervalLabel(int minutes) {
  final hours = minutes ~/ 60;
  final remainingMinutes = minutes % 60;
  final parts = <String>[];
  if (hours > 0) {
    parts.add('$hours ч');
  }
  if (remainingMinutes > 0 || parts.isEmpty) {
    parts.add('$remainingMinutes мин');
  }
  return parts.join(' ');
}

String _formatBestServerCheckIntervalBadge(int minutes) {
  final hours = minutes ~/ 60;
  final remainingMinutes = minutes % 60;
  if (hours <= 0) {
    return '$minutes мин';
  }
  if (remainingMinutes == 0) {
    return '$hours ч';
  }
  return '$hours ч $remainingMinutes мин';
}

class _HeroPanel extends StatelessWidget {
  const _HeroPanel({
    required this.busy,
    required this.activeGroup,
    required this.hasPendingChanges,
    required this.hasFailedSaves,
    required this.canManualSave,
    required this.isConnected,
    required this.onSave,
    this.onBack,
  });

  final bool busy;
  final _SettingsGroup? activeGroup;
  final bool hasPendingChanges;
  final bool hasFailedSaves;
  final bool canManualSave;
  final bool isConnected;
  final VoidCallback? onSave;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final saveLabel = busy
        ? 'Сохранение...'
        : canManualSave
        ? isConnected
              ? 'Сохранить и применить'
              : 'Сохранить'
        : hasPendingChanges
        ? 'Применяется...'
        : 'Сохранено';
    final saveIcon = busy
        ? Icons.sync_rounded
        : canManualSave
        ? isConnected
              ? Icons.sync_rounded
              : Icons.save_outlined
        : hasPendingChanges
        ? Icons.schedule_rounded
        : Icons.check_rounded;
    final heroMetaChildren = <Widget>[
      if (onBack != null)
        OutlinedButton.icon(
          onPressed: onBack,
          icon: const Icon(Icons.arrow_back_rounded),
          label: const Text('Все группы'),
        ),
      if (activeGroup != null)
        _Badge(
          label: activeGroup!.title,
          backgroundColor: activeGroup!.accentColor.withValues(alpha: 0.14),
          foregroundColor: activeGroup!.accentColor,
        ),
      if (hasPendingChanges)
        _Badge(
          label: hasFailedSaves ? 'Не сохранено' : 'Применяется',
          backgroundColor: const Color(0x22FFC857),
          foregroundColor: const Color(0xFFFFC857),
        ),
    ];
    final hasHeroMeta = heroMetaChildren.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final titleBlock = Text(
              'Настройки',
              style: theme.textTheme.displaySmall?.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w700,
                height: 1.0,
                letterSpacing: -0.6,
              ),
            );
            final saveButton = FilledButton.icon(
              onPressed: onSave,
              icon: Icon(saveIcon),
              label: Text(saveLabel),
            );

            if (constraints.maxWidth < 760) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  titleBlock,
                  if (hasHeroMeta) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: heroMetaChildren,
                    ),
                  ],
                  const SizedBox(height: 10),
                  saveButton,
                ],
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: titleBlock),
                    const SizedBox(width: 16),
                    saveButton,
                  ],
                ),
                if (hasHeroMeta) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: heroMetaChildren,
                  ),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}

class _SettingsGroupCard extends StatelessWidget {
  const _SettingsGroupCard({
    required this.group,
    required this.snapshot,
    required this.onTap,
  });

  final _SettingsGroup group;
  final _SettingsGroupSnapshot snapshot;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;

    return GlassPanel(
      borderRadius: 26,
      padding: EdgeInsets.zero,
      opacity: 0.06,
      backgroundColor: Colors.white,
      strokeColor: group.accentColor,
      strokeOpacity: 0.07,
      strokeWidth: 1,
      showGlow: false,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(26),
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.max,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: group.accentColor.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(group.icon, color: group.accentColor),
                    ),
                    const Spacer(),
                    if (snapshot.hasPendingChanges)
                      const _Badge(
                        label: 'Не сохранено',
                        backgroundColor: Color(0x22FFC857),
                        foregroundColor: Color(0xFFFFC857),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  group.title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  group.description,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: muted,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 16),
                _Badge(
                  label: snapshot.badgeLabel,
                  backgroundColor: group.accentColor.withValues(alpha: 0.14),
                  foregroundColor: group.accentColor,
                ),
                const SizedBox(height: 10),
                Text(
                  snapshot.supportingLabel,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurface,
                    height: 1.45,
                  ),
                ),
                const Spacer(),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Text(
                      'Открыть группу',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: group.accentColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    Icon(Icons.arrow_forward_rounded, color: group.accentColor),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.title,
    required this.description,
    required this.child,
  });

  final String title;
  final String description;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;

    return GlassPanel(
      borderRadius: 26,
      padding: const EdgeInsets.all(22),
      opacity: 0.06,
      backgroundColor: Colors.white,
      strokeColor: Colors.white,
      strokeOpacity: 0.04,
      strokeWidth: 1,
      showGlow: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleLarge?.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: muted,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }
}

class _ToggleTile extends StatelessWidget {
  const _ToggleTile({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: value ? 0.08 : 0.04),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: value
              ? scheme.primary.withValues(alpha: 0.24)
              : scheme.onSurface.withValues(alpha: 0.08),
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
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: muted,
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

class _ThemeChoiceCard extends StatelessWidget {
  const _ThemeChoiceCard({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.accentColor,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final Color accentColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.onSurface.withValues(alpha: selected ? 0.08 : 0.04),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? accentColor.withValues(alpha: 0.34)
                  : scheme.onSurface.withValues(alpha: 0.08),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 18,
                    color: selected ? accentColor : muted,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: muted,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThemePaletteCard extends StatelessWidget {
  const _ThemePaletteCard({
    required this.title,
    required this.subtitle,
    required this.previewColor,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final Color previewColor;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.onSurface.withValues(alpha: selected ? 0.08 : 0.04),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? previewColor.withValues(alpha: 0.38)
                  : scheme.onSurface.withValues(alpha: 0.08),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: previewColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 18,
                    color: selected ? previewColor : muted,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 10,
                      decoration: BoxDecoration(
                        color: previewColor.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    width: 32,
                    height: 10,
                    decoration: BoxDecoration(
                      color: previewColor.withValues(alpha: 0.48),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: muted,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.label,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  final String label;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: foregroundColor,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}
