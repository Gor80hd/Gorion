import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/features/auto_select/model/auto_select_state.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/home/notifier/auto_server_selection_progress.dart';
import 'package:gorion_clean/features/profiles/model/profile_models.dart';
import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  late final TextEditingController _subscriptionController;

  @override
  void initState() {
    super.initState();
    _subscriptionController = TextEditingController();
  }

  @override
  void dispose() {
    _subscriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(dashboardControllerProvider);
    final notifier = ref.read(dashboardControllerProvider.notifier);
    final theme = Theme.of(context);

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFF5F1E9), Color(0xFFE6EFE6), Color(0xFFF9F7F2)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 1120;
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _HeroCard(state: state),
                    const SizedBox(height: 24),
                    if (state.errorMessage != null) ...[
                      _MessageCard(
                        color: const Color(0xFFF5D3D3),
                        icon: Icons.error_outline,
                        text: state.errorMessage!,
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (state.statusMessage != null) ...[
                      _MessageCard(
                        color: const Color(0xFFD7F0E6),
                        icon: Icons.info_outline,
                        text: state.statusMessage!,
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (state.autoSelectActivity.hasTrace) ...[
                      _AutoSelectProgressCard(
                        activity: state.autoSelectActivity,
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (state.bootstrapping)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 64),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (isWide)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 5,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _SubscriptionCard(
                                  controller: _subscriptionController,
                                  busy: state.busy,
                                  onAdd: () async {
                                    await notifier.addSubscription(
                                      _subscriptionController.text,
                                    );
                                    final latestState = ref.read(
                                      dashboardControllerProvider,
                                    );
                                    if (mounted &&
                                        latestState.errorMessage == null) {
                                      _subscriptionController.clear();
                                    }
                                  },
                                ),
                                const SizedBox(height: 20),
                                _ProfilesCard(
                                  state: state,
                                  onSelect: notifier.chooseProfile,
                                  onRefresh: notifier.refreshActiveProfile,
                                  onRemove: notifier.removeActiveProfile,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 24),
                          Expanded(
                            flex: 7,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _ConnectionCard(
                                  state: state,
                                  onModeChanged: notifier.setRuntimeMode,
                                  onConnect: notifier.connect,
                                  onReconnect: notifier.reconnect,
                                  onDisconnect: notifier.disconnect,
                                  onRefreshDelays: notifier.refreshDelays,
                                  onAutoSelect: notifier.runAutoSelect,
                                ),
                                const SizedBox(height: 20),
                                _AutoSelectSettingsCard(
                                  state: state,
                                  onSetEnabled: notifier.setAutoSelectEnabled,
                                  onSetIpCheck: notifier.setAutoSelectIpCheck,
                                  onSetExcluded:
                                      notifier.setAutoSelectServerExcluded,
                                ),
                                const SizedBox(height: 20),
                                _AutoSelectCard(state: state),
                                const SizedBox(height: 20),
                                _ServersCard(
                                  state: state,
                                  onSelectServer: notifier.selectServer,
                                ),
                                const SizedBox(height: 20),
                                _LogsCard(logs: state.logs),
                              ],
                            ),
                          ),
                        ],
                      )
                    else
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _SubscriptionCard(
                            controller: _subscriptionController,
                            busy: state.busy,
                            onAdd: () async {
                              await notifier.addSubscription(
                                _subscriptionController.text,
                              );
                              final latestState = ref.read(
                                dashboardControllerProvider,
                              );
                              if (mounted && latestState.errorMessage == null) {
                                _subscriptionController.clear();
                              }
                            },
                          ),
                          const SizedBox(height: 20),
                          _ConnectionCard(
                            state: state,
                            onModeChanged: notifier.setRuntimeMode,
                            onConnect: notifier.connect,
                            onReconnect: notifier.reconnect,
                            onDisconnect: notifier.disconnect,
                            onRefreshDelays: notifier.refreshDelays,
                            onAutoSelect: notifier.runAutoSelect,
                          ),
                          const SizedBox(height: 20),
                          _AutoSelectSettingsCard(
                            state: state,
                            onSetEnabled: notifier.setAutoSelectEnabled,
                            onSetIpCheck: notifier.setAutoSelectIpCheck,
                            onSetExcluded: notifier.setAutoSelectServerExcluded,
                          ),
                          const SizedBox(height: 20),
                          _ProfilesCard(
                            state: state,
                            onSelect: notifier.chooseProfile,
                            onRefresh: notifier.refreshActiveProfile,
                            onRemove: notifier.removeActiveProfile,
                          ),
                          const SizedBox(height: 20),
                          _AutoSelectCard(state: state),
                          const SizedBox(height: 20),
                          _ServersCard(
                            state: state,
                            onSelectServer: notifier.selectServer,
                          ),
                          const SizedBox(height: 20),
                          _LogsCard(logs: state.logs),
                        ],
                      ),
                    const SizedBox(height: 20),
                    Text(
                      'Health decisions must be based on end-to-end traffic, URLTest and real proxy access, not TCP reachability alone.',
                      style: theme.textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.state});

  final DashboardState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activeMode = state.runtimeSession?.mode ?? state.runtimeMode;
    final statusLabel = switch (state.connectionStage) {
      ConnectionStage.connected => 'Connected',
      ConnectionStage.starting => 'Starting sing-box',
      ConnectionStage.stopping => 'Stopping runtime',
      ConnectionStage.failed => 'Runtime error',
      ConnectionStage.disconnected => 'Idle',
    };

    return Card(
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: const LinearGradient(
            colors: [Color(0xFF173A37), Color(0xFF0E6C66), Color(0xFFB8803D)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    statusLabel,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: Colors.white,
                    ),
                  ),
                ),
                if (state.runtimeSession != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      'Proxy ${state.runtimeSession!.mixedProxyAddress}',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                  ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    activeMode.label,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              'Local sing-box workspace',
              style: theme.textTheme.headlineLarge?.copyWith(
                color: Colors.white,
                height: 1.06,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Add a subscription URL, inspect parsed servers, start the vendored sing-box runtime locally and switch selectors through Clash API. The parsed server list also includes the Auto-select best entry, which chooses and maintains a real server for you while connected.',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: Colors.white.withValues(alpha: 0.88),
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({
    required this.color,
    required this.icon,
    required this.text,
  });

  final Color color;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _AutoSelectProgressCard extends StatelessWidget {
  const _AutoSelectProgressCard({required this.activity});

  final AutoSelectActivityState activity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = describeAutoSelectActivityLabel(activity.label);
    final summary = describeAutoSelectActivityStatus(activity);
    final visibleLines = activity.logLines.length <= 8
        ? activity.logLines.reversed.toList()
        : activity.logLines
              .sublist(activity.logLines.length - 8)
              .reversed
              .toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: theme.textTheme.titleLarge)),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: activity.active
                        ? const Color(0xFFF1ECE2)
                        : const Color(0xFFEDF7F2),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    activity.active ? 'Идёт проверка' : 'Последняя проверка',
                  ),
                ),
              ],
            ),
            if (summary != null && summary != title) ...[
              const SizedBox(height: 8),
              Text(summary, style: theme.textTheme.bodyMedium),
            ],
            if (activity.active || activity.progressValue != null) ...[
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  minHeight: 10,
                  value: activity.progressValue,
                  backgroundColor: const Color(0xFFE8E1D7),
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    Color(0xFF0E6C66),
                  ),
                ),
              ),
            ],
            if (activity.progressLabel != null) ...[
              const SizedBox(height: 8),
              Text(
                'Шаги ${activity.progressLabel}',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (visibleLines.isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF17211F),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final line in visibleLines)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          describeAutoSelectTraceLine(line),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: const Color(0xFFE8EEE6),
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SubscriptionCard extends StatelessWidget {
  const _SubscriptionCard({
    required this.controller,
    required this.busy,
    required this.onAdd,
  });

  final TextEditingController controller;
  final bool busy;
  final Future<void> Function() onAdd;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Subscription', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'This first pass accepts sing-box JSON configs and base64 or plain remote subscriptions with share links such as vless://, vmess://, trojan://, and ss://. The response is saved locally as the template config for the runtime.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 18),
            TextField(
              controller: controller,
              minLines: 2,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: 'https://example.com/subscription',
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: busy ? null : onAdd,
                icon: const Icon(Icons.add_link),
                label: Text(busy ? 'Working…' : 'Add subscription'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfilesCard extends StatelessWidget {
  const _ProfilesCard({
    required this.state,
    required this.onSelect,
    required this.onRefresh,
    required this.onRemove,
  });

  final DashboardState state;
  final Future<void> Function(String profileId) onSelect;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onRemove;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Profiles',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton.outlined(
                  onPressed: state.busy || state.activeProfile == null
                      ? null
                      : onRefresh,
                  tooltip: 'Refresh active subscription',
                  icon: const Icon(Icons.sync),
                ),
                const SizedBox(width: 8),
                IconButton.outlined(
                  onPressed: state.busy || state.activeProfile == null
                      ? null
                      : onRemove,
                  tooltip: 'Remove active profile',
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (state.storage.profiles.isEmpty)
              const Text('No subscriptions saved yet.')
            else
              Column(
                children: [
                  for (final profile in state.storage.profiles)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _ProfileTile(
                        profile: profile,
                        active: profile.id == state.storage.activeProfileId,
                        onTap: () => onSelect(profile.id),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({
    required this.state,
    required this.onModeChanged,
    required this.onConnect,
    required this.onReconnect,
    required this.onDisconnect,
    required this.onRefreshDelays,
    required this.onAutoSelect,
  });

  final DashboardState state;
  final Future<void> Function(RuntimeMode mode) onModeChanged;
  final Future<void> Function() onConnect;
  final Future<void> Function() onReconnect;
  final Future<void> Function() onDisconnect;
  final Future<void> Function() onRefreshDelays;
  final Future<void> Function() onAutoSelect;

  @override
  Widget build(BuildContext context) {
    final profile = state.activeProfile;
    final connected = state.connectionStage == ConnectionStage.connected;
    final activeMode = state.runtimeSession?.mode ?? state.runtimeMode;
    final bestServerCheckRunning = _isBestServerCheckActivity(
      state.autoSelectActivity,
    );
    final showBestServerCheck =
        (state.autoSelectSettings.enabled &&
            isAutoSelectServerTag(state.selectedServerTag)) ||
        state.lastBestServerCheckAt != null ||
        bestServerCheckRunning;
    final title = profile == null
        ? 'Select a profile'
        : 'Active profile: ${profile.name}';
    final connectionSummary = connected
        ? switch (activeMode) {
            RuntimeMode.mixed =>
              'Local mixed inbound: ${state.runtimeSession?.mixedProxyAddress ?? 'starting…'}. Apps must be configured to use it explicitly.',
            RuntimeMode.systemProxy =>
              'Windows system proxy points to ${state.runtimeSession?.mixedProxyAddress ?? 'starting…'}. Browsers that honor system proxy settings should now exit through sing-box.',
            RuntimeMode.tun =>
              'TUN mode is active. The mixed inbound stays available on ${state.runtimeSession?.mixedProxyAddress ?? 'starting…'} for diagnostics and URLTest.',
          }
        : state.runtimeMode.description;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              connectionSummary,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (state.connectedAt != null || showBestServerCheck) ...[
              const SizedBox(height: 20),
              _ConnectionTimersPanel(
                connectedAt: state.connectedAt,
                lastBestServerCheckAt: state.lastBestServerCheckAt,
                showBestServerCheck: showBestServerCheck,
                bestServerCheckRunning: bestServerCheckRunning,
              ),
            ],
            const SizedBox(height: 20),
            Text('Traffic mode', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final mode in RuntimeMode.values)
                  ChoiceChip(
                    label: Text(mode.label),
                    selected: state.runtimeMode == mode,
                    onSelected: state.busy || state.refreshingDelays
                        ? null
                        : (selected) {
                            if (selected) {
                              onModeChanged(mode);
                            }
                          },
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              state.runtimeMode.description,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                ElevatedButton.icon(
                  onPressed: state.busy || profile == null || connected
                      ? null
                      : onConnect,
                  icon: const Icon(Icons.power_settings_new),
                  label: const Text('Connect'),
                ),
                OutlinedButton.icon(
                  onPressed: state.busy || profile == null ? null : onReconnect,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reconnect'),
                ),
                OutlinedButton.icon(
                  onPressed: state.busy || !connected ? null : onDisconnect,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('Disconnect'),
                ),
                OutlinedButton.icon(
                  onPressed: state.refreshingDelays || !connected
                      ? null
                      : onRefreshDelays,
                  icon: const Icon(Icons.speed_outlined),
                  label: Text(
                    state.refreshingDelays ? 'Refreshing…' : 'Refresh delays',
                  ),
                ),
                OutlinedButton.icon(
                  onPressed:
                      state.busy ||
                          !connected ||
                          !isAutoSelectServerTag(state.selectedServerTag)
                      ? null
                      : onAutoSelect,
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('Re-run auto'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionTimersPanel extends StatefulWidget {
  const _ConnectionTimersPanel({
    required this.connectedAt,
    required this.lastBestServerCheckAt,
    required this.showBestServerCheck,
    required this.bestServerCheckRunning,
  });

  final DateTime? connectedAt;
  final DateTime? lastBestServerCheckAt;
  final bool showBestServerCheck;
  final bool bestServerCheckRunning;

  @override
  State<_ConnectionTimersPanel> createState() => _ConnectionTimersPanelState();
}

class _ConnectionTimersPanelState extends State<_ConnectionTimersPanel> {
  Timer? _ticker;
  DateTime _now = DateTime.now();

  bool get _needsTicker =>
      widget.connectedAt != null ||
      widget.lastBestServerCheckAt != null ||
      widget.bestServerCheckRunning;

  @override
  void initState() {
    super.initState();
    _restartTicker();
  }

  @override
  void didUpdateWidget(covariant _ConnectionTimersPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connectedAt != widget.connectedAt ||
        oldWidget.lastBestServerCheckAt != widget.lastBestServerCheckAt ||
        oldWidget.showBestServerCheck != widget.showBestServerCheck ||
        oldWidget.bestServerCheckRunning != widget.bestServerCheckRunning) {
      _now = DateTime.now();
      _restartTicker();
    }
  }

  void _restartTicker() {
    _ticker?.cancel();
    _ticker = null;
    if (!_needsTicker) {
      return;
    }

    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _now = DateTime.now();
      });
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final timerTiles = <Widget>[
      if (widget.connectedAt != null)
        _ConnectionTimerTile(
          title: 'Connection uptime',
          value: _formatElapsed(_elapsedSince(widget.connectedAt!, _now)),
          caption: 'Started at ${_formatTimeOfDay(widget.connectedAt!)}',
        ),
      if (widget.showBestServerCheck)
        _ConnectionTimerTile(
          title: 'Best server check',
          value: widget.lastBestServerCheckAt != null
              ? _formatElapsed(
                  _elapsedSince(widget.lastBestServerCheckAt!, _now),
                )
              : widget.bestServerCheckRunning
              ? 'Running now'
              : 'Not yet',
          caption: widget.lastBestServerCheckAt != null
              ? widget.bestServerCheckRunning
                    ? 'Last completed at ${_formatTimeOfDay(widget.lastBestServerCheckAt!)}. A new check is running now.'
                    : 'Last completed at ${_formatTimeOfDay(widget.lastBestServerCheckAt!)}'
              : widget.bestServerCheckRunning
              ? 'The first best-server check is running.'
              : 'No best-server pass has completed in this session.',
        ),
    ];

    if (timerTiles.isEmpty) {
      return const SizedBox.shrink();
    }

    return Wrap(spacing: 12, runSpacing: 12, children: timerTiles);
  }
}

class _ConnectionTimerTile extends StatelessWidget {
  const _ConnectionTimerTile({
    required this.title,
    required this.value,
    required this.caption,
  });

  final String title;
  final String value;
  final String caption;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 260,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFFF8F3EA),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFE2DDD4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            Text(
              value,
              style: theme.textTheme.headlineSmall?.copyWith(
                color: const Color(0xFF173A37),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(caption, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _AutoSelectCard extends StatelessWidget {
  const _AutoSelectCard({required this.state});

  final DashboardState state;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Auto-selector',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'The auto-selector is exposed as a dedicated server entry. Select Auto-select best in the server list to let the app choose and maintain the active server while sing-box stays connected.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            if (state.autoSelectResults.isEmpty)
              Text(
                state.autoSelectActivity.hasTrace
                    ? state.autoSelectActivity.active
                          ? 'The current auto-select pass is running. Live progress is shown above.'
                          : 'The latest auto-select pass finished. Ranked probe results will appear here after a pass publishes them.'
                    : 'Select Auto-select best in the server list, then connect to start automatic server selection and maintenance.',
              )
            else
              Column(
                children: [
                  for (final result in state.autoSelectResults)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: const Color(0xFFE2DDD4)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    result.serverTag,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                  const SizedBox(height: 6),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      _ProbeChip(
                                        label: result.domainProbeOk
                                            ? 'Domain OK'
                                            : 'Domain fail',
                                        success: result.domainProbeOk,
                                      ),
                                      _ProbeChip(
                                        label: result.ipProbeOk
                                            ? 'IP OK'
                                            : 'IP fail',
                                        success: result.ipProbeOk,
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF1ECE2),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                result.urlTestDelay == null
                                    ? 'n/a'
                                    : '${result.urlTestDelay}ms',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _AutoSelectSettingsCard extends StatelessWidget {
  const _AutoSelectSettingsCard({
    required this.state,
    required this.onSetEnabled,
    required this.onSetIpCheck,
    required this.onSetExcluded,
  });

  final DashboardState state;
  final Future<void> Function(bool enabled) onSetEnabled;
  final Future<void> Function(bool enabled) onSetIpCheck;
  final Future<void> Function(String serverTag, bool excluded) onSetExcluded;

  @override
  Widget build(BuildContext context) {
    final profile = state.activeProfile;
    final settings = state.autoSelectSettings;
    final excludedCount = profile == null
        ? 0
        : profile.servers
              .where((server) => settings.isExcluded(profile.id, server.tag))
              .length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Auto-select settings',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Control whether automatic selection is active, whether it requires an IP-only probe, and which real servers stay out of the automatic pool. Excluded servers remain available for manual use.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: settings.enabled,
              onChanged: state.busy ? null : onSetEnabled,
              title: const Text('Enable automatic server selection'),
              subtitle: const Text(
                'Pre-connect probing and ongoing maintenance only run while this is enabled.',
              ),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: settings.checkIp,
              onChanged: state.busy || !settings.enabled ? null : onSetIpCheck,
              title: const Text('Require IP-only probe'),
              subtitle: const Text(
                'Keep this enabled to reject servers that only pass domain traffic partially.',
              ),
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFF8F3EA),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFE2DDD4)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Probe endpoints',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Domain probe: ${settings.domainProbeUrl}',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'IP probe: ${settings.ipProbeUrl}',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Excluded servers',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                if (profile != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1ECE2),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text('$excludedCount / ${profile.servers.length}'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (profile == null)
              const Text(
                'Select a profile to manage which servers are excluded from automatic selection.',
              )
            else if (profile.servers.isEmpty)
              const Text('The active profile does not have any parsed servers.')
            else
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final server in profile.servers)
                    FilterChip(
                      label: Text(server.displayName),
                      selected: settings.isExcluded(profile.id, server.tag),
                      onSelected: state.busy
                          ? null
                          : (selected) async {
                              await onSetExcluded(server.tag, selected);
                            },
                      avatar: Icon(
                        state.activeServerTag == server.tag
                            ? Icons.bolt
                            : Icons.dns_outlined,
                        size: 18,
                      ),
                      selectedColor: const Color(0xFFF7DFDF),
                      checkmarkColor: const Color(0xFF8B1E1E),
                      side: BorderSide(
                        color: settings.isExcluded(profile.id, server.tag)
                            ? const Color(0xFFCC9090)
                            : const Color(0xFFE2DDD4),
                      ),
                    ),
                ],
              ),
            if (profile != null) ...[
              const SizedBox(height: 10),
              Text(
                'Tap a chip to exclude or restore a server. Manual connection remains available even when a server is excluded from auto-select.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.profile,
    required this.active,
    required this.onTap,
  });

  final ProxyProfile profile;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final subInfo = profile.subscriptionInfo;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: active ? const Color(0xFFEDF7F2) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active ? const Color(0xFF0E6C66) : const Color(0xFFE2DDD4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    profile.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (active)
                  const Icon(Icons.check_circle, color: Color(0xFF0E6C66)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${profile.servers.length} servers • updated ${_formatDate(profile.updatedAt)}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (subInfo != null) ...[
              const SizedBox(height: 6),
              Text(
                _buildSubscriptionLabel(subInfo),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProbeChip extends StatelessWidget {
  const _ProbeChip({required this.label, required this.success});

  final String label;
  final bool success;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: success ? const Color(0xFFDDF2E6) : const Color(0xFFF7DFDF),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: Theme.of(context).textTheme.labelMedium),
    );
  }
}

String _formatDate(DateTime value) {
  final local = value.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '${local.year}-$month-$day $hour:$minute';
}

String _buildSubscriptionLabel(SubscriptionInfo info) {
  final totalGb = info.total <= 0 ? null : info.total / 1024 / 1024 / 1024;
  final remainingGb = info.remaining == null
      ? null
      : info.remaining! / 1024 / 1024 / 1024;
  final traffic = totalGb == null
      ? 'traffic n/a'
      : 'remaining ${remainingGb?.toStringAsFixed(1) ?? '0.0'} GB of ${totalGb.toStringAsFixed(1)} GB';
  final expiry = info.expireAt == null
      ? 'no expiry'
      : 'expires ${_formatDate(info.expireAt!)}';
  return '$traffic • $expiry';
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

String _formatTimeOfDay(DateTime value) {
  final local = value.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  final second = local.second.toString().padLeft(2, '0');
  return '$hour:$minute:$second';
}

class _ServersCard extends StatelessWidget {
  const _ServersCard({required this.state, required this.onSelectServer});

  final DashboardState state;
  final Future<void> Function(String serverTag) onSelectServer;

  @override
  Widget build(BuildContext context) {
    final profile = state.activeProfile;
    final servers = buildSelectableServerEntries(
      profile?.servers ?? const <ServerEntry>[],
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Servers', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Manual server switching uses the local Clash API selector. Delay values are pulled from sing-box URLTest, not from raw TCP reachability.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            if (servers.isEmpty)
              const Text('Add a profile to see parsed servers.')
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: servers.length,
                separatorBuilder: (context, index) => const Divider(height: 18),
                itemBuilder: (context, index) {
                  final server = servers[index];
                  final autoEntry = isAutoSelectServerTag(server.tag);
                  final selected = state.selectedServerTag == server.tag;
                  final delayTag = autoEntry
                      ? state.activeServerTag
                      : server.tag;
                  final delay = delayTag == null
                      ? null
                      : state.delayByTag[delayTag];
                  return InkWell(
                    onTap: state.busy ? null : () => onSelectServer(server.tag),
                    borderRadius: BorderRadius.circular(22),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: selected
                            ? const Color(0xFFEDF7F2)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: selected
                              ? const Color(0xFF0E6C66)
                              : const Color(0xFFE2DDD4),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            selected
                                ? Icons.radio_button_checked
                                : Icons.radio_button_off,
                            color: selected
                                ? const Color(0xFF0E6C66)
                                : const Color(0xFF7E7A73),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  server.displayName,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  autoEntry
                                      ? _autoServerDescription(profile)
                                      : [
                                          server.type.toUpperCase(),
                                          if (server.host != null &&
                                              server.host!.isNotEmpty)
                                            server.host!,
                                          if (server.port != null)
                                            '${server.port}',
                                        ].join(' • '),
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 14),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF1ECE2),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(delay == null ? 'n/a' : '${delay}ms'),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  String _autoServerDescription(ProxyProfile? profile) {
    final activeTag = state.activeServerTag;
    if (profile == null || activeTag == null) {
      return 'Automatically chooses and maintains the best server.';
    }

    for (final server in profile.servers) {
      if (server.tag == activeTag) {
        return 'Automatically chooses and maintains the best server • current ${server.displayName}';
      }
    }

    return 'Automatically chooses and maintains the best server.';
  }
}

class _LogsCard extends StatelessWidget {
  const _LogsCard({required this.logs});

  final List<String> logs;

  @override
  Widget build(BuildContext context) {
    final visibleLogs = logs.length <= 14
        ? logs.reversed.toList()
        : logs.sublist(logs.length - 14).reversed.toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Runtime log', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            if (visibleLogs.isEmpty)
              const Text(
                'sing-box logs will appear here after the first launch.',
              )
            else
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF17211F),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final line in visibleLogs)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          line,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: const Color(0xFFE8EEE6),
                                fontFamily: 'monospace',
                              ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
