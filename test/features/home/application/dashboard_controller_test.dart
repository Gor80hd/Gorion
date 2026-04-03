import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/auto_select/data/auto_select_preconnect_service.dart';
import 'package:gorion_clean/features/auto_select/data/auto_select_settings_repository.dart';
import 'package:gorion_clean/features/auto_select/data/auto_selector_service.dart';
import 'package:gorion_clean/features/auto_select/model/auto_select_state.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/profiles/data/profile_repository.dart';
import 'package:gorion_clean/features/profiles/model/profile_models.dart';
import 'package:gorion_clean/features/runtime/data/singbox_runtime_service.dart';
import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';

const _createdAt = DateTime(2026, 4, 3, 12);
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
const _profile = ProxyProfile(
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
const _storage = StoredProfilesState(
  activeProfileId: 'profile-1',
  profiles: [_profile],
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
        final autoSelectorService = _ScriptedAutoSelectorService([
          firstPass.future,
          Future<AutoSelectOutcome>.value(_keepCurrentOutcome),
        ]);
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
          initialState: const DashboardState(
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
  @override
  Future<StoredAutoSelectState> clearExpiredCaches() async {
    return const StoredAutoSelectState(
      settings: AutoSelectSettings(enabled: true),
    );
  }
}

class _FakeRuntimeService extends SingboxRuntimeService {
  @override
  List<String> get logs => const <String>[];
}

class _ScriptedAutoSelectorService extends AutoSelectorService {
  _ScriptedAutoSelectorService(this._responses);

  final List<Future<AutoSelectOutcome>> _responses;
  int maintainCallCount = 0;

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
    return _responses.removeAt(0);
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
