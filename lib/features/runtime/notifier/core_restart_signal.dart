import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';

/// Fires when the runtime session changes (sing-box restart).
/// Analogous to Gorion's coreRestartSignalProvider.
final coreRestartSignalProvider = Provider<int>((ref) {
  final session = ref.watch(dashboardControllerProvider.select((s) => s.runtimeSession));
  return session?.controllerPort ?? 0;
});
