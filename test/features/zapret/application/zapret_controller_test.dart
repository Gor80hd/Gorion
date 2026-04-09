import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/core/windows/windows_elevation_service.dart';
import 'package:gorion_clean/features/zapret/application/zapret_controller.dart';
import 'package:gorion_clean/features/zapret/data/zapret_probe_service.dart';
import 'package:gorion_clean/features/zapret/data/zapret_runtime_service.dart';
import 'package:gorion_clean/features/zapret/data/zapret_settings_repository.dart';
import 'package:gorion_clean/features/zapret/model/zapret_models.dart';
import 'package:gorion_clean/features/zapret/model/zapret_settings.dart';

void main() {
  test(
    'starts zapret runtime when configured and not blocked by TUN',
    () async {
      final runtimeService = _FakeZapretRuntimeService();
      final controller = ZapretController(
        repository: _FakeZapretSettingsRepository(),
        runtimeService: runtimeService,
        elevationService: _FakeWindowsElevationService(elevated: true),
        initialState: const ZapretState(
          bootstrapping: false,
          settings: ZapretSettings(installDirectory: r'E:\Tools\zapret2'),
        ),
        loadOnInit: false,
      );
      addTearDown(controller.dispose);

      await controller.start();

      expect(runtimeService.startCalls, 1);
      expect(controller.state.stage, ZapretStage.running);
      expect(controller.state.runtimeSession?.processId, 4242);
      expect(
        controller.state.generatedConfigSummary,
        contains('Рекомендуемый'),
      );
    },
  );

  test(
    'hydrates the bundled zapret path before start when none is saved',
    () async {
      final runtimeService = _FakeZapretRuntimeService();
      final controller = ZapretController(
        repository: _FakeZapretSettingsRepository(),
        runtimeService: runtimeService,
        elevationService: _FakeWindowsElevationService(elevated: true),
        initialState: const ZapretState(
          bootstrapping: false,
          settings: ZapretSettings(),
        ),
        loadOnInit: false,
      );
      addTearDown(controller.dispose);

      await controller.start();

      expect(runtimeService.hydrateCalls, 1);
      expect(controller.state.settings.installDirectory, r'E:\Bundled\zapret2');
      expect(controller.state.stage, ZapretStage.running);
    },
  );

  test('auto-stops a running zapret session when TUN becomes active', () async {
    final runtimeService = _FakeZapretRuntimeService();
    final controller = ZapretController(
      repository: _FakeZapretSettingsRepository(),
      runtimeService: runtimeService,
      initialState: ZapretState(
        bootstrapping: false,
        settings: const ZapretSettings(installDirectory: r'E:\Tools\zapret2'),
        stage: ZapretStage.running,
        runtimeSession: runtimeService.sessionTemplate,
      ),
      loadOnInit: false,
    );
    addTearDown(controller.dispose);

    await controller.syncTunConflict(active: true);

    expect(runtimeService.stopCalls, 1);
    expect(controller.state.tunConflictActive, isTrue);
    expect(controller.state.stage, ZapretStage.pausedByTun);
  });

  test('requests elevated relaunch before starting zapret', () async {
    if (!Platform.isWindows) {
      return;
    }

    final runtimeService = _FakeZapretRuntimeService();
    final elevationService = _FakeWindowsElevationService(elevated: false);
    final controller = ZapretController(
      repository: _FakeZapretSettingsRepository(),
      runtimeService: runtimeService,
      elevationService: elevationService,
      initialState: const ZapretState(
        bootstrapping: false,
        settings: ZapretSettings(installDirectory: r'E:\Tools\zapret2'),
      ),
      loadOnInit: false,
    );
    addTearDown(controller.dispose);

    await controller.start();

    expect(elevationService.relaunchCallCount, 1);
    expect(
      elevationService.lastAction,
      PendingElevatedLaunchAction.startZapret,
    );
    expect(runtimeService.startCalls, 0);
    expect(controller.state.statusMessage, contains('UAC'));
  });

  test('shows a friendly message when winws2 requires elevation', () async {
    final runtimeService = _FakeZapretRuntimeService()
      ..startError = ProcessException(
        'winws2.exe',
        const ['--dry-run'],
        'Запрошенная операция требует повышения',
        740,
      );
    final controller = ZapretController(
      repository: _FakeZapretSettingsRepository(),
      runtimeService: runtimeService,
      elevationService: _FakeWindowsElevationService(elevated: true),
      initialState: const ZapretState(
        bootstrapping: false,
        settings: ZapretSettings(installDirectory: r'E:\Tools\zapret2'),
      ),
      loadOnInit: false,
    );
    addTearDown(controller.dispose);

    await controller.start();

    expect(controller.state.stage, ZapretStage.failed);
    expect(
      controller.state.errorMessage,
      'Запуск winws2 требует прав администратора. Перезапустите Gorion от имени администратора и попробуйте снова.',
    );
  });

  test('explains invalid parameter exit code from winws2', () async {
    final runtimeService = _FakeZapretRuntimeService();
    final controller = ZapretController(
      repository: _FakeZapretSettingsRepository(),
      runtimeService: runtimeService,
      elevationService: _FakeWindowsElevationService(elevated: true),
      initialState: const ZapretState(
        bootstrapping: false,
        settings: ZapretSettings(installDirectory: r'E:\Tools\zapret2'),
      ),
      loadOnInit: false,
    );
    addTearDown(controller.dispose);

    await controller.start();
    runtimeService.completeExit(87);

    expect(controller.state.stage, ZapretStage.failed);
    expect(
      controller.state.errorMessage,
      'zapret2 отклонил параметры запуска (код 87 / ERROR_INVALID_PARAMETER). Значит, winws2 не принял один из аргументов текущего пресета.',
    );
  });

  test('explains DLL initialization failure exit code from winws2', () async {
    final runtimeService = _FakeZapretRuntimeService();
    final controller = ZapretController(
      repository: _FakeZapretSettingsRepository(),
      runtimeService: runtimeService,
      elevationService: _FakeWindowsElevationService(elevated: true),
      initialState: const ZapretState(
        bootstrapping: false,
        settings: ZapretSettings(installDirectory: r'E:\Tools\zapret2'),
      ),
      loadOnInit: false,
    );
    addTearDown(controller.dispose);

    await controller.start();
    runtimeService.completeExit(-1073741502);

    expect(controller.state.stage, ZapretStage.failed);
    expect(
      controller.state.errorMessage,
      'zapret2 не смог инициализироваться (код -1073741502 / 0xC0000142). Обычно это сбой инициализации DLL или процесса; сначала попробуйте запустить Gorion от имени администратора.',
    );
  });

  test(
    'autotune varies generic TLS during Discord stage and keeps the winner running',
    () async {
      if (!Platform.isWindows) {
        return;
      }

      final runtimeService = _FakeZapretRuntimeService();
      final probeService = _FakeZapretProbeService(
        currentSettings: () => runtimeService.lastStartedSettings!,
        buildReport: (targets, settings) {
          final targetIds = {for (final target in targets) target.id};
          final profile = settings.effectiveCustomProfile;

          if (_sameTargetIds(targetIds, const {'youtube'})) {
            final success =
                profile.youtubeVariant == ZapretFlowsealVariant.multisplit;
            return _reportFor(
              targets,
              successIds: success ? targetIds : const {},
              baseLatencyMs: success ? 110 : 220,
            );
          }

          if (_sameTargetIds(targetIds, const {'discord'})) {
            final success =
                profile.genericVariant == ZapretFlowsealVariant.hostfakesplit;
            return _reportFor(
              targets,
              successIds: success ? targetIds : const {},
              baseLatencyMs: 96,
            );
          }

          if (_sameTargetIds(targetIds, const {'google', 'cloudflare'})) {
            final success =
                profile.genericVariant == ZapretFlowsealVariant.hostfakesplit;
            return _reportFor(
              targets,
              successIds: success ? targetIds : const {},
              baseLatencyMs: 101,
            );
          }

          if (_sameTargetIds(targetIds, _fullAutotuneTargetIds)) {
            final success =
                profile.youtubeVariant == ZapretFlowsealVariant.multisplit &&
                profile.genericVariant == ZapretFlowsealVariant.hostfakesplit;
            return _reportFor(
              targets,
              successIds: success ? targetIds : const {},
              baseLatencyMs: 88,
            );
          }

          return _reportFor(targets, successIds: const {});
        },
      );
      final controller = ZapretController(
        repository: _FakeZapretSettingsRepository(),
        runtimeService: runtimeService,
        probeService: probeService,
        elevationService: _FakeWindowsElevationService(elevated: true),
        probeSettleDuration: Duration.zero,
        initialState: const ZapretState(
          bootstrapping: false,
          settings: ZapretSettings(installDirectory: r'E:\Tools\zapret2'),
        ),
        loadOnInit: false,
      );
      addTearDown(controller.dispose);

      await controller.autoTuneForBlockedResources();

      expect(controller.state.autotuneRunning, isFalse);
      expect(controller.state.stage, ZapretStage.running);
      expect(controller.state.settings.customProfile, isNotNull);
      expect(
        controller.state.settings.customProfile?.youtubeVariant,
        ZapretFlowsealVariant.multisplit,
      );
      expect(
        controller.state.settings.customProfile?.genericVariant,
        ZapretFlowsealVariant.hostfakesplit,
      );
      expect(controller.state.lastProbeReport?.allRequiredPassed, isTrue);
      expect(
        runtimeService.startedSettings.any(
          (settings) =>
              settings.effectiveCustomProfile.genericVariant ==
              ZapretFlowsealVariant.hostfakesplit,
        ),
        isTrue,
      );
    },
  );

  test(
    'autotune keeps multiple YouTube seeds and can recover from a greedy miss',
    () async {
      if (!Platform.isWindows) {
        return;
      }

      final runtimeService = _FakeZapretRuntimeService();
      final probeService = _FakeZapretProbeService(
        currentSettings: () => runtimeService.lastStartedSettings!,
        buildReport: (targets, settings) {
          final targetIds = {for (final target in targets) target.id};
          final profile = settings.effectiveCustomProfile;

          if (_sameTargetIds(targetIds, const {'youtube'})) {
            final successIds = switch (profile.youtubeVariant) {
              ZapretFlowsealVariant.multisplit => const {'youtube'},
              ZapretFlowsealVariant.fakedsplit => const {'youtube'},
              _ => const <String>{},
            };
            final baseLatencyMs =
                profile.youtubeVariant == ZapretFlowsealVariant.multisplit
                ? 92
                : 145;
            return _reportFor(
              targets,
              successIds: successIds,
              baseLatencyMs: baseLatencyMs,
            );
          }

          if (_sameTargetIds(targetIds, const {'discord'})) {
            final success =
                (profile.youtubeVariant == ZapretFlowsealVariant.multisplit &&
                    profile.genericVariant ==
                        ZapretFlowsealVariant.hostfakesplit) ||
                (profile.youtubeVariant == ZapretFlowsealVariant.fakedsplit &&
                    profile.genericVariant ==
                        ZapretFlowsealVariant.multidisorder);
            return _reportFor(
              targets,
              successIds: success ? targetIds : const {},
              baseLatencyMs:
                  profile.youtubeVariant == ZapretFlowsealVariant.multisplit
                  ? 96
                  : 109,
            );
          }

          if (_sameTargetIds(targetIds, const {'google', 'cloudflare'})) {
            final success =
                profile.youtubeVariant == ZapretFlowsealVariant.fakedsplit &&
                profile.genericVariant == ZapretFlowsealVariant.multidisorder;
            return _reportFor(
              targets,
              successIds: success ? targetIds : const {},
              baseLatencyMs: 103,
            );
          }

          if (_sameTargetIds(targetIds, _fullAutotuneTargetIds)) {
            final success =
                profile.youtubeVariant == ZapretFlowsealVariant.fakedsplit &&
                profile.genericVariant == ZapretFlowsealVariant.multidisorder;
            return _reportFor(
              targets,
              successIds: success ? targetIds : const {},
              baseLatencyMs: 87,
            );
          }

          return _reportFor(targets, successIds: const {});
        },
      );

      final controller = ZapretController(
        repository: _FakeZapretSettingsRepository(),
        runtimeService: runtimeService,
        probeService: probeService,
        elevationService: _FakeWindowsElevationService(elevated: true),
        probeSettleDuration: Duration.zero,
        initialState: const ZapretState(
          bootstrapping: false,
          settings: ZapretSettings(installDirectory: r'E:\Tools\zapret2'),
        ),
        loadOnInit: false,
      );
      addTearDown(controller.dispose);

      await controller.autoTuneForBlockedResources();

      expect(controller.state.stage, ZapretStage.running);
      expect(
        controller.state.settings.customProfile?.youtubeVariant,
        ZapretFlowsealVariant.fakedsplit,
      );
      expect(
        controller.state.settings.customProfile?.genericVariant,
        ZapretFlowsealVariant.multidisorder,
      );
    },
  );

  test('autotune failure message prefers the broader partial report', () async {
    if (!Platform.isWindows) {
      return;
    }

    final runtimeService = _FakeZapretRuntimeService();
    final probeService = _FakeZapretProbeService(
      currentSettings: () => runtimeService.lastStartedSettings!,
      buildReport: (targets, settings) {
        final targetIds = {for (final target in targets) target.id};
        final profile = settings.effectiveCustomProfile;

        if (_sameTargetIds(targetIds, const {'youtube'})) {
          final success =
              profile.youtubeVariant == ZapretFlowsealVariant.multisplit;
          return _reportFor(
            targets,
            successIds: success ? targetIds : const {},
            baseLatencyMs: 112,
          );
        }

        if (_sameTargetIds(targetIds, const {'discord'})) {
          final success =
              profile.genericVariant == ZapretFlowsealVariant.hostfakesplit;
          return _reportFor(
            targets,
            successIds: success ? targetIds : const {},
            baseLatencyMs: 97,
          );
        }

        if (_sameTargetIds(targetIds, const {'google', 'cloudflare'})) {
          final successIds =
              profile.genericVariant == ZapretFlowsealVariant.hostfakesplit
              ? const {'google'}
              : const <String>{};
          return _reportFor(
            targets,
            successIds: successIds,
            baseLatencyMs: 132,
          );
        }

        return _reportFor(targets, successIds: const {});
      },
    );

    final controller = ZapretController(
      repository: _FakeZapretSettingsRepository(),
      runtimeService: runtimeService,
      probeService: probeService,
      elevationService: _FakeWindowsElevationService(elevated: true),
      probeSettleDuration: Duration.zero,
      initialState: const ZapretState(
        bootstrapping: false,
        settings: ZapretSettings(installDirectory: r'E:\Tools\zapret2'),
      ),
      loadOnInit: false,
    );
    addTearDown(controller.dispose);

    await controller.autoTuneForBlockedResources();

    expect(controller.state.stage, ZapretStage.failed);
    expect(controller.state.errorMessage, contains('Лучший кандидат'));
    expect(controller.state.errorMessage, contains('(1/2)'));
    expect(controller.state.errorMessage, contains('Google'));
    expect(controller.state.errorMessage, contains('Cloudflare'));
  });
}

const _fullAutotuneTargetIds = <String>{
  'youtube',
  'discord',
  'google',
  'cloudflare',
};

bool _sameTargetIds(Set<String> actual, Set<String> expected) {
  if (actual.length != expected.length) {
    return false;
  }
  return actual.containsAll(expected);
}

ZapretProbeReport _reportFor(
  Iterable<ZapretProbeTarget> targets, {
  required Set<String> successIds,
  int baseLatencyMs = 130,
}) {
  var index = 0;
  return ZapretProbeReport(
    results: [
      for (final target in targets)
        ZapretProbeResult(
          target: target,
          success: successIds.contains(target.id),
          latencyMs: successIds.contains(target.id)
              ? baseLatencyMs + (index++ * 7)
              : null,
          details: successIds.contains(target.id) ? 'ok' : 'timeout',
        ),
    ],
  );
}

class _FakeZapretSettingsRepository extends ZapretSettingsRepository {
  _FakeZapretSettingsRepository() : super(storageRootLoader: null);

  ZapretSettings _stored = const ZapretSettings();

  @override
  Future<ZapretSettings> load() async {
    return _stored;
  }

  @override
  Future<ZapretSettings> save(ZapretSettings settings) async {
    _stored = settings;
    return settings;
  }
}

class _FakeZapretRuntimeService extends ZapretRuntimeService {
  _FakeZapretRuntimeService();

  int startCalls = 0;
  int stopCalls = 0;
  int hydrateCalls = 0;
  Object? startError;
  void Function(int exitCode)? _onExit;
  ZapretRuntimeSession? _activeSession;
  ZapretSettings? lastStartedSettings;
  final List<ZapretSettings> startedSettings = <ZapretSettings>[];
  final ZapretRuntimeSession sessionTemplate = ZapretRuntimeSession(
    executablePath: r'E:\Tools\zapret2\winws2.exe',
    workingDirectory: r'E:\Tools\zapret2',
    processId: 4242,
    startedAt: DateTime(2026, 4, 7, 10),
    arguments: const ['--debug=1'],
    commandPreview: 'preview',
  );

  @override
  List<String> get logs => const ['[инфо] ready'];

  @override
  ZapretRuntimeSession? get session => _activeSession;

  @override
  Future<ZapretSettings> hydrateSettings(ZapretSettings settings) async {
    hydrateCalls += 1;
    if (settings.hasInstallDirectory) {
      return settings;
    }
    return settings.copyWith(installDirectory: r'E:\Bundled\zapret2');
  }

  @override
  ZapretLaunchConfiguration buildPreview(ZapretSettings settings) {
    return const ZapretLaunchConfiguration(
      workingDirectory: r'E:\Tools\zapret2',
      arguments: ['--debug=1'],
      requiredFiles: [],
      preview: 'preview',
      summary: 'Рекомендуемый: preview',
    );
  }

  @override
  Future<ZapretRuntimeSession> start({
    required ZapretSettings settings,
    required void Function(int exitCode) onExit,
    bool preserveLogs = false,
  }) async {
    startCalls += 1;
    _onExit = onExit;
    lastStartedSettings = settings;
    startedSettings.add(settings);
    if (startError != null) {
      throw startError!;
    }
    _activeSession = sessionTemplate;
    return sessionTemplate;
  }

  void completeExit(int exitCode) {
    _activeSession = null;
    _onExit?.call(exitCode);
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
    _activeSession = null;
  }
}

typedef _ProbeReportBuilder =
    ZapretProbeReport Function(
      List<ZapretProbeTarget> targets,
      ZapretSettings settings,
    );

class _FakeZapretProbeService extends ZapretProbeService {
  _FakeZapretProbeService({
    required this.currentSettings,
    required this.buildReport,
  });

  final ZapretSettings Function() currentSettings;
  final _ProbeReportBuilder buildReport;

  @override
  Future<ZapretProbeReport> runProbes({
    List<ZapretProbeTarget>? targets,
    void Function(String line)? onLog,
  }) async {
    final probeTargets = List<ZapretProbeTarget>.unmodifiable(
      targets ?? ZapretProbeService.defaultTargets,
    );
    final report = buildReport(probeTargets, currentSettings());
    for (final result in report.results) {
      onLog?.call(result.summary);
    }
    return report;
  }
}

class _FakeWindowsElevationService implements WindowsElevationService {
  _FakeWindowsElevationService({required this.elevated});

  final bool elevated;
  int relaunchCallCount = 0;
  PendingElevatedLaunchAction? lastAction;

  @override
  Future<bool> isElevated() async {
    return elevated;
  }

  @override
  Future<void> relaunchAsAdministrator({
    required PendingElevatedLaunchAction action,
  }) async {
    relaunchCallCount += 1;
    lastAction = action;
  }
}
