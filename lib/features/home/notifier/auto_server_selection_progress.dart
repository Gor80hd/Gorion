import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';

final autoServerSelectionStatusProvider = Provider<String?>((ref) {
  final activity = ref.watch(
    dashboardControllerProvider.select((s) => s.autoSelectActivity),
  );
  return activity.label;
});

class AutoServerSelectionProgress {
  const AutoServerSelectionProgress({this.value});
  final double? value;

  @override
  bool operator ==(Object other) =>
      other is AutoServerSelectionProgress && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

final autoServerSelectionProgressProvider = Provider<AutoServerSelectionProgress?>((ref) {
  final activity = ref.watch(
    dashboardControllerProvider.select((s) => s.autoSelectActivity),
  );
  if (!activity.active) return null;
  return AutoServerSelectionProgress(value: activity.progressValue);
});

class RecentAutoSelectedServer {
  const RecentAutoSelectedServer({required this.tag, required this.until});
  final String tag;
  final DateTime until;
  bool get isActive => until.isAfter(DateTime.now());
}

final recentAutoSelectedServerProvider = StateProvider<RecentAutoSelectedServer?>((ref) => null);
