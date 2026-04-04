import 'package:flutter_riverpod/flutter_riverpod.dart';

class TrafficStats {
  const TrafficStats({this.uplink = 0, this.downlink = 0});

  final int uplink;
  final int downlink;
}

/// Stub – traffic stats are not yet collected in gorion_clean.
final statsNotifierProvider = Provider<AsyncValue<TrafficStats>>((ref) {
  return const AsyncData(TrafficStats());
});
