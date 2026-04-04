import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/profiles/model/profile_entity.dart';

/// Provides the currently active [ProfileEntity] from the dashboard state.
final activeProfileProvider = Provider<AsyncValue<ProfileEntity?>>((ref) {
  final state = ref.watch(dashboardControllerProvider);
  final active = state.activeProfile;
  if (active == null) return const AsyncData(null);
  return AsyncData(profileToEntity(active));
});
