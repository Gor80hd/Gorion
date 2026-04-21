import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/core/http_client/http_client_provider.dart';
import 'package:gorion_clean/features/home/data/server_benchmark_runtime_service.dart';
import 'package:gorion_clean/features/profiles/data/profile_data_providers.dart';
import 'package:gorion_clean/features/profiles/model/profile_entity.dart';

final serverBenchmarkConfigLoaderProvider =
    Provider<Future<String> Function(ProfileEntity profile)>((ref) {
      return (profile) async {
        final profileRepo = await ref.read(profileRepoFacadeProvider.future);
        return profileRepo
            .generateConfig(profile.id)
            .getOrElse((_) => '')
            .run();
      };
    });

final serverBenchmarkUserAgentProvider = Provider<String>((ref) {
  return ref.read(httpClientProvider).userAgent;
});

final serverBenchmarkRuntimeServiceProvider =
    Provider<ServerBenchmarkRuntimeService>((ref) {
      return ServerBenchmarkRuntimeService();
    });

final serverBenchmarkControllerProvider =
    StateNotifierProvider<ServerBenchmarkController, ServerBenchmarkState>((
      ref,
    ) {
      return ServerBenchmarkController(
        runtimeService: ref.read(serverBenchmarkRuntimeServiceProvider),
        loadGeneratedConfig: ref.read(serverBenchmarkConfigLoaderProvider),
        userAgent: ref.read(serverBenchmarkUserAgentProvider),
      );
    });

class ServerBenchmarkState {
  const ServerBenchmarkState({
    this.active = false,
    this.pingResults = const <String, int>{},
    this.speedResults = const <String, int>{},
    this.completed = 0,
    this.total = 0,
    this.status,
    this.startedAt,
    this.elapsed = Duration.zero,
    this.benchmarkingKeys = const <String>{},
  });

  final bool active;
  final Map<String, int> pingResults;
  final Map<String, int> speedResults;
  final int completed;
  final int total;
  final String? status;
  final DateTime? startedAt;
  final Duration elapsed;
  final Set<String> benchmarkingKeys;

  ServerBenchmarkState copyWith({
    bool? active,
    Map<String, int>? pingResults,
    Map<String, int>? speedResults,
    int? completed,
    int? total,
    Object? status = _statusSentinel,
    Object? startedAt = _startedAtSentinel,
    Duration? elapsed,
    Set<String>? benchmarkingKeys,
  }) {
    return ServerBenchmarkState(
      active: active ?? this.active,
      pingResults: pingResults ?? this.pingResults,
      speedResults: speedResults ?? this.speedResults,
      completed: completed ?? this.completed,
      total: total ?? this.total,
      status: identical(status, _statusSentinel) ? this.status : status as String?,
      startedAt: identical(startedAt, _startedAtSentinel)
          ? this.startedAt
          : startedAt as DateTime?,
      elapsed: elapsed ?? this.elapsed,
      benchmarkingKeys: benchmarkingKeys ?? this.benchmarkingKeys,
    );
  }

  bool isBenchmarkingKey(String key) => benchmarkingKeys.contains(key);
}

const _statusSentinel = Object();
const _startedAtSentinel = Object();

class ServerBenchmarkController extends StateNotifier<ServerBenchmarkState> {
  ServerBenchmarkController(
    {
    required ServerBenchmarkRuntimeService runtimeService,
    required Future<String> Function(ProfileEntity profile) loadGeneratedConfig,
    required String userAgent,
  }) : _runtimeService = runtimeService,
       _loadGeneratedConfig = loadGeneratedConfig,
       _userAgent = userAgent,
       super(const ServerBenchmarkState());

  final ServerBenchmarkRuntimeService _runtimeService;
  final Future<String> Function(ProfileEntity profile) _loadGeneratedConfig;
  final String _userAgent;

  Timer? _elapsedTimer;
  bool _stopRequested = false;
  Future<void>? _activeRun;

  Future<void> runActiveProfileBatch({required ProfileEntity? activeProfile}) {
    if (_activeRun != null || state.active || activeProfile == null) {
      return _activeRun ?? Future<void>.value();
    }

    final future = _runActiveProfileBatch(activeProfile);
    _activeRun = future;
    future.whenComplete(() {
      if (identical(_activeRun, future)) {
        _activeRun = null;
      }
    });
    return future;
  }

  void stop() {
    if (!state.active) {
      return;
    }
    _stopRequested = true;
    state = state.copyWith(status: 'Останавливаем…');
  }

  int effectivePing(String profileId, String serverTag, int fallback) {
    return state.pingResults[buildServerBenchmarkKey(profileId, serverTag)] ??
        fallback;
  }

  int effectiveSpeed(String profileId, String serverTag) {
    return state.speedResults[buildServerBenchmarkKey(profileId, serverTag)] ??
        0;
  }

  @override
  void dispose() {
    _stopRequested = true;
    _elapsedTimer?.cancel();
    super.dispose();
  }

  Future<void> _runActiveProfileBatch(ProfileEntity activeProfile) async {
    _stopRequested = false;
    final startedAt = DateTime.now();
    state = const ServerBenchmarkState().copyWith(
      active: true,
      status: 'Подготовка…',
      startedAt: startedAt,
      elapsed: Duration.zero,
    );
    _startElapsedTimer(startedAt);

    try {
      final targets = await _runtimeService.loadTargets(
        profiles: <ProfileEntity>[activeProfile],
        loadGeneratedConfig: _loadGeneratedConfig,
      );

      state = state.copyWith(total: targets.length);
      if (targets.isEmpty) {
        _stopElapsedTimer();
        state = state.copyWith(
          active: false,
          status: 'Нет серверов для теста',
          startedAt: null,
          elapsed: Duration.zero,
        );
        return;
      }

      await _runtimeService.runBatch(
        targets: targets,
        userAgent: _userAgent,
        isCancelled: () => _stopRequested,
        onStatus: (status) {
          state = state.copyWith(status: status);
        },
        onProgress: (completed, total) {
          state = state.copyWith(completed: completed, total: total);
        },
        onTargetStarted: (key) {
          state = state.copyWith(
            benchmarkingKeys: <String>{...state.benchmarkingKeys, key},
          );
        },
        onSpeedProgress: (key, speed) {
          state = state.copyWith(
            speedResults: <String, int>{...state.speedResults, key: speed},
          );
        },
        onTargetFinished: (key, ping, speed) {
          final benchmarkingKeys = <String>{...state.benchmarkingKeys}
            ..remove(key);
          state = state.copyWith(
            pingResults: <String, int>{...state.pingResults, key: ping},
            speedResults: <String, int>{...state.speedResults, key: speed},
            benchmarkingKeys: benchmarkingKeys,
          );
        },
      );

      final elapsed = startedAt == state.startedAt
          ? DateTime.now().difference(startedAt)
          : state.elapsed;
      _stopElapsedTimer();
      state = state.copyWith(
        active: false,
        benchmarkingKeys: const <String>{},
        elapsed: elapsed,
        status: _stopRequested ? 'Остановлено' : null,
        startedAt: _stopRequested ? startedAt : null,
      );
    } catch (_) {
      _stopElapsedTimer();
      state = state.copyWith(
        active: false,
        status: null,
        startedAt: null,
        benchmarkingKeys: const <String>{},
      );
      rethrow;
    } finally {
      _stopRequested = false;
    }
  }

  void _startElapsedTimer(DateTime startedAt) {
    _elapsedTimer?.cancel();

    void updateElapsed() {
      if (!mounted || !state.active) {
        return;
      }
      state = state.copyWith(
        elapsed: DateTime.now().difference(startedAt),
      );
    }

    updateElapsed();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      updateElapsed();
    });
  }

  void _stopElapsedTimer() {
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
  }
}
