import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/features/proxy/model/ip_info_entity.dart';

/// Stub – gorion_clean does not include automatic IP detection.
/// Returns an error so map_view gracefully falls back to locale-based location.
final ipInfoNotifierProvider = Provider<AsyncValue<IpInfo>>((ref) {
  return AsyncError<IpInfo>('IP info not available', StackTrace.empty);
});

final directIpInfoNotifierProvider = Provider<AsyncValue<IpInfo>>((ref) {
  return AsyncError<IpInfo>('IP info not available', StackTrace.empty);
});
