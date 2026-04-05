import 'dart:async';
import 'dart:convert';

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
const _autoSelectTemplateConfig = '''
{
  "outbounds": [
    {
      "tag": "server-a",
      "type": "vless",
      "server": "a.example.com",
      "server_port": 443
    },
    {
      "tag": "server-b",
      "type": "vless",
      "server": "b.example.com",
      "server_port": 443
    }
  ]
}
''';
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
        final settingsRepository = _FakeAutoSelectSettingsRepository(
          initialState: const StoredAutoSelectState(
            settings: AutoSelectSettings(enabled: false),
          ),
        );
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
            autoSelectSettings: const AutoSelectSettings(enabled: false),
            storage: _storage,
            connectionStage: ConnectionStage.connected,
            runtimeSession: _session,
            selectedServerTag: autoSelectServerTag,
            activeServerTag: 'server-a',
          ),
          loadOnInit: false,
        );
        addTearDown(controller.dispose);

        await controller.setAutoSelectEnabled(true);
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
      'selecting auto server while connected does not run best-server immediately',
      () async {
        final timerFactory = _ControlledTimerFactory();
        final autoSelectorService = _ScriptedAutoSelectorService(
          maintainResponses: [
            Future<AutoSelectOutcome>.value(_keepCurrentOutcome),
          ],
        );
        final controller = DashboardController(
          repository: _FakeProfileRepository(initialStorage: _storage),
          runtimeService: _FakeRuntimeService(),
          autoSelectSettingsRepository: _FakeAutoSelectSettingsRepository(),
          autoSelectPreconnectService: _FakeAutoSelectPreconnectService(),
          autoSelectorService: autoSelectorService,
          autoSelectionInterval: const Duration(minutes: 1),
          createTimer: timerFactory.create,
          initialState: DashboardState(
            bootstrapping: false,
            runtimeMode: RuntimeMode.mixed,
            autoSelectSettings: const AutoSelectSettings(enabled: true),
            storage: _manualStorage,
            connectionStage: ConnectionStage.connected,
            runtimeSession: _session,
            selectedServerTag: 'server-a',
            activeServerTag: 'server-a',
          ),
          loadOnInit: false,
        );
        addTearDown(controller.dispose);

        await controller.selectServer(autoSelectServerTag);
        await _flushAsync();

        expect(autoSelectorService.maintainCallCount, 0);
        expect(timerFactory.activeTimers, hasLength(1));
        expect(
          controller.state.statusMessage,
          'Auto server selected. The next automatic pass will choose and maintain a server.',
        );

        timerFactory.activeTimers.single.fire();
        await _flushAsync();

        expect(autoSelectorService.maintainCallCount, 1);
      },
    );

    test(
      'runAutoSelect refreshes the quick reconnect cache to the live selected server',
      () async {
        final cachedAutoConnect = RecentSuccessfulAutoConnect(
          profileId: _profile.id,
          tag: 'server-a',
          until: DateTime.now().add(const Duration(minutes: 1)),
        );
        final settingsRepository = _FakeAutoSelectSettingsRepository(
          initialState: StoredAutoSelectState(
            settings: const AutoSelectSettings(enabled: true),
            recentSuccessfulAutoConnect: cachedAutoConnect,
          ),
        );
        final autoSelectorService = _ScriptedAutoSelectorService(
          selectResponses: [
            Future<AutoSelectOutcome>.value(
              const AutoSelectOutcome(
                selectedServerTag: 'server-b',
                previousServerTag: 'server-a',
                delayByTag: {'server-a': 90, 'server-b': 42},
                probes: [
                  AutoSelectProbeResult(
                    serverTag: 'server-b',
                    urlTestDelay: 42,
                    domainProbeOk: true,
                    ipProbeOk: true,
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
        final controller = DashboardController(
          repository: _FakeProfileRepository(initialStorage: _storage),
          runtimeService: _FakeRuntimeService(),
          autoSelectSettingsRepository: settingsRepository,
          autoSelectPreconnectService: _FakeAutoSelectPreconnectService(),
          autoSelectorService: autoSelectorService,
          initialState: DashboardState(
            bootstrapping: false,
            runtimeMode: RuntimeMode.mixed,
            autoSelectSettings: const AutoSelectSettings(enabled: true),
            storage: _storage,
            connectionStage: ConnectionStage.connected,
            runtimeSession: _session,
            selectedServerTag: autoSelectServerTag,
            activeServerTag: 'server-a',
            recentSuccessfulAutoConnect: cachedAutoConnect,
          ),
          loadOnInit: false,
        );
        addTearDown(controller.dispose);

        await controller.runAutoSelect();

        expect(autoSelectorService.selectCallCount, 1);
        expect(controller.state.activeServerTag, 'server-b');
        expect(settingsRepository.recentAutoSelectedServerCalls, [
          'profile-1::server-b',
        ]);
        expect(settingsRepository.recentSuccessfulAutoConnectCalls, [
          'profile-1::server-b',
        ]);
        expect(controller.state.recentSuccessfulAutoConnect?.tag, 'server-b');
      },
    );

    test(
      'automatic maintenance refreshes the quick reconnect cache to the maintained server',
      () async {
        final cachedAutoConnect = RecentSuccessfulAutoConnect(
          profileId: _profile.id,
          tag: 'server-a',
          until: DateTime.now().add(const Duration(minutes: 1)),
        );
        final timerFactory = _ControlledTimerFactory();
        final settingsRepository = _FakeAutoSelectSettingsRepository(
          initialState: StoredAutoSelectState(
            settings: const AutoSelectSettings(enabled: false),
            recentSuccessfulAutoConnect: cachedAutoConnect,
          ),
        );
        final autoSelectorService = _ScriptedAutoSelectorService(
          maintainResponses: [
            Future<AutoSelectOutcome>.value(
              const AutoSelectOutcome(
                selectedServerTag: 'server-b',
                previousServerTag: 'server-a',
                delayByTag: {'server-a': 90, 'server-b': 42},
                probes: [
                  AutoSelectProbeResult(
                    serverTag: 'server-b',
                    urlTestDelay: 42,
                    domainProbeOk: true,
                    ipProbeOk: true,
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
            autoSelectSettings: const AutoSelectSettings(enabled: false),
            storage: _storage,
            connectionStage: ConnectionStage.connected,
            runtimeSession: _session,
            selectedServerTag: autoSelectServerTag,
            activeServerTag: 'server-a',
            recentSuccessfulAutoConnect: cachedAutoConnect,
          ),
          loadOnInit: false,
        );
        addTearDown(controller.dispose);

        await controller.setAutoSelectEnabled(true);
        await _flushAsync();

        expect(autoSelectorService.maintainCallCount, 1);
        expect(controller.state.activeServerTag, 'server-b');
        expect(settingsRepository.recentAutoSelectedServerCalls, [
          'profile-1::server-b',
        ]);
        expect(settingsRepository.recentSuccessfulAutoConnectCalls, [
          'profile-1::server-b',
        ]);
        expect(controller.state.recentSuccessfulAutoConnect?.tag, 'server-b');
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
      'connect skips immediate maintenance after a successful pre-connect selection',
      () async {
        final runtimeService = _FakeRuntimeService(startSession: _session);
        final autoSelectorService = _ScriptedAutoSelectorService();
        final settingsRepository = _FakeAutoSelectSettingsRepository();
        final controller = DashboardController(
          repository: _FakeProfileRepository(initialStorage: _storage),
          runtimeService: runtimeService,
          autoSelectSettingsRepository: settingsRepository,
          autoSelectPreconnectService: _FakeAutoSelectPreconnectService(
            prepared: const PreparedAutoConnectSelection(
              selectedServerTag: 'server-b',
              delayByTag: {'server-b': 62},
              probes: [
                AutoSelectProbeResult(
                  serverTag: 'server-b',
                  urlTestDelay: 62,
                  domainProbeOk: true,
                  ipProbeOk: false,
                  throughputBytesPerSecond: 64 * 1024,
                ),
              ],
              summary:
                  'Auto-selector chose server-b before connect (62 ms, 64 KB/s).',
              reusedRecentSuccessfulSelection: false,
              requiresImmediatePostConnectCheck: false,
            ),
          ),
          autoSelectorService: autoSelectorService,
          clashApiClientFactory: (_) => _FakeClashApiClient(
            snapshot: const ClashApiSnapshot(
              selectedTag: 'server-b',
              delayByTag: {'server-b': 62},
            ),
            delays: const {'server-b': 62},
          ),
          initialState: DashboardState(
            bootstrapping: false,
            runtimeMode: RuntimeMode.mixed,
            autoSelectSettings: const AutoSelectSettings(enabled: true),
            storage: _storage,
            selectedServerTag: autoSelectServerTag,
            activeServerTag: 'server-a',
          ),
          loadOnInit: false,
        );
        addTearDown(controller.dispose);

        await controller.connect();

        expect(runtimeService.startCallCount, 1);
        expect(runtimeService.stopCallCount, 0);
        expect(autoSelectorService.maintainCallCount, 0);
        expect(autoSelectorService.verifyCallCount, 0);
        expect(controller.state.connectionStage, ConnectionStage.connected);
        expect(controller.state.runtimeSession, same(_session));
        expect(controller.state.connectedAt, isNotNull);
        expect(controller.state.activeServerTag, 'server-b');
        expect(controller.state.autoSelectResults, hasLength(1));
        expect(controller.state.lastBestServerCheckAt, isNotNull);
        expect(controller.state.errorMessage, isNull);
        expect(settingsRepository.recentAutoSelectedServerCalls, [
          'profile-1::server-b',
        ]);
        expect(settingsRepository.recentSuccessfulAutoConnectCalls, [
          'profile-1::server-b',
        ]);
      },
    );

    test(
      'connect immediately rechecks a best-effort pre-connect selection',
      () async {
        final runtimeService = _FakeRuntimeService(startSession: _session);
        final autoSelectorService = _ScriptedAutoSelectorService(
          maintainResponses: [
            Future<AutoSelectOutcome>.value(
              const AutoSelectOutcome(
                selectedServerTag: 'server-b',
                previousServerTag: 'server-b',
                delayByTag: {'server-b': 62},
                probes: [
                  AutoSelectProbeResult(
                    serverTag: 'server-b',
                    urlTestDelay: 62,
                    domainProbeOk: true,
                    ipProbeOk: false,
                    throughputBytesPerSecond: 64 * 1024,
                  ),
                ],
                summary:
                    'Current server server-b stayed selected after the latest proxy probe check.',
                didSwitch: false,
                hasReachableCandidate: true,
              ),
            ),
          ],
        );
        final controller = DashboardController(
          repository: _FakeProfileRepository(initialStorage: _storage),
          runtimeService: runtimeService,
          autoSelectSettingsRepository: _FakeAutoSelectSettingsRepository(),
          autoSelectPreconnectService: _FakeAutoSelectPreconnectService(
            prepared: const PreparedAutoConnectSelection(
              selectedServerTag: 'server-b',
              delayByTag: {'server-b': 62},
              probes: [
                AutoSelectProbeResult(
                  serverTag: 'server-b',
                  urlTestDelay: 62,
                  domainProbeOk: true,
                  ipProbeOk: false,
                  throughputBytesPerSecond: 64 * 1024,
                ),
              ],
              summary:
                  'No fully confirmed server passed the detached pre-connect probe. Using best-effort candidate server-b and rechecking immediately after connect.',
              reusedRecentSuccessfulSelection: false,
              requiresImmediatePostConnectCheck: true,
            ),
          ),
          autoSelectorService: autoSelectorService,
          clashApiClientFactory: (_) => _FakeClashApiClient(
            snapshot: const ClashApiSnapshot(
              selectedTag: 'server-b',
              delayByTag: {'server-b': 62},
            ),
            delays: const {'server-b': 62},
          ),
          initialState: DashboardState(
            bootstrapping: false,
            runtimeMode: RuntimeMode.mixed,
            autoSelectSettings: const AutoSelectSettings(enabled: true),
            storage: _storage,
            selectedServerTag: autoSelectServerTag,
            activeServerTag: 'server-a',
          ),
          loadOnInit: false,
        );
        addTearDown(controller.dispose);

        await controller.connect();

        expect(autoSelectorService.maintainCallCount, 1);
        expect(runtimeService.stopCallCount, 1);
        expect(controller.state.connectionStage, ConnectionStage.disconnected);
        expect(
          controller.state.errorMessage,
          'Подключение не удалось: Server B недоступен.',
        );
      },
    );

    test(
      'recent successful cache uses lightweight verification and stays reusable across a quick reconnect',
      () async {
        final recentSuccessfulState = StoredAutoSelectState(
          settings: const AutoSelectSettings(enabled: true),
          recentSuccessfulAutoConnect: RecentSuccessfulAutoConnect(
            profileId: _profile.id,
            tag: 'server-a',
            until: DateTime.now().add(const Duration(minutes: 1)),
          ),
        );
        final settingsRepository = _FakeAutoSelectSettingsRepository(
          initialState: recentSuccessfulState,
        );
        final preconnectProbedTags = <String>[];
        final preconnectService = AutoSelectPreconnectService(
          settingsRepository: settingsRepository,
          probeCandidate:
              ({
                required profileId,
                required templateConfig,
                required candidate,
                required settings,
              }) async {
                preconnectProbedTags.add(candidate.tag);
                return switch (candidate.tag) {
                  'server-b' => const AutoSelectPreconnectProbeResult(
                    serverTag: 'server-b',
                    urlTestDelay: 42,
                    domainProbeOk: true,
                    ipProbeOk: true,
                    throughputBytesPerSecond: 64 * 1024,
                  ),
                  _ => const AutoSelectPreconnectProbeResult(
                    serverTag: 'server-a',
                    urlTestDelay: null,
                    domainProbeOk: false,
                    ipProbeOk: false,
                    throughputBytesPerSecond: 0,
                  ),
                };
              },
        );
        final runtimeService = _FakeRuntimeService(startSession: _session);
        final autoSelectorService = _ScriptedAutoSelectorService(
          verifyResponses: [
            Future<AutoSelectProbeResult>.value(
              const AutoSelectProbeResult(
                serverTag: 'server-a',
                urlTestDelay: 90,
                domainProbeOk: true,
                ipProbeOk: true,
                throughputBytesPerSecond: 64 * 1024,
              ),
            ),
            Future<AutoSelectProbeResult>.value(
              const AutoSelectProbeResult(
                serverTag: 'server-a',
                urlTestDelay: 90,
                domainProbeOk: true,
                ipProbeOk: true,
                throughputBytesPerSecond: 64 * 1024,
              ),
            ),
          ],
        );
        final controller = DashboardController(
          repository: _FakeProfileRepository(
            initialStorage: _storage,
            templateConfig: _autoSelectTemplateConfig,
          ),
          runtimeService: runtimeService,
          autoSelectSettingsRepository: settingsRepository,
          autoSelectPreconnectService: preconnectService,
          autoSelectorService: autoSelectorService,
          clashApiClientFactory: (_) => _FakeClashApiClient(
            snapshot: ClashApiSnapshot(
              selectedTag: runtimeService.lastStartedSelectedServerTag,
              delayByTag: const {'server-a': 90, 'server-b': 42},
            ),
            delays: const {'server-a': 90, 'server-b': 42},
          ),
          initialState: DashboardState(
            bootstrapping: false,
            runtimeMode: RuntimeMode.mixed,
            autoSelectSettings: const AutoSelectSettings(enabled: true),
            storage: _storage,
            selectedServerTag: autoSelectServerTag,
            activeServerTag: 'server-a',
          ),
          loadOnInit: false,
        );
        addTearDown(controller.dispose);

        await controller.connect();

        expect(preconnectProbedTags, isEmpty);
        expect(autoSelectorService.maintainCallCount, 0);
        expect(autoSelectorService.verifyCallCount, 1);
        expect(settingsRepository.clearRecentSuccessfulAutoConnectCallCount, 0);
        expect(runtimeService.selectedServerTags, ['server-a']);
        expect(controller.state.connectionStage, ConnectionStage.connected);
        expect(
          controller.state.hasRecentSuccessfulAutoConnectForActiveProfile,
          isTrue,
        );

        await controller.disconnect();
        await controller.connect();

        expect(preconnectProbedTags, isEmpty);
        expect(autoSelectorService.maintainCallCount, 0);
        expect(autoSelectorService.verifyCallCount, 2);
        expect(settingsRepository.clearRecentSuccessfulAutoConnectCallCount, 0);
        expect(runtimeService.selectedServerTags, ['server-a', 'server-a']);
        expect(controller.state.connectionStage, ConnectionStage.connected);
        expect(controller.state.activeServerTag, 'server-a');
        expect(
          controller.state.hasRecentSuccessfulAutoConnectForActiveProfile,
          isTrue,
        );
      },
    );

    test(
      'connect with a valid recent successful cache skips pre-connect activity entirely',
      () async {
        final cachedAutoConnect = RecentSuccessfulAutoConnect(
          profileId: _profile.id,
          tag: 'server-a',
          until: DateTime.now().add(const Duration(minutes: 1)),
        );
        final settingsRepository = _FakeAutoSelectSettingsRepository(
          initialState: StoredAutoSelectState(
            settings: const AutoSelectSettings(enabled: true),
            recentSuccessfulAutoConnect: cachedAutoConnect,
          ),
        );
        final preconnectProbedTags = <String>[];
        final preconnectService = AutoSelectPreconnectService(
          settingsRepository: settingsRepository,
          probeCandidate:
              ({
                required profileId,
                required templateConfig,
                required candidate,
                required settings,
              }) async {
                preconnectProbedTags.add(candidate.tag);
                return const AutoSelectPreconnectProbeResult(
                  serverTag: 'server-a',
                  urlTestDelay: 42,
                  domainProbeOk: true,
                  ipProbeOk: true,
                  throughputBytesPerSecond: 64 * 1024,
                );
              },
        );
        final runtimeService = _FakeRuntimeService(startSession: _session);
        final autoSelectorService = _ScriptedAutoSelectorService(
          verifyResponses: [
            Future<AutoSelectProbeResult>.value(
              const AutoSelectProbeResult(
                serverTag: 'server-a',
                urlTestDelay: 42,
                domainProbeOk: true,
                ipProbeOk: true,
                throughputBytesPerSecond: 64 * 1024,
              ),
            ),
          ],
        );
        final controller = DashboardController(
          repository: _FakeProfileRepository(
            initialStorage: _storage,
            templateConfig: _autoSelectTemplateConfig,
          ),
          runtimeService: runtimeService,
          autoSelectSettingsRepository: settingsRepository,
          autoSelectPreconnectService: preconnectService,
          autoSelectorService: autoSelectorService,
          clashApiClientFactory: (_) => _FakeClashApiClient(
            snapshot: const ClashApiSnapshot(
              selectedTag: 'server-a',
              delayByTag: {'server-a': 42},
            ),
            delays: const {'server-a': 42},
          ),
          initialState: DashboardState(
            bootstrapping: false,
            runtimeMode: RuntimeMode.mixed,
            autoSelectSettings: const AutoSelectSettings(enabled: true),
            storage: _storage,
            selectedServerTag: autoSelectServerTag,
            activeServerTag: 'server-a',
            recentSuccessfulAutoConnect: cachedAutoConnect,
          ),
          loadOnInit: false,
        );
        addTearDown(controller.dispose);

        await controller.connect();

        expect(runtimeService.selectedServerTags, ['server-a']);
        expect(runtimeService.stopCallCount, 0);
        expect(preconnectProbedTags, isEmpty);
        expect(autoSelectorService.maintainCallCount, 0);
        expect(autoSelectorService.verifyCallCount, 1);
        expect(controller.state.connectionStage, ConnectionStage.connected);
        expect(controller.state.lastBestServerCheckAt, isNull);
        expect(
          controller.state.autoSelectActivity.label,
          isNot('Pre-connect auto-select'),
        );
        expect(
          controller.state.autoSelectActivity.logLines.where(
            (line) => line.contains('[Pre-connect auto-select]'),
          ),
          isEmpty,
        );
        expect(
          controller.state.statusMessage,
          contains(
            'Auto-selector reused the recent successful server server-a before starting sing-box.',
          ),
        );
      },
    );

    test(
      'connect clears the recent successful cache when lightweight fast-path verification fails',
      () async {
        final cachedAutoConnect = RecentSuccessfulAutoConnect(
          profileId: _profile.id,
          tag: 'server-a',
          until: DateTime.now().add(const Duration(minutes: 1)),
        );
        final settingsRepository = _FakeAutoSelectSettingsRepository(
          initialState: StoredAutoSelectState(
            settings: const AutoSelectSettings(enabled: true),
            recentSuccessfulAutoConnect: cachedAutoConnect,
          ),
        );
        final preconnectService = AutoSelectPreconnectService(
          settingsRepository: settingsRepository,
          probeCandidate:
              ({
                required profileId,
                required templateConfig,
                required candidate,
                required settings,
              }) async {
                return const AutoSelectPreconnectProbeResult(
                  serverTag: 'server-a',
                  urlTestDelay: 42,
                  domainProbeOk: true,
                  ipProbeOk: true,
                  throughputBytesPerSecond: 64 * 1024,
                );
              },
        );
        final runtimeService = _FakeRuntimeService(startSession: _session);
        final autoSelectorService = _ScriptedAutoSelectorService(
          verifyResponses: [
            Future<AutoSelectProbeResult>.value(
              const AutoSelectProbeResult(
                serverTag: 'server-a',
                urlTestDelay: 42,
                domainProbeOk: true,
                ipProbeOk: false,
                throughputBytesPerSecond: 64 * 1024,
              ),
            ),
          ],
        );
        final controller = DashboardController(
          repository: _FakeProfileRepository(
            initialStorage: _storage,
            templateConfig: _autoSelectTemplateConfig,
          ),
          runtimeService: runtimeService,
          autoSelectSettingsRepository: settingsRepository,
          autoSelectPreconnectService: preconnectService,
          autoSelectorService: autoSelectorService,
          clashApiClientFactory: (_) => _FakeClashApiClient(
            snapshot: const ClashApiSnapshot(
              selectedTag: 'server-a',
              delayByTag: {'server-a': 42},
            ),
            delays: const {'server-a': 42},
          ),
          initialState: DashboardState(
            bootstrapping: false,
            runtimeMode: RuntimeMode.mixed,
            autoSelectSettings: const AutoSelectSettings(enabled: true),
            storage: _storage,
            selectedServerTag: autoSelectServerTag,
            activeServerTag: 'server-a',
            recentSuccessfulAutoConnect: cachedAutoConnect,
          ),
          loadOnInit: false,
        );
        addTearDown(controller.dispose);

        await controller.connect();

        expect(runtimeService.startCallCount, 1);
        expect(runtimeService.stopCallCount, 1);
        expect(autoSelectorService.maintainCallCount, 0);
        expect(autoSelectorService.verifyCallCount, 1);
        expect(settingsRepository.clearRecentSuccessfulAutoConnectCallCount, 1);
        expect(controller.state.connectionStage, ConnectionStage.disconnected);
        expect(
          controller.state.errorMessage,
          'Подключение не удалось: Server A недоступен.',
        );
      },
    );

    test(
      'selecting auto server while disconnected keeps the quick reconnect cache until reset is pressed',
      () async {
        final cachedAutoConnect = RecentSuccessfulAutoConnect(
          profileId: _manualProfile.id,
          tag: 'server-a',
          until: DateTime.now().add(const Duration(minutes: 1)),
        );
        final manualStorageWithAutoCandidate = StoredProfilesState(
          activeProfileId: _manualProfile.id,
          profiles: [
            _manualProfile.copyWith(lastAutoSelectedServerTag: 'server-b'),
          ],
        );
        final settingsRepository = _FakeAutoSelectSettingsRepository(
          initialState: StoredAutoSelectState(
            settings: const AutoSelectSettings(enabled: true),
            recentSuccessfulAutoConnect: cachedAutoConnect,
          ),
        );
        final controller = DashboardController(
          repository: _FakeProfileRepository(
            initialStorage: manualStorageWithAutoCandidate,
          ),
          runtimeService: _FakeRuntimeService(),
          autoSelectSettingsRepository: settingsRepository,
          autoSelectPreconnectService: _FakeAutoSelectPreconnectService(),
          autoSelectorService: _ScriptedAutoSelectorService(),
          initialState: DashboardState(
            bootstrapping: false,
            runtimeMode: RuntimeMode.mixed,
            autoSelectSettings: const AutoSelectSettings(enabled: true),
            storage: manualStorageWithAutoCandidate,
            selectedServerTag: 'server-a',
            activeServerTag: 'server-a',
            recentSuccessfulAutoConnect: cachedAutoConnect,
          ),
          loadOnInit: false,
        );
        addTearDown(controller.dispose);

        await controller.selectServer(autoSelectServerTag);

        expect(settingsRepository.clearRecentSuccessfulAutoConnectCallCount, 0);
        expect(controller.state.selectedServerTag, autoSelectServerTag);
        expect(controller.state.activeServerTag, 'server-b');
        expect(
          controller.state.hasRecentSuccessfulAutoConnectForActiveProfile,
          isTrue,
        );
      },
    );

    test(
      'resetRecentSuccessfulAutoConnect clears the quick reconnect cache for the next connect',
      () async {
        final cachedAutoConnect = RecentSuccessfulAutoConnect(
          profileId: _profile.id,
          tag: 'server-a',
          until: DateTime.now().add(const Duration(minutes: 1)),
        );
        final settingsRepository = _FakeAutoSelectSettingsRepository(
          initialState: StoredAutoSelectState(
            settings: const AutoSelectSettings(enabled: true),
            recentSuccessfulAutoConnect: cachedAutoConnect,
          ),
        );
        final controller = DashboardController(
          repository: _FakeProfileRepository(initialStorage: _storage),
          runtimeService: _FakeRuntimeService(),
          autoSelectSettingsRepository: settingsRepository,
          autoSelectPreconnectService: _FakeAutoSelectPreconnectService(),
          autoSelectorService: _ScriptedAutoSelectorService(),
          initialState: DashboardState(
            bootstrapping: false,
            runtimeMode: RuntimeMode.mixed,
            autoSelectSettings: const AutoSelectSettings(enabled: true),
            storage: _storage,
            selectedServerTag: autoSelectServerTag,
            activeServerTag: 'server-a',
            recentSuccessfulAutoConnect: cachedAutoConnect,
          ),
          loadOnInit: false,
        );
        addTearDown(controller.dispose);

        await controller.resetRecentSuccessfulAutoConnect();

        expect(settingsRepository.clearRecentSuccessfulAutoConnectCallCount, 1);
        expect(
          controller.state.hasRecentSuccessfulAutoConnectForActiveProfile,
          isFalse,
        );
        expect(controller.state.activeServerTag, 'server-a');
        expect(
          controller.state.statusMessage,
          'Auto-select quick reconnect cache cleared. The next connection will run pre-connect probing again.',
        );
      },
    );

    test(
      'manual auto-select updates the last best-server check timestamp',
      () async {
        final autoSelectorService = _ScriptedAutoSelectorService(
          selectResponses: [
            Future<AutoSelectOutcome>.value(
              const AutoSelectOutcome(
                selectedServerTag: 'server-b',
                previousServerTag: 'server-a',
                delayByTag: {'server-a': 55, 'server-b': 42},
                probes: [
                  AutoSelectProbeResult(
                    serverTag: 'server-b',
                    urlTestDelay: 42,
                    domainProbeOk: true,
                    ipProbeOk: true,
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
        final controller = DashboardController(
          repository: _FakeProfileRepository(initialStorage: _storage),
          runtimeService: _FakeRuntimeService(),
          autoSelectSettingsRepository: _FakeAutoSelectSettingsRepository(),
          autoSelectPreconnectService: _FakeAutoSelectPreconnectService(),
          autoSelectorService: autoSelectorService,
          initialState: DashboardState(
            bootstrapping: false,
            runtimeMode: RuntimeMode.mixed,
            autoSelectSettings: const AutoSelectSettings(enabled: true),
            storage: _storage,
            connectionStage: ConnectionStage.connected,
            runtimeSession: _session,
            connectedAt: DateTime(2026, 4, 4, 10),
            selectedServerTag: autoSelectServerTag,
            activeServerTag: 'server-a',
          ),
          loadOnInit: false,
        );
        addTearDown(controller.dispose);

        await controller.runAutoSelect();

        expect(autoSelectorService.selectCallCount, 1);
        expect(controller.state.activeServerTag, 'server-b');
        expect(controller.state.lastBestServerCheckAt, isNotNull);
      },
    );

    test(
      'manual auto-select deduplicates exact duplicate candidates from template config',
      () async {
        final duplicateProfile = ProxyProfile(
          id: 'profile-1',
          name: 'Profile 1',
          subscriptionUrl: 'https://example.com/sub',
          templateFileName: 'profile-1.json',
          createdAt: _createdAt,
          updatedAt: _createdAt,
          servers: const [
            ServerEntry(
              tag: 'server-a',
              displayName: 'Server A',
              type: 'vless',
              host: 'dup.example.com',
              port: 443,
            ),
            ServerEntry(
              tag: 'server-b',
              displayName: 'Server B',
              type: 'vless',
              host: 'dup.example.com',
              port: 443,
            ),
            ServerEntry(
              tag: 'server-c',
              displayName: 'Server C',
              type: 'vless',
              host: 'unique.example.com',
              port: 443,
            ),
          ],
          lastSelectedServerTag: autoSelectServerTag,
          lastAutoSelectedServerTag: 'server-a',
        );
        final duplicateStorage = StoredProfilesState(
          activeProfileId: duplicateProfile.id,
          profiles: [duplicateProfile],
        );
        final autoSelectorService = _ScriptedAutoSelectorService(
          selectResponses: [
            Future<AutoSelectOutcome>.value(
              const AutoSelectOutcome(
                selectedServerTag: 'server-c',
                previousServerTag: 'server-a',
                delayByTag: {'server-c': 42},
                probes: [
                  AutoSelectProbeResult(
                    serverTag: 'server-c',
                    urlTestDelay: 42,
                    domainProbeOk: true,
                    ipProbeOk: true,
                    throughputBytesPerSecond: 64 * 1024,
                  ),
                ],
                summary:
                    'Auto-selector switched from server-a to server-c after confirming better end-to-end health and latency.',
                didSwitch: true,
                hasReachableCandidate: true,
              ),
            ),
          ],
        );
        final controller = DashboardController(
          repository: _FakeProfileRepository(
            initialStorage: duplicateStorage,
            templateConfig: jsonEncode({
              'outbounds': [
                {
                  'type': 'vless',
                  'tag': 'server-a',
                  'server': 'dup.example.com',
                  'server_port': 443,
                  'uuid': '11111111-1111-1111-1111-111111111111',
                },
                {
                  'server_port': 443,
                  'server': 'dup.example.com',
                  'uuid': '11111111-1111-1111-1111-111111111111',
                  'tag': 'server-b',
                  'type': 'vless',
                },
                {
                  'type': 'vless',
                  'tag': 'server-c',
                  'server': 'unique.example.com',
                  'server_port': 443,
                  'uuid': '22222222-2222-2222-2222-222222222222',
                },
              ],
            }),
          ),
          runtimeService: _FakeRuntimeService(),
          autoSelectSettingsRepository: _FakeAutoSelectSettingsRepository(),
          autoSelectPreconnectService: _FakeAutoSelectPreconnectService(),
          autoSelectorService: autoSelectorService,
          initialState: DashboardState(
            bootstrapping: false,
            runtimeMode: RuntimeMode.mixed,
            autoSelectSettings: const AutoSelectSettings(enabled: true),
            storage: duplicateStorage,
            connectionStage: ConnectionStage.connected,
            runtimeSession: _session,
            connectedAt: DateTime(2026, 4, 4, 10),
            selectedServerTag: autoSelectServerTag,
            activeServerTag: 'server-a',
          ),
          loadOnInit: false,
        );
        addTearDown(controller.dispose);

        await controller.runAutoSelect();

        expect(
          autoSelectorService.selectServerTagsHistory.single,
          ['server-a', 'server-c'],
        );
      },
    );

    test('disconnect clears connection and best-server timers', () async {
      final controller = DashboardController(
        repository: _FakeProfileRepository(initialStorage: _storage),
        runtimeService: _FakeRuntimeService(),
        autoSelectSettingsRepository: _FakeAutoSelectSettingsRepository(),
        autoSelectPreconnectService: _FakeAutoSelectPreconnectService(),
        autoSelectorService: _ScriptedAutoSelectorService(),
        initialState: DashboardState(
          bootstrapping: false,
          runtimeMode: RuntimeMode.mixed,
          autoSelectSettings: const AutoSelectSettings(enabled: true),
          storage: _storage,
          connectionStage: ConnectionStage.connected,
          runtimeSession: _session,
          connectedAt: DateTime(2026, 4, 4, 10),
          selectedServerTag: autoSelectServerTag,
          activeServerTag: 'server-a',
          lastBestServerCheckAt: DateTime(2026, 4, 4, 10, 5),
        ),
        loadOnInit: false,
      );
      addTearDown(controller.dispose);

      await controller.disconnect();

      expect(controller.state.connectionStage, ConnectionStage.disconnected);
      expect(controller.state.connectedAt, isNull);
      expect(controller.state.lastBestServerCheckAt, isNull);
    });

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
  _FakeProfileRepository({
    required StoredProfilesState initialStorage,
    this.templateConfig = '{}',
  }) : _storage = initialStorage;

  StoredProfilesState _storage;
  final String templateConfig;

  @override
  Future<StoredProfilesState> loadState() async => _storage;

  @override
  Future<String> loadTemplateConfig(ProxyProfile profile) async =>
      templateConfig;

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
  _FakeAutoSelectSettingsRepository({StoredAutoSelectState? initialState})
    : _state =
          initialState ??
          const StoredAutoSelectState(
            settings: AutoSelectSettings(enabled: true),
          );

  StoredAutoSelectState _state;
  final List<String> recentAutoSelectedServerCalls = <String>[];
  final List<String> recentSuccessfulAutoConnectCalls = <String>[];
  int clearRecentSuccessfulAutoConnectCallCount = 0;

  @override
  Future<StoredAutoSelectState> clearExpiredCaches() async => _state;

  @override
  Future<StoredAutoSelectState> saveSettings(
    AutoSelectSettings settings,
  ) async {
    _state = _state.copyWith(settings: settings);
    return _state;
  }

  @override
  Future<StoredAutoSelectState> setRecentAutoSelectedServer({
    required String profileId,
    required String serverTag,
    Duration ttl = defaultRecentAutoSelectedServerTtl,
  }) async {
    recentAutoSelectedServerCalls.add('$profileId::$serverTag');
    _state = _state.copyWith(
      recentAutoSelectedServer: RecentAutoSelectedServer(
        profileId: profileId,
        tag: serverTag,
        until: DateTime.now().add(ttl),
      ),
    );
    return _state;
  }

  @override
  Future<StoredAutoSelectState> setRecentSuccessfulAutoConnect({
    required String profileId,
    required String serverTag,
    Duration ttl = defaultRecentSuccessfulAutoConnectTtl,
  }) async {
    recentSuccessfulAutoConnectCalls.add('$profileId::$serverTag');
    _state = _state.copyWith(
      recentSuccessfulAutoConnect: RecentSuccessfulAutoConnect(
        profileId: profileId,
        tag: serverTag,
        until: DateTime.now().add(ttl),
      ),
    );
    return _state;
  }

  @override
  Future<StoredAutoSelectState> clearRecentSuccessfulAutoConnect() async {
    clearRecentSuccessfulAutoConnectCallCount += 1;
    _state = _state.copyWith(clearRecentSuccessfulAutoConnect: true);
    return _state;
  }
}

class _FakeRuntimeService extends SingboxRuntimeService {
  _FakeRuntimeService({RuntimeSession? startSession})
    : _startSession = startSession ?? _session;

  final RuntimeSession _startSession;
  int startCallCount = 0;
  int stopCallCount = 0;
  final List<String?> selectedServerTags = <String?>[];

  String? get lastStartedSelectedServerTag =>
      selectedServerTags.isEmpty ? null : selectedServerTags.last;

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
    selectedServerTags.add(selectedServerTag);
    return _startSession;
  }

  @override
  Future<void> stop() async {
    stopCallCount += 1;
  }
}

class _ScriptedAutoSelectorService extends AutoSelectorService {
  _ScriptedAutoSelectorService({
    List<Future<AutoSelectOutcome>>? selectResponses,
    List<Future<AutoSelectOutcome>>? maintainResponses,
    List<Future<AutoSelectProbeResult>>? verifyResponses,
  }) : _selectResponses = selectResponses ?? <Future<AutoSelectOutcome>>[],
       _maintainResponses = maintainResponses ?? <Future<AutoSelectOutcome>>[],
       _verifyResponses = verifyResponses ?? <Future<AutoSelectProbeResult>>[];

  final List<Future<AutoSelectOutcome>> _selectResponses;
  final List<Future<AutoSelectOutcome>> _maintainResponses;
  final List<Future<AutoSelectProbeResult>> _verifyResponses;
  final List<List<String>> selectServerTagsHistory = <List<String>>[];
  final List<List<String>> maintainServerTagsHistory = <List<String>>[];
  int selectCallCount = 0;
  int maintainCallCount = 0;
  int verifyCallCount = 0;

  @override
  Future<AutoSelectOutcome> selectBestServer({
    required RuntimeSession session,
    required List<ServerEntry> servers,
    required String domainProbeUrl,
    String ipProbeUrl = 'http://1.1.1.1',
    bool checkIp = true,
    AutoSelectProgressReporter? onProgress,
  }) {
    selectCallCount += 1;
    selectServerTagsHistory.add([for (final server in servers) server.tag]);
    return _selectResponses.removeAt(0);
  }

  @override
  Future<AutoSelectOutcome> maintainBestServer({
    required RuntimeSession session,
    required List<ServerEntry> servers,
    required String domainProbeUrl,
    String ipProbeUrl = 'http://1.1.1.1',
    bool checkIp = true,
    bool allowSwitchDuringCooldown = false,
    AutoSelectProgressReporter? onProgress,
  }) {
    maintainCallCount += 1;
    maintainServerTagsHistory.add([for (final server in servers) server.tag]);
    return _maintainResponses.removeAt(0);
  }

  @override
  Future<AutoSelectProbeResult> verifyCurrentServer({
    required RuntimeSession session,
    required ServerEntry server,
    required String domainProbeUrl,
    String ipProbeUrl = 'http://1.1.1.1',
    bool checkIp = true,
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
