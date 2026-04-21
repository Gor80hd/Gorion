import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/features/home/application/server_benchmark_controller.dart';
import 'package:gorion_clean/features/proxy/model/outbound_models.dart';

final selectedServerPreviewProvider = StateProvider<OutboundInfo?>((ref) => null);

final benchmarkActiveProvider = Provider<bool>((ref) {
  return ref.watch(
    serverBenchmarkControllerProvider.select((state) => state.active),
  );
});

class PendingServerSelection {
  const PendingServerSelection({
    required this.requestId,
    required this.profileId,
    this.groupTag,
    required this.outboundTag,
  });

  final int requestId;
  final String profileId;
  final String? groupTag;
  final String outboundTag;
}

final pendingServerSelectionProvider = StateProvider<PendingServerSelection?>((ref) => null);

final pendingAutoServerSelectionProvider = StateProvider<PendingServerSelection?>((ref) => null);
