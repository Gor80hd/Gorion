import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/profiles/model/profile_entity.dart';
import 'package:gorion_clean/features/profiles/model/profile_models.dart';
import 'package:gorion_clean/features/profiles/model/profile_sort_enum.dart';
import 'package:gorion_clean/utils/functional.dart';

// ─── Minimal TaskEither compatibility shim ───────────────────────────────────

// TaskEither and Either are defined in lib/utils/functional.dart

// ─── Profile data entry ───────────────────────────────────────────────────────

class ProfileDataEntry {
  const ProfileDataEntry(this._entity);
  final ProfileEntity _entity;
  ProfileEntity toEntity() => _entity;
}

// ─── Reactive data source ─────────────────────────────────────────────────────

class ProfileDataSource {
  const ProfileDataSource(this._stream);
  final Stream<List<ProfileDataEntry>> _stream;

  Stream<List<ProfileDataEntry>> watchAll({
    ProfilesSort sort = ProfilesSort.lastUpdate,
    SortMode sortMode = SortMode.ascending,
  }) => _stream;
}

final profileDataSourceProvider = Provider<ProfileDataSource>((ref) {
  var currentEntries = const <ProfileDataEntry>[];
  late final StreamController<List<ProfileDataEntry>> controller;
  controller = StreamController<List<ProfileDataEntry>>.broadcast(
    onListen: () {
      if (!controller.isClosed) {
        controller.add(List<ProfileDataEntry>.unmodifiable(currentEntries));
      }
    },
  );

  ref.listen(dashboardControllerProvider.select((s) => s.storage), (
    _,
    storage,
  ) {
    currentEntries = List<ProfileDataEntry>.unmodifiable(
      storage.profiles
          .map((p) => ProfileDataEntry(profileToEntity(p)))
          .toList(growable: false),
    );
    if (!controller.isClosed) {
      controller.add(currentEntries);
    }
  }, fireImmediately: true);

  ref.onDispose(controller.close);
  return ProfileDataSource(controller.stream);
});

// ─── Repository with TaskEither API ──────────────────────────────────────────

class _ProfileRepoFacade {
  const _ProfileRepoFacade(this._ref);

  final Ref _ref;

  ProxyProfile? _findProfile(String profileId) {
    final storage = _ref.read(dashboardControllerProvider).storage;
    for (final p in storage.profiles) {
      if (p.id == profileId) return p;
    }
    return null;
  }

  TaskEither<dynamic, String> getRawConfig(String profileId) {
    return TaskEither.fromFuture(() async {
      final profile = _findProfile(profileId);
      if (profile == null) throw Exception('Profile not found: $profileId');
      return _ref.read(profileRepositoryProvider).loadTemplateConfig(profile);
    }, (e) => e);
  }

  /// In gorion_clean the template config IS the full outbound config.
  TaskEither<dynamic, String> generateConfig(String profileId) =>
      getRawConfig(profileId);

  TaskEither<dynamic, void> setAsActive(String profileId) {
    return TaskEither.fromFuture(() async {
      await _ref
          .read(dashboardControllerProvider.notifier)
          .chooseProfile(profileId);
    }, (e) => e);
  }
}

/// Facade provider that closely matches hiddify's profileRepositoryProvider.
/// Use `.valueOrNull` on the watched value, or `.future` to await it.
final profileRepoFacadeProvider = FutureProvider<_ProfileRepoFacade>((
  ref,
) async {
  return _ProfileRepoFacade(ref);
});
