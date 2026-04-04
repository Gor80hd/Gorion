import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/proxy/model/outbound_models.dart';
import 'package:gorion_clean/features/runtime/model/connection_status.dart';
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';

class _ConnectionNotifier extends Notifier<ConnectionStatus> {
  @override
  ConnectionStatus build() {
    final stage = ref.watch(
      dashboardControllerProvider.select((s) => s.connectionStage),
    );
    return switch (stage) {
      ConnectionStage.connected => const Connected(),
      ConnectionStage.starting => const Connecting(),
      ConnectionStage.stopping => const Disconnecting(),
      _ => const Disconnected(),
    };
  }

  Future<void> toggleConnection() async {
    final notifier = ref.read(dashboardControllerProvider.notifier);
    final stage = ref.read(dashboardControllerProvider).connectionStage;
    if (stage == ConnectionStage.connected || stage == ConnectionStage.starting) {
      await notifier.disconnect();
    } else {
      await notifier.connect();
    }
  }
}

final connectionNotifierProvider =
    NotifierProvider<_ConnectionNotifier, ConnectionStatus>(_ConnectionNotifier.new);

final serviceRunningProvider = Provider<AsyncValue<bool>>((ref) {
  final state = ref.watch(dashboardControllerProvider);
  return AsyncData(state.connectionStage == ConnectionStage.connected);
});

/// Provides the active proxy as [OutboundInfo] based on dashboard state.
final activeProxyNotifierProvider = Provider<AsyncValue<OutboundInfo>>((ref) {
  final state = ref.watch(dashboardControllerProvider);
  final tag = state.activeServerTag ?? state.selectedServerTag;
  if (tag == null) return AsyncData(OutboundInfo());

  for (final profile in state.storage.profiles) {
    for (final server in profile.servers) {
      if (server.tag == tag) {
        final delay = state.delayByTag[tag] ?? 0;
        return AsyncData(OutboundInfo.fromServerEntry(server, delay: delay));
      }
    }
  }

  return AsyncData(OutboundInfo(tag: tag, tagDisplay: tag, type: 'unknown', isVisible: true));
});
