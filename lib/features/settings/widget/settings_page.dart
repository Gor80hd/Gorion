import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/app/theme.dart';
import 'package:gorion_clean/features/auto_select/model/auto_select_state.dart';
import 'package:gorion_clean/core/widget/glass_panel.dart';
import 'package:gorion_clean/core/widget/page_reveal.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';
import 'package:gorion_clean/features/settings/model/connection_tuning_settings.dart';
import 'package:gorion_clean/features/settings/widget/split_tunnel_section.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final TextEditingController _sniController;
  ConnectionTuningSettings _draft = const ConnectionTuningSettings();
  ConnectionTuningSettings? _syncedSettings;

  @override
  void initState() {
    super.initState();
    _sniController = TextEditingController();
  }

  @override
  void dispose() {
    _sniController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dashboardState = ref.watch(dashboardControllerProvider);
    _syncDraft(dashboardState.connectionTuningSettings);

    final theme = Theme.of(context);
    final bestServerCheckIntervalMinutes =
        dashboardState.autoSelectSettings.bestServerCheckIntervalMinutes;
    final hasChanges = _draft != dashboardState.connectionTuningSettings;
    final isConnected =
        dashboardState.connectionStage == ConnectionStage.connected;
    final canSave = !dashboardState.busy && hasChanges;

    return PageReveal(
      duration: const Duration(milliseconds: 240),
      offset: const Offset(0.02, 0.02),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 1080;
          final cardWidth = isWide
              ? (constraints.maxWidth - 18) / 2
              : constraints.maxWidth;

          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(0, 24, 0, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _HeroPanel(
                  stage: dashboardState.connectionStage,
                  busy: dashboardState.busy,
                  hasOverrides:
                      dashboardState.connectionTuningSettings.hasOverrides,
                  statusMessage: dashboardState.statusMessage,
                  errorMessage: dashboardState.errorMessage,
                ),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 18,
                  runSpacing: 18,
                  children: [
                    SizedBox(
                      width: cardWidth,
                      child: _SettingsSection(
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
                                setState(() {
                                  _draft = _draft.copyWith(
                                    forceChromeUtls: value,
                                  );
                                });
                              },
                            ),
                            const SizedBox(height: 14),
                            TextField(
                              controller: _sniController,
                              onChanged: (value) {
                                setState(() {
                                  _draft = _draft.copyWith(sniDonor: value);
                                });
                              },
                              decoration: InputDecoration(
                                labelText: 'SNI-донор',
                                hintText: 'cdn.example.com',
                                helperText:
                                    'Если задан, подставляется в tls.server_name.',
                                suffixIcon: _draft.normalizedSniDonor.isEmpty
                                    ? null
                                    : IconButton(
                                        tooltip: 'Очистить',
                                        onPressed: () {
                                          _sniController.clear();
                                          setState(() {
                                            _draft = _draft.copyWith(
                                              sniDonor: '',
                                            );
                                          });
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
                                setState(() {
                                  _draft = _draft.copyWith(
                                    enableTlsRecordFragment: value,
                                  );
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(
                      width: cardWidth,
                      child: _SettingsSection(
                        title: 'VLESS transport',
                        description:
                            'Эти override накладываются только на VLESS outbound. Нужны в основном для Reality и Xray-совместимых серверов.',
                        child: Column(
                          children: [
                            _ToggleTile(
                              title: 'flow = xtls-rprx-vision',
                              subtitle:
                                  'Форсирует Vision flow на VLESS outbound.',
                              value: _draft.forceVisionFlow,
                              onChanged: (value) {
                                setState(() {
                                  _draft = _draft.copyWith(
                                    forceVisionFlow: value,
                                  );
                                });
                              },
                            ),
                            const SizedBox(height: 14),
                            _ToggleTile(
                              title: 'packet_encoding = xudp',
                              subtitle:
                                  'Форсирует xudp для UDP packet encoding на VLESS outbound.',
                              value: _draft.forceXudpPacketEncoding,
                              onChanged: (value) {
                                setState(() {
                                  _draft = _draft.copyWith(
                                    forceXudpPacketEncoding: value,
                                  );
                                });
                              },
                            ),
                            const SizedBox(height: 14),
                            _ToggleTile(
                              title: 'Multiplex (mux)',
                              subtitle:
                                  'Включает multiplex.enabled на VLESS outbound и оставляет существующие mux-поля нетронутыми.',
                              value: _draft.enableMultiplex,
                              onChanged: (value) {
                                setState(() {
                                  _draft = _draft.copyWith(
                                    enableMultiplex: value,
                                  );
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(
                      width: cardWidth,
                      child: _SettingsSection(
                        title: 'Автовыбор сервера',
                        description:
                            'Частота фоновой проверки best server сохраняется отдельно от transport overrides и начинает действовать сразу, без переподключения.',
                        child: _AutoSelectBestServerCheckIntervalTile(
                          minutes: bestServerCheckIntervalMinutes,
                          busy: dashboardState.busy,
                          onConfigure: () =>
                              _showAutoSelectBestServerCheckIntervalDialog(
                                dashboardState,
                              ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                SplitTunnelSection(
                  settings: _draft.splitTunnel,
                  busy: dashboardState.busy,
                  isConnected: isConnected,
                  onChanged: (nextSplitTunnel) {
                    setState(() {
                      _draft = _draft.copyWith(splitTunnel: nextSplitTunnel);
                    });
                  },
                  onRefreshRequested: () =>
                      _refreshSplitTunnelSources(dashboardState),
                ),
                const SizedBox(height: 18),
                GlassPanel(
                  borderRadius: 24,
                  padding: const EdgeInsets.all(22),
                  opacity: 0.06,
                  backgroundColor: Colors.white,
                  strokeColor: Colors.white,
                  strokeOpacity: 0.1,
                  strokeWidth: 1,
                  showGlow: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Как это работает',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: gorionOnSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        isConnected
                            ? 'Изменения сохраняются сразу, а затем приложение переподключит текущую сессию, чтобы transport overrides и split tunneling действительно попали в sing-box runtime. Частота проверки best server сохраняется отдельно и применяется без переподключения.'
                            : 'Изменения сохраняются сразу и применяются на следующий connect. Уже пришедшие из подписки параметры и route rules не стираются, пока вы явно не добавляете новый override или split tunneling правило. Частота проверки best server сохраняется отдельно и применяется без переподключения.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: gorionOnSurfaceMuted,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          OutlinedButton.icon(
                            onPressed: dashboardState.busy || !hasChanges
                                ? null
                                : () {
                                    _restoreDraft(
                                      dashboardState.connectionTuningSettings,
                                    );
                                  },
                            icon: const Icon(Icons.undo_rounded),
                            label: const Text('Сбросить изменения'),
                          ),
                          const SizedBox(width: 12),
                          ElevatedButton.icon(
                            onPressed: canSave
                                ? () => _saveSettings(
                                    dashboardState,
                                    reconnectAfterSave: isConnected,
                                  )
                                : null,
                            icon: Icon(
                              isConnected
                                  ? Icons.sync_rounded
                                  : Icons.save_outlined,
                            ),
                            label: Text(
                              isConnected
                                  ? 'Сохранить и переподключить'
                                  : 'Сохранить',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _showAutoSelectBestServerCheckIntervalDialog(
    DashboardState state,
  ) async {
    FocusScope.of(context).unfocus();

    final currentMinutes =
        state.autoSelectSettings.bestServerCheckIntervalMinutes;
    final selectedMinutes = await showDialog<int>(
      context: context,
      builder: (dialogContext) {
        var draftMinutes = currentMinutes.toDouble();
        return StatefulBuilder(
          builder: (context, setState) {
            final effectiveMinutes = draftMinutes.round();
            return AlertDialog(
              title: const Text('Частота проверки best server'),
              content: SizedBox(
                width: 360,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Фоновая проверка лучшего сервера сейчас запускается каждые '
                      '${_formatBestServerCheckIntervalLabel(effectiveMinutes)}.',
                    ),
                    const SizedBox(height: 14),
                    Slider(
                      value: draftMinutes,
                      min: autoSelectBestServerCheckIntervalMinMinutes
                          .toDouble(),
                      max: autoSelectBestServerCheckIntervalMaxMinutes
                          .toDouble(),
                      divisions:
                          autoSelectBestServerCheckIntervalMaxMinutes -
                          autoSelectBestServerCheckIntervalMinMinutes,
                      label: _formatBestServerCheckIntervalLabel(
                        effectiveMinutes,
                      ),
                      onChanged: (value) {
                        setState(() {
                          draftMinutes = value;
                        });
                      },
                    ),
                    Row(
                      children: [
                        Text(
                          '${autoSelectBestServerCheckIntervalMinMinutes} мин',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const Spacer(),
                        Text(
                          _formatBestServerCheckIntervalLabel(
                            autoSelectBestServerCheckIntervalMaxMinutes,
                          ),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Минимум 15 минут, максимум 3 часа. По умолчанию 40 минут.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  onPressed: () =>
                      Navigator.of(dialogContext).pop(effectiveMinutes),
                  child: const Text('Сохранить'),
                ),
              ],
            );
          },
        );
      },
    );

    if (!mounted ||
        selectedMinutes == null ||
        selectedMinutes == currentMinutes) {
      return;
    }

    await ref
        .read(dashboardControllerProvider.notifier)
        .setAutoSelectBestServerCheckIntervalMinutes(selectedMinutes);
  }

  Future<void> _saveSettings(
    DashboardState state, {
    required bool reconnectAfterSave,
  }) async {
    FocusScope.of(context).unfocus();
    final requestedSettings = _draft.copyWith();
    final controller = ref.read(dashboardControllerProvider.notifier);
    await controller.saveConnectionTuningSettings(requestedSettings);
    final updatedState = ref.read(dashboardControllerProvider);
    if (!mounted ||
        !reconnectAfterSave ||
        updatedState.errorMessage != null ||
        updatedState.connectionTuningSettings != requestedSettings) {
      return;
    }
    await controller.reconnect();
  }

  Future<void> _refreshSplitTunnelSources(DashboardState state) async {
    FocusScope.of(context).unfocus();

    var effectiveState = state;
    final controller = ref.read(dashboardControllerProvider.notifier);
    final requestedSettings = _draft.copyWith();
    if (requestedSettings != state.connectionTuningSettings) {
      await controller.saveConnectionTuningSettings(requestedSettings);
      effectiveState = ref.read(dashboardControllerProvider);
      if (!mounted ||
          effectiveState.errorMessage != null ||
          effectiveState.connectionTuningSettings != requestedSettings) {
        return;
      }
    }

    final previousRevision =
        effectiveState.connectionTuningSettings.splitTunnel.remoteRevision;
    await controller.refreshSplitTunnelSources();
    final refreshedState = ref.read(dashboardControllerProvider);
    if (!mounted || refreshedState.errorMessage != null) {
      return;
    }

    final revisionChanged =
        refreshedState.connectionTuningSettings.splitTunnel.remoteRevision !=
        previousRevision;
    if (!revisionChanged ||
        refreshedState.connectionStage != ConnectionStage.connected) {
      return;
    }

    await controller.reconnect();
  }

  void _restoreDraft(ConnectionTuningSettings settings) {
    setState(() {
      _draft = settings;
      _sniController.value = TextEditingValue(
        text: settings.normalizedSniDonor,
        selection: TextSelection.collapsed(
          offset: settings.normalizedSniDonor.length,
        ),
      );
    });
  }

  void _syncDraft(ConnectionTuningSettings settings) {
    if (_syncedSettings == settings) {
      return;
    }
    _syncedSettings = settings;
    _draft = settings;
    _sniController.value = TextEditingValue(
      text: settings.normalizedSniDonor,
      selection: TextSelection.collapsed(
        offset: settings.normalizedSniDonor.length,
      ),
    );
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
    required this.stage,
    required this.busy,
    required this.hasOverrides,
    required this.statusMessage,
    required this.errorMessage,
  });

  final ConnectionStage stage;
  final bool busy;
  final bool hasOverrides;
  final String? statusMessage;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return GlassPanel(
      borderRadius: 30,
      padding: const EdgeInsets.fromLTRB(28, 26, 28, 24),
      opacity: 0.06,
      backgroundColor: Colors.white,
      strokeColor: gorionAccent,
      strokeOpacity: 0.16,
      strokeWidth: 1,
      showGlow: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _Badge(
                label: _stageLabel(stage),
                backgroundColor: _stageColor(stage).withValues(alpha: 0.14),
                foregroundColor: _stageColor(stage),
              ),
              _Badge(
                label: hasOverrides ? 'Overrides active' : 'No overrides',
                backgroundColor: hasOverrides
                    ? gorionAccent.withValues(alpha: 0.14)
                    : Colors.white.withValues(alpha: 0.06),
                foregroundColor: hasOverrides
                    ? gorionAccent
                    : gorionOnSurfaceMuted,
              ),
              if (busy)
                const _Badge(
                  label: 'Saving',
                  backgroundColor: Color(0x22FFFFFF),
                  foregroundColor: gorionOnSurface,
                ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            'Настройки подключения',
            style: theme.textTheme.headlineMedium?.copyWith(
              color: gorionOnSurface,
              fontWeight: FontWeight.w700,
              height: 1.05,
            ),
          ),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Text(
              'Здесь собраны transport overrides, TLS tweaks, split tunneling правила и параметры фоновой проверки best server. Overrides накладываются поверх активного профиля только там, где формат узла это поддерживает.',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: gorionOnSurfaceMuted,
                height: 1.5,
              ),
            ),
          ),
          if (statusMessage != null || errorMessage != null) ...[
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: errorMessage != null
                    ? const Color(0x22EF4444)
                    : gorionAccent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: errorMessage != null
                      ? const Color(0x55EF4444)
                      : gorionAccent.withValues(alpha: 0.2),
                ),
              ),
              child: Text(
                errorMessage ?? statusMessage!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: errorMessage != null
                      ? const Color(0xFFFFB4B4)
                      : gorionOnSurface,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static Color _stageColor(ConnectionStage stage) {
    switch (stage) {
      case ConnectionStage.disconnected:
        return gorionOnSurfaceMuted;
      case ConnectionStage.starting:
        return const Color(0xFFFFC857);
      case ConnectionStage.connected:
        return gorionAccent;
      case ConnectionStage.stopping:
        return const Color(0xFFFFA94D);
      case ConnectionStage.failed:
        return const Color(0xFFEF4444);
    }
  }

  static String _stageLabel(ConnectionStage stage) {
    switch (stage) {
      case ConnectionStage.disconnected:
        return 'Отключено';
      case ConnectionStage.starting:
        return 'Подключение';
      case ConnectionStage.connected:
        return 'Подключено';
      case ConnectionStage.stopping:
        return 'Отключение';
      case ConnectionStage.failed:
        return 'Ошибка';
    }
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
            title,
            style: theme.textTheme.titleLarge?.copyWith(
              color: gorionOnSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: gorionOnSurfaceMuted,
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

class _AutoSelectBestServerCheckIntervalTile extends StatelessWidget {
  const _AutoSelectBestServerCheckIntervalTile({
    required this.minutes,
    required this.busy,
    required this.onConfigure,
  });

  final int minutes;
  final bool busy;
  final VoidCallback onConfigure;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
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
                      'Частота проверки best server',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: gorionOnSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Maintenance-проверка текущего сервера и поиск замены будут идти с этим интервалом.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: gorionOnSurfaceMuted,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              _Badge(
                label: _formatBestServerCheckIntervalBadge(minutes),
                backgroundColor: const Color(
                  0xFF6DD3FF,
                ).withValues(alpha: 0.14),
                foregroundColor: const Color(0xFF6DD3FF),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Text(
                  'Диапазон: 15 минут - 3 часа. Значение по умолчанию: 40 минут.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: gorionOnSurfaceMuted,
                    height: 1.45,
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : onConfigure,
                icon: const Icon(Icons.schedule_rounded),
                label: const Text('Изменить'),
              ),
            ],
          ),
        ],
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
