import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/home/application/server_benchmark_controller.dart';
import 'package:gorion_clean/features/home/data/server_benchmark_runtime_service.dart';
import 'package:gorion_clean/features/profiles/model/profile_entity.dart';
import 'package:gorion_clean/features/profiles/model/profile_models.dart';
import 'package:gorion_clean/features/proxy/model/outbound_models.dart';

void main() {
  test('runActiveProfileBatch loads only the active profile and exits cleanly', () async {
    final service = _FakeServerBenchmarkRuntimeService();
    final controller = ServerBenchmarkController(
      runtimeService: service,
      loadGeneratedConfig: (profile) async => '{"outbounds":[]}',
      userAgent: 'Gorion/Test',
    );
    addTearDown(controller.dispose);

    final activeProfile = _buildProfile('profile-1');
    await controller.runActiveProfileBatch(activeProfile: activeProfile);

    expect(service.loadedProfileIds, ['profile-1']);
    expect(controller.state.active, isFalse);
    expect(controller.state.status, 'Нет серверов для теста');
    expect(controller.state.total, 0);
  });

  test('runActiveProfileBatch records progress and final benchmark results', () async {
    final target = ServerBenchmarkTarget(
      profile: _buildProfile('profile-1'),
      server: OutboundInfo(
        tag: 'server-a',
        tagDisplay: 'Server A',
        type: 'vless',
        isVisible: true,
        isGroup: false,
      ),
      generatedConfig: '{"outbounds":[]}',
    );
    final service = _FakeServerBenchmarkRuntimeService(targets: [target]);
    final controller = ServerBenchmarkController(
      runtimeService: service,
      loadGeneratedConfig: (profile) async => target.generatedConfig,
      userAgent: 'Gorion/Test',
    );
    addTearDown(controller.dispose);

    await controller.runActiveProfileBatch(activeProfile: target.profile);

    expect(controller.state.completed, 1);
    expect(controller.state.total, 1);
    expect(controller.state.pingResults[target.key], 42);
    expect(controller.state.speedResults[target.key], 2048);
    expect(controller.state.active, isFalse);
    expect(controller.state.status, isNull);
  });

  test('stop marks an active batch for cancellation and preserves the stopped status', () async {
    final target = ServerBenchmarkTarget(
      profile: _buildProfile('profile-1'),
      server: OutboundInfo(
        tag: 'server-a',
        tagDisplay: 'Server A',
        type: 'vless',
        isVisible: true,
        isGroup: false,
      ),
      generatedConfig: '{"outbounds":[]}',
    );
    final releaseRun = Completer<void>();
    final service = _FakeServerBenchmarkRuntimeService(
      targets: [target],
      beforeFinish: () => releaseRun.future,
    );
    final controller = ServerBenchmarkController(
      runtimeService: service,
      loadGeneratedConfig: (profile) async => target.generatedConfig,
      userAgent: 'Gorion/Test',
    );
    addTearDown(controller.dispose);

    final runFuture = controller.runActiveProfileBatch(activeProfile: target.profile);
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.active, isTrue);
    controller.stop();
    expect(controller.state.status, 'Останавливаем…');

    releaseRun.complete();
    await runFuture;

    expect(controller.state.active, isFalse);
    expect(controller.state.status, 'Остановлено');
  });
}

class _FakeServerBenchmarkRuntimeService extends ServerBenchmarkRuntimeService {
  _FakeServerBenchmarkRuntimeService({
    this.targets = const <ServerBenchmarkTarget>[],
    this.beforeFinish,
  });

  final List<ServerBenchmarkTarget> targets;
  final Future<void> Function()? beforeFinish;
  final List<String> loadedProfileIds = <String>[];

  @override
  Future<List<ServerBenchmarkTarget>> loadTargets({
    required List<ProfileEntity> profiles,
    required Future<String> Function(ProfileEntity profile) loadGeneratedConfig,
  }) async {
    loadedProfileIds.addAll(profiles.map((profile) => profile.id));
    for (final profile in profiles) {
      await loadGeneratedConfig(profile);
    }
    return targets;
  }

  @override
  Future<void> runBatch({
    required List<ServerBenchmarkTarget> targets,
    required String userAgent,
    required bool Function() isCancelled,
    required void Function(String status) onStatus,
    required void Function(int completed, int total) onProgress,
    required void Function(String key) onTargetStarted,
    required void Function(String key, int speed) onSpeedProgress,
    required void Function(String key, int ping, int speed) onTargetFinished,
  }) async {
    for (final target in targets) {
      onTargetStarted(target.key);
      onStatus('Параллельный тест 0/${targets.length}');
      onSpeedProgress(target.key, 512);
      if (beforeFinish != null) {
        await beforeFinish!();
      }
      if (isCancelled()) {
        onStatus('Остановлено');
        onProgress(1, targets.length);
        return;
      }
      onTargetFinished(target.key, 42, 2048);
      onProgress(1, targets.length);
      onStatus('Готово');
    }
  }
}

ProfileEntity _buildProfile(String id) {
  final now = DateTime(2026, 4, 21, 10);
  return profileToEntity(
    ProxyProfile(
      id: id,
      name: 'Profile $id',
      subscriptionUrl: 'https://example.com/$id',
      templateFileName: '$id.json',
      createdAt: now,
      updatedAt: now,
      servers: const <ServerEntry>[],
      lastSelectedServerTag: '',
      lastAutoSelectedServerTag: '',
    ),
  );
}
