import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
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
              'Add a subscription URL, inspect parsed servers, start the vendored sing-box runtime locally and switch selectors through Clash API. This foundation is built to host the migrated auto-selector next.',
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
                  onPressed: state.busy || !connected ? null : onAutoSelect,
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('Auto-select best'),
                ),
              ],
            ),
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
              'The first migrated slice evaluates candidate servers using URLTest and real proxy probes. Domain and IP results are shown separately because partial connectivity is normal in censored networks.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            if (state.autoSelectResults.isEmpty)
              const Text(
                'Run Auto-select best after connecting to inspect the ranked candidates.',
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

class _ServersCard extends StatelessWidget {
  const _ServersCard({required this.state, required this.onSelectServer});

  final DashboardState state;
  final Future<void> Function(String serverTag) onSelectServer;

  @override
  Widget build(BuildContext context) {
    final profile = state.activeProfile;
    final servers = profile?.servers ?? const <ServerEntry>[];
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
                  final selected = state.selectedServerTag == server.tag;
                  final delay = state.delayByTag[server.tag];
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
                                  [
                                    server.type.toUpperCase(),
                                    if (server.host != null &&
                                        server.host!.isNotEmpty)
                                      server.host!,
                                    if (server.port != null) '${server.port}',
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
