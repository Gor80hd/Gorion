import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/features/auto_select/utils/auto_select_server_exclusion.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/home/data/server_sort_mode_settings_repository.dart';
import 'package:gorion_clean/features/home/model/server_sort_mode.dart';
import 'package:gorion_clean/features/profiles/model/profile_connection_mode.dart';
import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';

final serverSortModeSettingsRepositoryProvider =
    Provider<ServerSortModeSettingsRepository>(
      (ref) => ServerSortModeSettingsRepository(),
    );

/// Preference notifier for service mode (RuntimeMode).
class _ServiceModeNotifier extends Notifier<RuntimeMode> {
  @override
  RuntimeMode build() {
    return ref.watch(dashboardControllerProvider.select((s) => s.runtimeMode));
  }

  Future<void> update(RuntimeMode mode) async {
    await ref.read(dashboardControllerProvider.notifier).setRuntimeMode(mode);
  }
}

/// Preference notifier for auto-select server enabled flag.
class _AutoSelectServerNotifier extends Notifier<bool> {
  @override
  bool build() {
    return ref.watch(
      dashboardControllerProvider.select((s) => s.autoSelectSettings.enabled),
    );
  }

  Future<void> update(bool value) async {
    await ref
        .read(dashboardControllerProvider.notifier)
        .setAutoSelectEnabled(value);
  }
}

/// Preference notifier for excluded auto-select server keys.
class _AutoSelectServerExcludedNotifier extends Notifier<List<String>> {
  @override
  List<String> build() {
    return ref.watch(
      dashboardControllerProvider.select(
        (s) => s.autoSelectSettings.excludedServerKeys,
      ),
    );
  }

  Future<void> update(List<String> next) async {
    final current = state.toSet();
    final nextSet = next.toSet();
    final notifier = ref.read(dashboardControllerProvider.notifier);
    for (final key in nextSet.difference(current)) {
      final parsed = parseAutoSelectServerExclusionKey(key);
      if (parsed != null) {
        await notifier.setAutoSelectServerExcluded(parsed.serverTag, true);
      }
    }
    for (final key in current.difference(nextSet)) {
      final parsed = parseAutoSelectServerExclusionKey(key);
      if (parsed != null) {
        await notifier.setAutoSelectServerExcluded(parsed.serverTag, false);
      }
    }
  }
}

class _ServerSortModeNotifier extends Notifier<ServerSortMode> {
  bool _restoreScheduled = false;
  bool _hasLocalOverride = false;
  bool _alive = true;

  @override
  ServerSortMode build() {
    _alive = true;
    ref.onDispose(() => _alive = false);
    if (!_restoreScheduled) {
      _restoreScheduled = true;
      unawaited(_restore());
    }
    return ServerSortMode.speed;
  }

  Future<void> update(ServerSortMode mode) async {
    if (state == mode) {
      return;
    }

    _hasLocalOverride = true;
    final previous = state;
    state = mode;

    try {
      await ref.read(serverSortModeSettingsRepositoryProvider).save(mode);
    } catch (_) {
      if (_alive) {
        state = previous;
      }
    }
  }

  Future<void> _restore() async {
    try {
      final stored = await ref
          .read(serverSortModeSettingsRepositoryProvider)
          .load();
      if (_alive && !_hasLocalOverride) {
        state = stored;
      }
    } catch (_) {
      // Fall back to the default mode if the persisted preference is unavailable.
    }
  }
}

/// Central preferences registry for home page compatibility.
abstract class Preferences {
  static final serviceMode =
      NotifierProvider<_ServiceModeNotifier, RuntimeMode>(
        _ServiceModeNotifier.new,
      );

  static final autoSelectServer =
      NotifierProvider<_AutoSelectServerNotifier, bool>(
        _AutoSelectServerNotifier.new,
      );

  static final autoSelectServerExcluded =
      NotifierProvider<_AutoSelectServerExcludedNotifier, List<String>>(
        _AutoSelectServerExcludedNotifier.new,
      );

  static final serverSortMode =
      NotifierProvider<_ServerSortModeNotifier, ServerSortMode>(
        _ServerSortModeNotifier.new,
      );

  static final profileConnectionMode = Provider<ProfileConnectionMode>((ref) {
    return ProfileConnectionMode.currentProfile;
  });

  static final profileDisplayOrder = Provider<List<String>>((ref) => const []);
}

/// Exposes [ConfigOptions.serviceMode] compatible with the map_view widget.
abstract class ConfigOptions {
  static final serviceMode = Preferences.serviceMode;
}
