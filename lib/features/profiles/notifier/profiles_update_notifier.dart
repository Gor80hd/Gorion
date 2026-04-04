import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';

typedef ProfilesUpdateState = ({
  bool running,
  bool force,
  int total,
  int completed,
  int updated,
  int failed,
  String? message,
  String? currentName,
  DateTime? lastRun,
});

/// Compatibility getter so `ref.watch(provider).valueOrNull` works.
extension ProfilesUpdateStateExt on ProfilesUpdateState {
  ProfilesUpdateState? get valueOrNull => this;
}

const _idle = (
  running: false,
  force: false,
  total: 0,
  completed: 0,
  updated: 0,
  failed: 0,
  message: null,
  currentName: null,
  lastRun: null,
);

class _ProfilesUpdateNotifier extends Notifier<ProfilesUpdateState> {
  @override
  ProfilesUpdateState build() => _idle;

  Future<void> trigger() async {
    if (state.running) return;
    state = (
      running: true,
      force: false,
      total: 0,
      completed: 0,
      updated: 0,
      failed: 0,
      message: null,
      currentName: null,
      lastRun: null,
    );
    try {
      await ref.read(dashboardControllerProvider.notifier).refreshActiveProfile();
      state = (
        running: false,
        force: false,
        total: 1,
        completed: 1,
        updated: 1,
        failed: 0,
        message: 'Подписки обновлены',
        currentName: null,
        lastRun: DateTime.now(),
      );
    } catch (_) {
      state = (
        running: false,
        force: false,
        total: 1,
        completed: 1,
        updated: 0,
        failed: 1,
        message: 'Ошибка обновления',
        currentName: null,
        lastRun: DateTime.now(),
      );
    }
  }
}

final foregroundProfilesUpdateNotifierProvider =
    NotifierProvider<_ProfilesUpdateNotifier, ProfilesUpdateState>(
  _ProfilesUpdateNotifier.new,
);
