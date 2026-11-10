import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/app/theme.dart';
import 'package:gorion_clean/app/theme_preferences.dart';
import 'package:gorion_clean/app/theme_settings.dart';
import 'package:gorion_clean/core/preferences/general_preferences.dart';
import 'package:gorion_clean/core/widget/glass_panel.dart';
import 'package:gorion_clean/core/widget/page_reveal.dart';
import 'package:gorion_clean/features/auto_select/model/auto_select_state.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/home/application/dashboard_state.dart';
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';
import 'package:gorion_clean/features/settings/application/desktop_settings_controller.dart';
import 'package:gorion_clean/features/settings/data/app_settings_reset_service.dart';
import 'package:gorion_clean/features/settings/model/connection_tuning_settings.dart';
import 'package:gorion_clean/features/settings/model/desktop_settings.dart';
import 'package:gorion_clean/features/settings/model/split_tunnel_settings.dart';
import 'package:gorion_clean/features/settings/widget/split_tunnel_section.dart';
import 'package:gorion_clean/features/update/application/app_update_controller.dart';
import 'package:gorion_clean/features/update/model/app_update_state.dart';

part 'settings_page_widgets.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key, this.animateOnMount = true});

  final bool animateOnMount;

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final TextEditingController _sniController;
  late final ScrollController _scrollController;
  ConnectionTuningSettings _draft = const ConnectionTuningSettings();
  ConnectionTuningSettings? _syncedSettings;
  int? _autoSelectIntervalDraftMinutes;
  int? _syncedAutoSelectIntervalMinutes;
  int? _liveServerPingIntervalDraftSeconds;
  int? _syncedLiveServerPingIntervalSeconds;
  ConnectionTuningSettings? _failedConnectionSettings;
  int? _failedAutoSelectIntervalMinutes;
  int? _failedLiveServerPingIntervalSeconds;
  Timer? _connectionAutoSaveTimer;
  Timer? _autoSelectAutoSaveTimer;
  Timer? _liveServerPingAutoSaveTimer;
  bool _autoSaveFlushScheduled = false;
  bool _resetInProgress = false;

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
    _liveServerPingAutoSaveTimer?.cancel();
    _sniController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dashboardState = ref.watch(dashboardControllerProvider);
    final appThemeSettings = ref.watch(appThemeSettingsProvider);
    final desktopSettingsState = ref.watch(desktopSettingsControllerProvider);
    final appUpdateState = ref.watch(appUpdateControllerProvider);
    _syncDraft(dashboardState.connectionTuningSettings);

    final savedBestServerCheckIntervalMinutes =
        dashboardState.autoSelectSettings.bestServerCheckIntervalMinutes;
    _syncAutoSelectInterval(savedBestServerCheckIntervalMinutes);
    final savedLiveServerPingIntervalSeconds =
        dashboardState.autoSelectSettings.liveServerPingIntervalSeconds;
    _syncLiveServerPingInterval(savedLiveServerPingIntervalSeconds);

    final bestServerCheckIntervalMinutes =
        _autoSelectIntervalDraftMinutes ?? savedBestServerCheckIntervalMinutes;
    final liveServerPingIntervalSeconds =
        _liveServerPingIntervalDraftSeconds ??
        savedLiveServerPingIntervalSeconds;
    final hasPendingConnectionChanges =
        _draft != dashboardState.connectionTuningSettings;
    final hasPendingAutoSelectChanges =
        bestServerCheckIntervalMinutes != savedBestServerCheckIntervalMinutes;
    final hasPendingLiveServerPingChanges =
        liveServerPingIntervalSeconds != savedLiveServerPingIntervalSeconds;
    final hasPendingChanges =
        hasPendingConnectionChanges ||
        hasPendingAutoSelectChanges ||
        hasPendingLiveServerPingChanges;
    final hasFailedConnectionSave =
        hasPendingConnectionChanges && _failedConnectionSettings == _draft;
    final hasFailedAutoSelectSave =
        hasPendingAutoSelectChanges &&
        _failedAutoSelectIntervalMinutes == bestServerCheckIntervalMinutes;
    final hasFailedLiveServerPingSave =
        hasPendingLiveServerPingChanges &&
        _failedLiveServerPingIntervalSeconds == liveServerPingIntervalSeconds;
    final hasFailedSaves =
        hasFailedConnectionSave ||
        hasFailedAutoSelectSave ||
        hasFailedLiveServerPingSave;
    final isConnected =
        dashboardState.connectionStage == ConnectionStage.connected;
    final pageBusy =
        dashboardState.busy || desktopSettingsState.busy || _resetInProgress;
    final canManualSave = !pageBusy && hasFailedSaves;

    if (!dashboardState.busy && !_resetInProgress) {
      _scheduleAutoSaveFlush();
    }

    final content = SingleChildScrollView(
      controller: _scrollController,
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SettingsHeader(
            busy: pageBusy,
            hasPendingChanges: hasPendingChanges,
            hasFailedSaves: hasFailedSaves,
            canManualSave: canManualSave,
            isConnected: isConnected,
            appUpdateState: appUpdateState,
            onSave: canManualSave ? _savePendingChanges : null,
            onCheckUpdates: _checkForUpdatesManually,
          ),
          const SizedBox(height: 18),
          _buildAppearanceSection(appThemeSettings),
          if (Platform.isWindows) ...[
            const SizedBox(height: 12),
            _buildDesktopSection(desktopSettingsState),
          ],
          const SizedBox(height: 12),
          _buildAutoSelectSection(
            dashboardState,
            bestServerCheckIntervalMinutes,
            liveServerPingIntervalSeconds,
          ),
          const SizedBox(height: 12),
          _buildSplitTunnelSection(dashboardState, isConnected),
          const SizedBox(height: 12),
          _buildTlsSection(),
          const SizedBox(height: 12),
          _buildVlessSection(),
          const SizedBox(height: 16),
          _buildResetSection(dashboardState: dashboardState, busy: pageBusy),
        ],
      ),
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

  Widget _buildAppearanceSection(AppThemeSettings appThemeSettings) {
    final themeNotifier = ref.read(appThemeSettingsProvider.notifier);

    return _SettingsSection(
      icon: Icons.contrast_rounded,
      title: 'Внешний вид',
      description:
          'Две выверенные темы — светлая и тёмная. Применяются сразу, без перезапуска.',
      child: _ThemeModeSelector(
        value: appThemeSettings.mode,
        onChanged: (mode) => unawaited(themeNotifier.setMode(mode)),
      ),
    );
  }

  Widget _buildResetSection({
    required DashboardState dashboardState,
    required bool busy,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;
    final runtimeActive =
        dashboardState.connectionStage == ConnectionStage.connected ||
        dashboardState.connectionStage == ConnectionStage.starting;
    final errorColor = scheme.error;

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 10),
      child: Align(
        alignment: Alignment.center,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              TextButton.icon(
                onPressed: busy ? null : _confirmResetAllSettings,
                style: TextButton.styleFrom(
                  foregroundColor: errorColor,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  textStyle: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                icon: Icon(
                  _resetInProgress
                      ? Icons.sync_rounded
                      : Icons.delete_forever_rounded,
                  size: 16,
                ),
                label: Text(
                  _resetInProgress
                      ? 'Сбрасываем настройки...'
                      : 'Стереть все настройки',
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Сбросит тему, connection overrides, split tunneling, автовыбор, Gorion Boost и параметры запуска. Профили и подписки останутся на месте.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: muted,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
              if (runtimeActive) ...[
                const SizedBox(height: 4),
                Text(
                  'При активном подключении изменения полностью применятся после переподключения или следующего запуска.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: errorColor.withValues(alpha: 0.9),
                    height: 1.4,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTlsSection() {
    return _SettingsSection(
      icon: Icons.shield_outlined,
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
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: TextField(
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
          ),
          const SizedBox(height: 10),
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
      icon: Icons.hub_outlined,
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
          const SizedBox(height: 10),
          _ToggleTile(
            title: 'packet_encoding = xudp',
            subtitle:
                'Форсирует xudp для UDP packet encoding на VLESS outbound.',
            value: _draft.forceXudpPacketEncoding,
            onChanged: (value) {
              _updateDraft(_draft.copyWith(forceXudpPacketEncoding: value));
            },
          ),
          const SizedBox(height: 10),
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
    int liveServerPingIntervalSeconds,
  ) {
    final theme = Theme.of(context);
    final muted = theme.gorionTokens.onSurfaceMuted;
    final draftMinutes =
        _autoSelectIntervalDraftMinutes ?? bestServerCheckIntervalMinutes;
    final draftLivePingSeconds =
        _liveServerPingIntervalDraftSeconds ?? liveServerPingIntervalSeconds;

    return _SettingsSection(
      icon: Icons.auto_awesome_outlined,
      title: 'Автовыбор сервера',
      description:
          'Фоновая проверка лучшего сервера. Изменения сохраняются автоматически и не требуют переподключения.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SliderTile(
            title: 'Частота проверки best server',
            subtitle:
                'Maintenance-проверка текущего сервера и поиск замены будут идти с этим интервалом.',
            valueLabel: _formatBestServerCheckIntervalBadge(draftMinutes),
            slider: Slider(
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
                      _scheduleAutoSelectIntervalSave(debounce: Duration.zero);
                    },
            ),
            rangeStart: '$autoSelectBestServerCheckIntervalMinMinutes мин',
            rangeEnd: _formatBestServerCheckIntervalLabel(
              autoSelectBestServerCheckIntervalMaxMinutes,
            ),
            footnote:
                'Минимум 15 минут, максимум 3 часа. Значение по умолчанию: 40 минут.',
          ),
          const SizedBox(height: 10),
          _ToggleTile(
            title: 'Live ping серверов',
            subtitle:
                'Обновляет задержку серверов через быстрый GET в активном proxy runtime. Работает только при подключении и не запускает тяжёлый speed benchmark.',
            value: dashboardState.autoSelectSettings.liveServerPingEnabled,
            onChanged: dashboardState.busy
                ? null
                : (value) {
                    unawaited(
                      ref
                          .read(dashboardControllerProvider.notifier)
                          .setLiveServerPingEnabled(value),
                    );
                  },
          ),
          const SizedBox(height: 10),
          _SliderTile(
            title: 'Интервал Live ping',
            subtitle:
                'Как часто обновлять задержку серверов через активный proxy runtime.',
            valueLabel: _formatLiveServerPingIntervalLabel(
              draftLivePingSeconds,
            ),
            slider: Slider(
              value: draftLivePingSeconds.toDouble(),
              min: liveServerPingIntervalMinSeconds.toDouble(),
              max: liveServerPingIntervalMaxSeconds.toDouble(),
              divisions:
                  liveServerPingIntervalMaxSeconds -
                  liveServerPingIntervalMinSeconds,
              label: _formatLiveServerPingIntervalLabel(draftLivePingSeconds),
              onChanged:
                  dashboardState.busy ||
                      !dashboardState.autoSelectSettings.liveServerPingEnabled
                  ? null
                  : (value) {
                      _updateLiveServerPingIntervalDraft(value.round());
                      _scheduleLiveServerPingIntervalSave();
                    },
              onChangeEnd:
                  dashboardState.busy ||
                      !dashboardState.autoSelectSettings.liveServerPingEnabled
                  ? null
                  : (value) {
                      _updateLiveServerPingIntervalDraft(value.round());
                      _scheduleLiveServerPingIntervalSave(
                        debounce: Duration.zero,
                      );
                    },
            ),
            rangeStart: '$liveServerPingIntervalMinSeconds сек',
            rangeEnd: _formatLiveServerPingIntervalLabel(
              liveServerPingIntervalMaxSeconds,
            ),
            footnote:
                'Минимум 15 секунд, максимум 15 минут. Чем меньше интервал, тем чаще идут сетевые GET-проверки.',
          ),
          const SizedBox(height: 10),
          _ToggleTile(
            title: 'Пинговать при запуске',
            subtitle:
                'После запуска приложения выполнит первый быстрый Live ping, когда появится активное подключение.',
            value: dashboardState
                .autoSelectSettings
                .liveServerPingOnStartupEnabled,
            onChanged: dashboardState.busy
                ? null
                : (value) {
                    unawaited(
                      ref
                          .read(dashboardControllerProvider.notifier)
                          .setLiveServerPingOnStartupEnabled(value),
                    );
                  },
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'После отпускания ползунка новое значение сохраняется и начинает работать сразу.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: muted,
                height: 1.45,
              ),
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
    final desktopController = ref.read(
      desktopSettingsControllerProvider.notifier,
    );
    final settings = desktopSettingsState.settings;
    final desktopBusy = desktopSettingsState.busy;
    final theme = Theme.of(context);
    final muted = theme.gorionTokens.onSurfaceMuted;

    return _SettingsSection(
      icon: Icons.desktop_windows_outlined,
      title: 'Запуск и трей',
      description:
          'Настройки применяются сразу. Обычный автостарт Gorion использует стандартную запись Windows Run, а режим повышенного приоритета переключает его на задачу AtLogOn в Планировщике Windows без задержки.',
      child: Column(
        children: [
          _ToggleTile(
            title: 'Gorion с Windows',
            subtitle:
                'Включает автозагрузку Gorion после входа в Windows. Точный механизм зависит от выбранного приоритета ниже.',
            value: desktopSettingsState.launchAtStartupEnabled,
            onChanged: desktopBusy
                ? null
                : (value) {
                    unawaited(
                      desktopController.setLaunchAtStartupEnabled(value),
                    );
                  },
          ),
          const SizedBox(height: 10),
          _ToggleTile(
            title: 'Запускать первым',
            subtitle:
                settings.launchAtStartupPriority ==
                    LaunchAtStartupPriority.first
                ? 'Gorion запускается через задачу AtLogOn без задержки, чтобы стартовать раньше стандартной группы автозагрузки Windows.'
                : 'Обычный режим использует стандартную запись Run. Windows не гарантирует порядок такого запуска среди других приложений.',
            value:
                settings.launchAtStartupPriority ==
                LaunchAtStartupPriority.first,
            onChanged: desktopBusy
                ? null
                : (value) {
                    unawaited(
                      desktopController.setLaunchAtStartupPriority(
                        value
                            ? LaunchAtStartupPriority.first
                            : LaunchAtStartupPriority.standard,
                      ),
                    );
                  },
          ),
          if (desktopSettingsState.canLaunchMinimized) ...[
            const SizedBox(height: 10),
            _ToggleTile(
              title: 'Запускать скрыто в трей',
              subtitle:
                  'При следующем запуске окно не откроется поверх рабочего стола: приложение сразу уйдёт в системный трей и продолжит работать в фоне.',
              value: desktopSettingsState.effectiveLaunchMinimized,
              onChanged: desktopBusy
                  ? null
                  : (value) {
                      unawaited(desktopController.setLaunchMinimized(value));
                    },
            ),
          ],
          const SizedBox(height: 10),
          _ToggleTile(
            title: 'Автоподключение при запуске',
            subtitle:
                'После загрузки сохранённого состояния gorion автоматически запустит connect для активного профиля, если он уже выбран.',
            value: settings.autoConnectOnLaunch,
            onChanged: desktopBusy
                ? null
                : (value) {
                    unawaited(desktopController.setAutoConnectOnLaunch(value));
                  },
          ),
          if (desktopSettingsState.errorMessage case final errorMessage?) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: theme.colorScheme.error.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: theme.colorScheme.error.withValues(alpha: 0.32),
                ),
              ),
              child: Text(
                errorMessage,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                  height: 1.45,
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'Закрытие окна на Windows не завершает приложение: gorion остаётся в трее, а полный выход доступен через меню иконки.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: muted,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
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

  void _updateLiveServerPingIntervalDraft(int seconds) {
    final clamped = clampLiveServerPingIntervalSeconds(seconds);
    setState(() {
      _liveServerPingIntervalDraftSeconds = clamped;
      if (_failedLiveServerPingIntervalSeconds != clamped) {
        _failedLiveServerPingIntervalSeconds = null;
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

  void _scheduleLiveServerPingIntervalSave({
    Duration debounce = const Duration(milliseconds: 180),
  }) {
    _liveServerPingAutoSaveTimer?.cancel();
    _liveServerPingAutoSaveTimer = Timer(debounce, () {
      unawaited(_tryAutoSaveLiveServerPingInterval(ignoreDebounce: true));
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
      unawaited(_tryAutoSaveLiveServerPingInterval());
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

  Future<bool> _tryAutoSaveLiveServerPingInterval({
    bool ignoreDebounce = false,
  }) async {
    if (!mounted) {
      return false;
    }
    if (!ignoreDebounce && (_liveServerPingAutoSaveTimer?.isActive ?? false)) {
      return false;
    }

    final state = ref.read(dashboardControllerProvider);
    final target =
        _liveServerPingIntervalDraftSeconds ??
        state.autoSelectSettings.liveServerPingIntervalSeconds;
    if (state.busy ||
        state.autoSelectSettings.liveServerPingIntervalSeconds == target ||
        _failedLiveServerPingIntervalSeconds == target) {
      return state.autoSelectSettings.liveServerPingIntervalSeconds == target;
    }

    return _saveLiveServerPingInterval(target);
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

  Future<bool> _saveLiveServerPingInterval(int seconds) async {
    final clamped = clampLiveServerPingIntervalSeconds(seconds);
    final state = ref.read(dashboardControllerProvider);
    if (state.busy) {
      return false;
    }
    if (state.autoSelectSettings.liveServerPingIntervalSeconds == clamped) {
      if (_failedLiveServerPingIntervalSeconds == clamped) {
        setState(() {
          _failedLiveServerPingIntervalSeconds = null;
        });
      }
      return true;
    }

    await ref
        .read(dashboardControllerProvider.notifier)
        .setLiveServerPingIntervalSeconds(clamped);
    if (!mounted) {
      return false;
    }

    final updatedState = ref.read(dashboardControllerProvider);
    final saved =
        updatedState.errorMessage == null &&
        updatedState.autoSelectSettings.liveServerPingIntervalSeconds ==
            clamped;
    if (!saved) {
      setState(() {
        _failedLiveServerPingIntervalSeconds = clamped;
      });
      return false;
    }

    if (_failedLiveServerPingIntervalSeconds == clamped) {
      setState(() {
        _failedLiveServerPingIntervalSeconds = null;
      });
    }
    return true;
  }

  Future<void> _savePendingChanges() async {
    FocusScope.of(context).unfocus();
    _connectionAutoSaveTimer?.cancel();
    _autoSelectAutoSaveTimer?.cancel();
    _liveServerPingAutoSaveTimer?.cancel();

    final autoSelectSaved = await _tryAutoSaveAutoSelectInterval(
      ignoreDebounce: true,
    );
    if (!mounted || !autoSelectSaved) {
      return;
    }

    final livePingSaved = await _tryAutoSaveLiveServerPingInterval(
      ignoreDebounce: true,
    );
    if (!mounted || !livePingSaved) {
      return;
    }

    await _tryAutoSaveConnectionSettings(ignoreDebounce: true);
  }

  Future<void> _checkForUpdatesManually() async {
    final controller = ref.read(appUpdateControllerProvider.notifier);
    await controller.checkForUpdates(force: true);
    if (!mounted) {
      return;
    }

    final updateState = ref.read(appUpdateControllerProvider);
    final message = switch (updateState.status) {
      AppUpdateStatus.updateAvailable =>
        'Найдена новая версия ${updateState.availableUpdate?.latestVersion ?? ''}.',
      AppUpdateStatus.upToDate =>
        'Установлена актуальная версия ${updateState.currentVersion ?? ''}.',
      AppUpdateStatus.failure => 'Не удалось проверить обновления.',
      _ => null,
    };
    if (message == null) {
      return;
    }

    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _confirmResetAllSettings() async {
    FocusScope.of(context).unfocus();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Стереть все настройки?'),
          content: const Text(
            'Это удалит все сохранённые настройки приложения и вернёт значения по умолчанию. Профили и подписки останутся на месте.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Стереть'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) {
      return;
    }

    await _resetAllSettings();
  }

  Future<void> _resetAllSettings() async {
    FocusScope.of(context).unfocus();
    _connectionAutoSaveTimer?.cancel();
    _autoSelectAutoSaveTimer?.cancel();

    setState(() {
      _resetInProgress = true;
      _failedConnectionSettings = null;
      _failedAutoSelectIntervalMinutes = null;
    });

    final messenger = ScaffoldMessenger.maybeOf(context);

    try {
      await ref.read(appSettingsResetServiceProvider).resetAll();
      ref.invalidate(appThemeSettingsProvider);
      ref.invalidate(Preferences.serverSortMode);
      await ref.read(dashboardControllerProvider.notifier).load();
      await ref.read(desktopSettingsControllerProvider.notifier).reload();
      if (!mounted) {
        return;
      }

      setState(() {
        _draft = const ConnectionTuningSettings();
        _syncedSettings = null;
        _autoSelectIntervalDraftMinutes = null;
        _syncedAutoSelectIntervalMinutes = null;
        _failedConnectionSettings = null;
        _failedAutoSelectIntervalMinutes = null;
        _resetInProgress = false;
      });

      messenger?.showSnackBar(
        const SnackBar(
          content: Text(
            'Все настройки сброшены. Профили и подписки сохранены.',
          ),
        ),
      );
    } on Object catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _resetInProgress = false;
      });

      messenger?.showSnackBar(
        SnackBar(content: Text('Не удалось стереть настройки: $error')),
      );
    }
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

  void _syncLiveServerPingInterval(int seconds) {
    if (_syncedLiveServerPingIntervalSeconds == seconds) {
      if (_liveServerPingIntervalDraftSeconds == seconds) {
        _failedLiveServerPingIntervalSeconds = null;
      }
      return;
    }

    final previousSyncedSeconds = _syncedLiveServerPingIntervalSeconds;
    _syncedLiveServerPingIntervalSeconds = seconds;
    final shouldAdoptSavedInterval =
        previousSyncedSeconds == null ||
        _liveServerPingIntervalDraftSeconds == null ||
        _liveServerPingIntervalDraftSeconds == previousSyncedSeconds;
    if (shouldAdoptSavedInterval) {
      _liveServerPingIntervalDraftSeconds = seconds;
    }
    if (_liveServerPingIntervalDraftSeconds == seconds) {
      _failedLiveServerPingIntervalSeconds = null;
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

String _formatLiveServerPingIntervalLabel(int seconds) {
  if (seconds < 60) {
    return '$seconds сек';
  }
  final minutes = seconds ~/ 60;
  final remainingSeconds = seconds % 60;
  if (remainingSeconds == 0) {
    return '$minutes мин';
  }
  return '$minutes мин $remainingSeconds сек';
}
