import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/core/windows/elevation_relaunch_prompt_service.dart';
import 'package:gorion_clean/core/windows/windows_elevation_service.dart';
import 'package:gorion_clean/features/zapret/application/zapret_controller.dart';
import 'package:gorion_clean/features/zapret/data/zapret_config_test_service.dart';
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
      expect(runtimeService.lastStartedSettings?.customProfile, isNull);
      expect(controller.state.settings.customProfile, isNull);
      expect(controller.state.generatedConfigSummary, 'general');
    },
  );

  test('shows a path error when no zapret directory is saved', () async {
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
    expect(controller.state.settings.installDirectory, isEmpty);
    expect(runtimeService.startCalls, 0);
    expect(controller.state.stage, ZapretStage.stopped);
    expect(
      controller.state.errorMessage,
      'Сначала укажите каталог установки zapret.',
    );
  });

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

  test('cancels zapret start when relaunch warning is declined', () async {
    if (!Platform.isWindows) {
      return;
    }

    final runtimeService = _FakeZapretRuntimeService();
    final elevationService = _FakeWindowsElevationService(elevated: false);
    final controller = ZapretController(
      repository: _FakeZapretSettingsRepository(),
      runtimeService: runtimeService,
      elevationService: elevationService,
      elevationPromptService: const _FakeElevationRelaunchPromptService(
        confirmed: false,
      ),
      initialState: const ZapretState(
        bootstrapping: false,
        settings: ZapretSettings(installDirectory: r'E:\Tools\zapret2'),
      ),
      loadOnInit: false,
    );
    addTearDown(controller.dispose);

    await controller.start();

    expect(elevationService.relaunchCallCount, 0);
    expect(runtimeService.startCalls, 0);
    expect(controller.state.statusMessage, 'Запуск zapret отменён.');
  });

  test('shows a friendly message when winws requires elevation', () async {
    final runtimeService = _FakeZapretRuntimeService()
      ..startError = ProcessException(
        'winws.exe',
        const ['--wf-tcp=80,443'],
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
      'Запуск winws требует прав администратора. Перезапустите Gorion от имени администратора и попробуйте снова.',
    );
  });

  test('explains invalid parameter exit code from winws', () async {
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
      'zapret отклонил параметры запуска (код 87 / ERROR_INVALID_PARAMETER). Значит, winws не принял один из аргументов текущего конфига.',
    );
  });

  test('explains DLL initialization failure exit code from winws', () async {
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
      'zapret не смог инициализироваться (код -1073741502 / 0xC0000142). Обычно это сбой инициализации DLL или процесса; сначала попробуйте запустить Gorion от имени администратора.',
    );
  });

  test('shutdownForAppExit stops the zapret runtime once', () async {
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

    await controller.shutdownForAppExit();

    expect(runtimeService.stopCalls, 1);
  });

  test('http config test auto-selects the best fully working config', () async {
    if (!Platform.isWindows) {
      return;
    }

    final runtimeService = _FakeZapretRuntimeService()
      ..availableProfiles = const [
        ZapretConfigOption(
          fileName: 'general.conf',
          path: r'E:\Tools\zapret2\profiles\general.conf',
        ),
        ZapretConfigOption(
          fileName: 'general (ALT10).conf',
          path: r'E:\Tools\zapret2\profiles\general (ALT10).conf',
        ),
      ];
    final configTestService = _FakeZapretConfigTestService(
      suite: ZapretConfigTestSuite(
        targets: const [
          ZapretProbeTarget(
            id: 'DiscordMain_http11',
            label: 'DiscordMain HTTP/1.1',
            kind: ZapretProbeKind.http11,
            address: 'https://discord.com',
          ),
          ZapretProbeTarget(
            id: 'DiscordMain_ping',
            label: 'DiscordMain Ping',
            kind: ZapretProbeKind.ping,
            address: 'discord.com',
            requiredForSuccess: false,
          ),
        ],
        targetsPath: r'E:\Tools\zapret2\files\targets.txt',
        results: const [
          ZapretConfigTestResult(
            config: ZapretConfigOption(
              fileName: 'general (ALT10).conf',
              path: r'E:\Tools\zapret2\profiles\general (ALT10).conf',
            ),
            report: ZapretProbeReport(
              results: [
                ZapretProbeResult(
                  target: ZapretProbeTarget(
                    id: 'DiscordMain_http11',
                    label: 'DiscordMain HTTP/1.1',
                    kind: ZapretProbeKind.http11,
                    address: 'https://discord.com',
                  ),
                  success: true,
                  latencyMs: 120,
                  details: 'HTTP 200',
                ),
                ZapretProbeResult(
                  target: ZapretProbeTarget(
                    id: 'DiscordMain_ping',
                    label: 'DiscordMain Ping',
                    kind: ZapretProbeKind.ping,
                    address: 'discord.com',
                    requiredForSuccess: false,
                  ),
                  success: true,
                  latencyMs: 45,
                  details: 'Ping 45 ms',
                ),
              ],
            ),
          ),
          ZapretConfigTestResult(
            config: ZapretConfigOption(
              fileName: 'general.conf',
              path: r'E:\Tools\zapret2\profiles\general.conf',
            ),
            report: ZapretProbeReport(
              results: [
                ZapretProbeResult(
                  target: ZapretProbeTarget(
                    id: 'DiscordMain_http11',
                    label: 'DiscordMain HTTP/1.1',
                    kind: ZapretProbeKind.http11,
                    address: 'https://discord.com',
                  ),
                  success: true,
                  latencyMs: 280,
                  details: 'HTTP 200',
                ),
                ZapretProbeResult(
                  target: ZapretProbeTarget(
                    id: 'DiscordMain_ping',
                    label: 'DiscordMain Ping',
                    kind: ZapretProbeKind.ping,
                    address: 'discord.com',
                    requiredForSuccess: false,
                  ),
                  success: false,
                  details: 'Ping timeout',
                ),
              ],
            ),
          ),
        ],
      ),
    );
    final repository = _FakeZapretSettingsRepository();
    final controller = ZapretController(
      repository: repository,
      runtimeService: runtimeService,
      configTestService: configTestService,
      elevationService: _FakeWindowsElevationService(elevated: true),
      initialState: const ZapretState(
        bootstrapping: false,
        settings: ZapretSettings(installDirectory: r'E:\Tools\zapret2'),
      ),
      loadOnInit: false,
    );
    addTearDown(controller.dispose);

    await controller.runHttpConfigTests();

    expect(
      controller.state.settings.effectiveConfigFileName,
      'general (ALT10).conf',
    );
    expect(
      controller.state.configTestSuite?.bestWorkingResult?.config.fileName,
      'general (ALT10).conf',
    );
    expect(controller.state.statusMessage, contains('Выбран автоматически'));
    expect(repository._stored.effectiveConfigFileName, 'general (ALT10).conf');
  });

  test('requests elevated relaunch before running config tests', () async {
    if (!Platform.isWindows) {
      return;
    }

    final runtimeService = _FakeZapretRuntimeService();
    final elevationService = _FakeWindowsElevationService(elevated: false);
    final controller = ZapretController(
      repository: _FakeZapretSettingsRepository(),
      runtimeService: runtimeService,
      configTestService: _FakeZapretConfigTestService(
        suite: const ZapretConfigTestSuite(
          targets: [],
          results: [],
          targetsPath: r'E:\Tools\zapret2\files\targets.txt',
        ),
      ),
      elevationService: elevationService,
      initialState: const ZapretState(
        bootstrapping: false,
        settings: ZapretSettings(installDirectory: r'E:\Tools\zapret2'),
      ),
      loadOnInit: false,
    );
    addTearDown(controller.dispose);

    await controller.runHttpConfigTests();

    expect(elevationService.relaunchCallCount, 1);
    expect(
      elevationService.lastAction,
      PendingElevatedLaunchAction.testZapretConfigs,
    );
    expect(controller.state.statusMessage, contains('тестирование конфигов'));
  });
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
  List<ZapretConfigOption> availableProfiles = const [
    ZapretConfigOption(
      fileName: 'general.conf',
      path: r'E:\Tools\zapret2\profiles\general.conf',
    ),
  ];
  final ZapretRuntimeSession sessionTemplate = ZapretRuntimeSession(
    executablePath: r'E:\Tools\zapret2\bin\winws.exe',
    workingDirectory: r'E:\Tools\zapret2\bin',
    processId: 4242,
    startedAt: DateTime(2026, 4, 7, 10),
    arguments: const ['--wf-tcp=80,443,12'],
    commandPreview: 'preview',
  );

  @override
  List<String> get logs => const ['[инфо] ready'];

  @override
  ZapretRuntimeSession? get session => _activeSession;

  @override
  Future<ZapretSettings> hydrateSettings(ZapretSettings settings) async {
    hydrateCalls += 1;
    return settings;
  }

  @override
  ZapretLaunchConfiguration buildPreview(ZapretSettings settings) {
    return const ZapretLaunchConfiguration(
      executablePath: r'E:\Tools\zapret2\bin\winws.exe',
      workingDirectory: r'E:\Tools\zapret2\bin',
      arguments: ['--wf-tcp=80,443,12'],
      requiredFiles: [],
      preview: 'preview',
      summary: 'general',
    );
  }

  @override
  List<ZapretConfigOption> listAvailableProfiles(String installDirectory) {
    return availableProfiles;
  }

  @override
  String resolveSelectedConfigFileName(
    String installDirectory,
    String preferredFileName,
  ) {
    return preferredFileName.isEmpty ? 'general.conf' : preferredFileName;
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

class _FakeZapretConfigTestService extends ZapretConfigTestService {
  _FakeZapretConfigTestService({required this.suite})
    : super(runtimeService: ZapretRuntimeService());

  final ZapretConfigTestSuite suite;

  @override
  Future<ZapretConfigTestSuite> runHttpSuite({
    required ZapretSettings settings,
    FutureOr<void> Function(
      int completed,
      int total,
      ZapretConfigOption config,
    )?
    onProgress,
  }) async {
    for (var index = 0; index < suite.results.length; index += 1) {
      if (onProgress != null) {
        await onProgress(
          index,
          suite.results.length,
          suite.results[index].config,
        );
      }
    }
    return suite;
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

class _FakeElevationRelaunchPromptService
    implements ElevationRelaunchPromptService {
  const _FakeElevationRelaunchPromptService({required this.confirmed});

  final bool confirmed;

  @override
  Future<bool> confirmRelaunch({
    required PendingElevatedLaunchAction action,
  }) async {
    return confirmed;
  }
}
