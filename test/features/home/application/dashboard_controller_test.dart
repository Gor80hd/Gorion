import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/auto_select/data/auto_select_preconnect_service.dart';
import 'package:gorion_clean/features/auto_select/data/auto_select_settings_repository.dart';
import 'package:gorion_clean/features/auto_select/data/auto_selector_service.dart';
import 'package:gorion_clean/features/auto_select/model/auto_select_state.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/profiles/data/profile_repository.dart';
import 'package:gorion_clean/features/profiles/model/profile_models.dart';
import 'package:gorion_clean/features/runtime/data/clash_api_client.dart';
import 'package:gorion_clean/features/runtime/data/singbox_runtime_service.dart';
import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';

final _createdAt = DateTime(2026, 4, 3, 12);
const _session = RuntimeSession(
  profileId: 'profile-1',
  mode: RuntimeMode.mixed,
  binaryPath: 'sing-box.exe',
  configPath: 'config.json',
  controllerPort: 9090,
  mixedPort: 2080,
  secret: 'secret',
  manualSelectorTag: 'gorion-manual',
  autoGroupTag: 'gorion-auto',
);
final _profile = ProxyProfile(
  id: 'profile-1',
  name: 'Profile 1',
  subscriptionUrl: 'https://example.com/sub',
  templateFileName: 'profile-1.json',
  createdAt: _createdAt,
  updatedAt: _createdAt,
  servers: [
    ServerEntry(
      tag: 'server-a',
      displayName: 'Server A',
      type: 'vless',
      host: 'a.example.com',
      port: 443,
    ),
    ServerEntry(
      tag: 'server-b',
      displayName: 'Server B',
      type: 'vless',
      host: 'b.example.com',
      port: 443,
    ),
  ],
  lastSelectedServerTag: autoSelectServerTag,
  lastAutoSelectedServerTag: 'server-a',
);
final _storage = StoredProfilesState(
  activeProfileId: 'profile-1',
  profiles: [_profile],
);
final _manualProfile = ProxyProfile(
  id: 'profile-1',
  name: 'Profile 1',
  subscriptionUrl: 'https://example.com/sub',
  templateFileName: 'profile-1.json',
  createdAt: _createdAt,
  updatedAt: _createdAt,
  servers: [
    ServerEntry(
      tag: 'server-a',
      displayName: 'Server A',
      type: 'vless',
      host: 'a.example.com',
      port: 443,
    ),
    ServerEntry(
      tag: 'server-b',
      displayName: 'Server B',
      type: 'vless',
      host: 'b.example.com',
      port: 443,
    ),
  ],
  lastSelectedServerTag: 'server-a',
  lastAutoSelectedServerTag: 'server-a',
);
final _manualStorage = StoredProfilesState(
  activeProfileId: 'profile-1',
  profiles: [_manualProfile],
);
const _keepCurrentOutcome = AutoSelectOutcome(
  selectedServerTag: 'server-a',
  previousServerTag: 'server-a',
  delayByTag: {'server-a': 50, 'server-b': 120},
  probes: [],
  summary:
      'Current server server-a stayed selected after the latest proxy probe check.',
  didSwitch: false,
  hasReachableCandidate: true,
);

void main() {
  group('DashboardController', () {
    test(
      'immediate maintenance arms the next pass only after the current pass finishes',
      () async {
        final timerFactory = _ControlledTimerFactory();
        final firstPass = Completer<AutoSelectOutcome>();
        final autoSelectorService = _ScriptedAutoSelectorService(
          maintainResponses: [
            firstPass.future,
            Future<AutoSelectOutcome>.value(_keepCurrentOutcome),
          ],
        );
        final settingsRepository = _FakeAutoSelectSettingsRepository();
        final controller = DashboardController(
          repository: _FakeProfileRepository(initialStorage: _storage),
          runtimeService: _FakeRuntimeService(),
          autoSelectSettingsRepository: settingsRepository,
          autoSelectPreconnectService: AutoSelectPreconnectService(
            settingsRepository: settingsRepository,
          ),
          autoSelectorService: autoSelectorService,
          autoSelectionInterval: const Duration(minutes: 1),
          createTimer: timerFactory.create,
          initialState: DashboardState(
            bootstrapping: false,
            runtimeMode: RuntimeMode.mixed,
            autoSelectSettings: AutoSelectSettings(enabled: true),
            storage: _storage,
            connectionStage: ConnectionStage.connected,
            runtimeSession: _session,
            selectedServerTag: autoSelectServerTag,
            activeServerTag: 'server-a',
          ),
          loadOnInit: false,
        );
        addTearDown(controller.dispose);

        await controller.selectServer(autoSelectServerTag);
        await _flushAsync();

        expect(autoSelectorService.maintainCallCount, 1);
        expect(timerFactory.activeTimers, isEmpty);

        firstPass.complete(_keepCurrentOutcome);
        await _flushAsync();

        expect(autoSelectorService.maintainCallCount, 1);
        expect(timerFactory.activeTimers, hasLength(1));
        expect(
          timerFactory.activeTimers.single.duration,
          const Duration(minutes: 1),
        );

        timerFactory.activeTimers.single.fire();
        await _flushAsync();

        expect(autoSelectorService.maintainCallCount, 2);
      },
    );

    test(
      'connect cancels a manual connection when full internet access stays partial',
      () async {
        final runtimeService = _FakeRuntimeService(startSession: _session);
        final autoSelectorService = _ScriptedAutoSelectorService(
          verifyResponses: [
            Future<AutoSelectProbeResult>.value(
              const AutoSelectProbeResult(
                serverTag: 'server-a',
                urlTestDelay: 48,
                domainProbeOk: true,
                ipProbeOk: false,
                throughputBytesPerSecond: 64 * 1024,
              ),
            ),
          ],
        );
        final settingsRepository = _FakeAutoSelectSettingsRepository();
        final controller = DashboardController(
          repository: _FakeProfileRepository(initialStorage: _manualStorage),
          runtimeService: runtimeService,
          autoSelectSettingsRepository: settingsRepository,
          autoSelectPreconnectService: _FakeAutoSelectPreconnectService(),
          autoSelectorService: autoSelectorService,
          clashApiClientFactory: (_) => _FakeClashApiClient(
            snapshot: const ClashApiSnapshot(
              selectedTag: 'server-a',
              delayByTag: {'server-a': 48},
            ),
            delays: const {'server-a': 48},
          ),
          initialState: DashboardState(
            bootstrapping: false,
            runtimeMode: RuntimeMode.mixed,
            autoSelectSettings: AutoSelectSettings(enabled: false),
            storage: _manualStorage,
            selectedServerTag: 'server-a',
            activeServerTag: 'server-a',
          ),
          loadOnInit: false,
        );
        addTearDown(controller.dispose);

        await controller.connect();

        expect(runtimeService.startCallCount, 1);
        expect(runtimeService.stopCallCount, 1);
        expect(autoSelectorService.verifyCallCount, 1);
        expect(controller.state.connectionStage, ConnectionStage.disconnected);
        expect(controller.state.runtimeSession, isNull);
        expect(
          controller.state.errorMessage,
          'Подключение не удалось: Server A недоступен.',
        );
        expect(controller.state.activeServerTag, 'server-a');
      },
    );

    test(
      'connect cancels an auto-selected connection when no fully healthy server is confirmed',
      () async {
        final runtimeService = _FakeRuntimeService(startSession: _session);
        final autoSelectorService = _ScriptedAutoSelectorService(
          maintainResponses: [
            Future<AutoSelectOutcome>.value(
              const AutoSelectOutcome(
                selectedServerTag: 'server-b',
                previousServerTag: 'server-a',
                delayByTag: {'server-a': 44, 'server-b': 62},
                probes: [
                  AutoSelectProbeResult(
                    serverTag: 'server-a',
                    urlTestDelay: 44,
                    domainProbeOk: false,
                    ipProbeOk: false,
                    throughputBytesPerSecond: 0,
                  ),
                  AutoSelectProbeResult(
                    serverTag: 'server-b',
                    urlTestDelay: 62,
                    domainProbeOk: true,
                    ipProbeOk: false,
                    throughputBytesPerSecond: 64 * 1024,
                  ),
                ],
                summary:
                    'Auto-selector switched from server-a to server-b after confirming better end-to-end health and latency.',
                didSwitch: true,
                hasReachableCandidate: true,
              ),
            ),
          ],
        );
        final settingsRepository = _FakeAutoSelectSettingsRepository();
        final controller = DashboardController(
          repository: _FakeProfileRepository(initialStorage: _storage),
          runtimeService: runtimeService,
          autoSelectSettingsRepository: settingsRepository,
          autoSelectPreconnectService: _FakeAutoSelectPreconnectService(),
          autoSelectorService: autoSelectorService,
          clashApiClientFactory: (_) => _FakeClashApiClient(
            snapshot: const ClashApiSnapshot(
              selectedTag: 'server-a',
              delayByTag: {'server-a': 44, 'server-b': 62},
            ),
            delays: const {'server-a': 44, 'server-b': 62},
          ),
          initialState: DashboardState(
            bootstrapping: false,
            runtimeMode: RuntimeMode.mixed,
            autoSelectSettings: AutoSelectSettings(enabled: true),
            storage: _storage,
            selectedServerTag: autoSelectServerTag,
            activeServerTag: 'server-a',
          ),
          loadOnInit: false,
        );
        addTearDown(controller.dispose);

        await controller.connect();

        expect(runtimeService.startCallCount, 1);
        expect(runtimeService.stopCallCount, 1);
        expect(autoSelectorService.maintainCallCount, 1);
        expect(controller.state.connectionStage, ConnectionStage.disconnected);
        expect(controller.state.runtimeSession, isNull);
        expect(
          controller.state.errorMessage,
          'Подключение не удалось: Server B недоступен.',
        );
        expect(controller.state.activeServerTag, 'server-b');
        expect(controller.state.autoSelectResults, hasLength(2));
        expect(settingsRepository.recentAutoSelectedServerCalls, isEmpty);
        expect(settingsRepository.recentSuccessfulAutoConnectCalls, isEmpty);
      },
    );

    test(
      'connection error uses the normalized server name with a flag',
      () async {
        final flaggedProfile = _manualProfile.copyWith(
          servers: const [
            ServerEntry(
              tag: 'server-a',
              displayName: '[NO] Норвегия, Осло',
              type: 'vless',
              host: 'oslo.example.com',
              port: 443,
            ),
          ],
        );
        final flaggedStorage = StoredProfilesState(
          activeProfileId: flaggedProfile.id,
          profiles: [flaggedProfile],
        );
        final runtimeService = _FakeRuntimeService(startSession: _session);
        final autoSelectorService = _ScriptedAutoSelectorService(
          verifyResponses: [
            Future<AutoSelectProbeResult>.value(
              const AutoSelectProbeResult(
                serverTag: 'server-a',
                urlTestDelay: 48,
                domainProbeOk: true,
                ipProbeOk: false,
                throughputBytesPerSecond: 64 * 1024,
              ),
            ),
          ],
        );
        final controller = DashboardController(
          repository: _FakeProfileRepository(initialStorage: flaggedStorage),
          runtimeService: runtimeService,
          autoSelectSettingsRepository: _FakeAutoSelectSettingsRepository(),
          autoSelectPreconnectService: _FakeAutoSelectPreconnectService(),
          autoSelectorService: autoSelectorService,
          clashApiClientFactory: (_) => _FakeClashApiClient(
            snapshot: const ClashApiSnapshot(
              selectedTag: 'server-a',
              delayByTag: {'server-a': 48},
            ),
            delays: const {'server-a': 48},
          ),
          initialState: DashboardState(
            bootstrapping: false,
            runtimeMode: RuntimeMode.mixed,
            autoSelectSettings: AutoSelectSettings(enabled: false),
            storage: flaggedStorage,
            selectedServerTag: 'server-a',
            activeServerTag: 'server-a',
          ),
          loadOnInit: false,
        );
        addTearDown(controller.dispose);

        await controller.connect();

        expect(
          controller.state.errorMessage,
          'Подключение не удалось: 🇳🇴 Норвегия, Осло недоступен.',
        );
      },
    );
  });
}

Future<void> _flushAsync() async {
  for (var index = 0; index < 4; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _FakeProfileRepository extends ProfileRepository {
  _FakeProfileRepository({required StoredProfilesState initialStorage})
    : _storage = initialStorage;

  StoredProfilesState _storage;

  @override
  Future<StoredProfilesState> loadState() async => _storage;

  @override
  Future<String> loadTemplateConfig(ProxyProfile profile) async => '{}';

  @override
  Future<StoredProfilesState> updateSelectedServer(
    String profileId,
    String serverTag,
  ) async {
    _storage = _storage.copyWith(
      profiles: [
        for (final profile in _storage.profiles)
          if (profile.id == profileId)
            profile.copyWith(lastSelectedServerTag: serverTag)
          else
            profile,
      ],
    );
    return _storage;
  }

  @override
  Future<StoredProfilesState> updateAutoSelectedServer(
    String profileId,
    String serverTag,
  ) async {
    _storage = _storage.copyWith(
      profiles: [
        for (final profile in _storage.profiles)
          if (profile.id == profileId)
            profile.copyWith(lastAutoSelectedServerTag: serverTag)
          else
            profile,
      ],
    );
    return _storage;
  }
}

class _FakeAutoSelectSettingsRepository extends AutoSelectSettingsRepository {
  final List<String> recentAutoSelectedServerCalls = <String>[];
  final List<String> recentSuccessfulAutoConnectCalls = <String>[];

  @override
  Future<StoredAutoSelectState> clearExpiredCaches() async {
    return const StoredAutoSelectState(
      settings: AutoSelectSettings(enabled: true),
    );
  }

  @override
  Future<StoredAutoSelectState> setRecentAutoSelectedServer({
    required String profileId,
    required String serverTag,
    Duration ttl = defaultRecentAutoSelectedServerTtl,
  }) async {
    recentAutoSelectedServerCalls.add('$profileId::$serverTag');
    return const StoredAutoSelectState(
      settings: AutoSelectSettings(enabled: true),
    );
  }

  @override
  Future<StoredAutoSelectState> setRecentSuccessfulAutoConnect({
    required String profileId,
    required String serverTag,
    Duration ttl = defaultRecentSuccessfulAutoConnectTtl,
  }) async {
    recentSuccessfulAutoConnectCalls.add('$profileId::$serverTag');
    return const StoredAutoSelectState(
      settings: AutoSelectSettings(enabled: true),
    );
  }
}

class _FakeRuntimeService extends SingboxRuntimeService {
  _FakeRuntimeService({RuntimeSession? startSession})
    : _startSession = startSession ?? _session;

  final RuntimeSession _startSession;
  int startCallCount = 0;
  int stopCallCount = 0;

  @override
  List<String> get logs => const <String>[];

  @override
  Future<RuntimeSession> start({
    required String profileId,
    required String templateConfig,
    required String urlTestUrl,
    required RuntimeMode mode,
    String? selectedServerTag,
  }) async {
    startCallCount += 1;
    return _startSession;
  }

  @override
  Future<void> stop() async {
    stopCallCount += 1;
  }
}

class _ScriptedAutoSelectorService extends AutoSelectorService {
  _ScriptedAutoSelectorService({
    List<Future<AutoSelectOutcome>>? maintainResponses,
    List<Future<AutoSelectProbeResult>>? verifyResponses,
  }) : _maintainResponses = maintainResponses ?? <Future<AutoSelectOutcome>>[],
       _verifyResponses = verifyResponses ?? <Future<AutoSelectProbeResult>>[];

  final List<Future<AutoSelectOutcome>> _maintainResponses;
  final List<Future<AutoSelectProbeResult>> _verifyResponses;
  int maintainCallCount = 0;
  int verifyCallCount = 0;

  @override
  Future<AutoSelectOutcome> maintainBestServer({
    required RuntimeSession session,
    required List<ServerEntry> servers,
    required String domainProbeUrl,
    String ipProbeUrl = 'http://1.1.1.1',
    bool allowSwitchDuringCooldown = false,
    AutoSelectProgressReporter? onProgress,
  }) {
    maintainCallCount += 1;
    return _maintainResponses.removeAt(0);
  }

  @override
  Future<AutoSelectProbeResult> verifyCurrentServer({
    required RuntimeSession session,
    required ServerEntry server,
    required String domainProbeUrl,
    String ipProbeUrl = 'http://1.1.1.1',
    int? urlTestDelay,
    bool ensureSelected = false,
  }) {
    verifyCallCount += 1;
    return _verifyResponses.removeAt(0);
  }
}

class _FakeAutoSelectPreconnectService extends AutoSelectPreconnectService {
  _FakeAutoSelectPreconnectService({PreparedAutoConnectSelection? prepared})
    : _prepared = prepared,
      super(settingsRepository: _FakeAutoSelectSettingsRepository());

  final PreparedAutoConnectSelection? _prepared;

  @override
  Future<PreparedAutoConnectSelection?> prepare({
    required ProxyProfile profile,
    required String templateConfig,
    AutoSelectProgressReporter? onProgress,
  }) async {
    return _prepared;
  }
}

class _FakeClashApiClient extends ClashApiClient {
  _FakeClashApiClient({required this.snapshot, required this.delays})
    : super(baseUrl: 'http://127.0.0.1:9090', secret: 'secret');

  final ClashApiSnapshot snapshot;
  final Map<String, int> delays;

  @override
  Future<ClashApiSnapshot> fetchSnapshot({required String selectorTag}) async {
    return snapshot;
  }

  @override
  Future<Map<String, int>> measureGroupDelay({
    required String groupTag,
    required String testUrl,
    int timeoutMs = 8000,
  }) async {
    return delays;
  }
}

class _ControlledTimerFactory {
  final List<_ControlledTimer> _timers = <_ControlledTimer>[];

  Timer create(Duration duration, void Function() callback) {
    final timer = _ControlledTimer(duration, callback);
    _timers.add(timer);
    return timer;
  }

  List<_ControlledTimer> get activeTimers {
    return _timers.where((timer) => timer.isActive).toList(growable: false);
  }
}

class _ControlledTimer implements Timer {
  _ControlledTimer(this.duration, this._callback);

  final Duration duration;
  final void Function() _callback;
  bool _active = true;
  int _tick = 0;

  void fire() {
    if (!_active) {
      return;
    }

    _active = false;
    _tick = 1;
    _callback();
  }

  @override
  void cancel() {
    _active = false;
  }

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;
}
