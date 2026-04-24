import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/runtime/data/singbox_runtime_service.dart';
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';
import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';
import 'package:gorion_clean/features/settings/model/connection_tuning_settings.dart';

void main() {
  test(
    'selectSingboxRuntimeBackend keeps mixed and system proxy in the user session',
    () {
      expect(
        selectSingboxRuntimeBackend(
          mode: RuntimeMode.mixed,
          privilegedHelperProvisioned: true,
        ),
        SingboxRuntimeBackend.local,
      );
      expect(
        selectSingboxRuntimeBackend(
          mode: RuntimeMode.systemProxy,
          privilegedHelperProvisioned: true,
        ),
        SingboxRuntimeBackend.local,
      );
    },
  );

  test('selectSingboxRuntimeBackend uses helper only for TUN', () {
    expect(
      selectSingboxRuntimeBackend(
        mode: RuntimeMode.tun,
        privilegedHelperProvisioned: true,
      ),
      SingboxRuntimeBackend.privilegedHelper,
    );
    expect(
      selectSingboxRuntimeBackend(
        mode: RuntimeMode.tun,
        privilegedHelperProvisioned: false,
      ),
      SingboxRuntimeBackend.local,
    );
  });

  test(
    'adaptive sing-box runtime falls back to local TUN start when helper is unavailable',
    () async {
      final localService = _FakeAdaptiveSingboxRuntimeService(
        canUseEmbeddedBroker: false,
        sessionTemplate: _runtimeSession('local'),
      );
      final helperService = _FakeAdaptiveSingboxRuntimeService(
        canUseEmbeddedBroker: false,
        sessionTemplate: _runtimeSession('helper'),
      );
      final service = buildSingboxRuntimeService(
        privilegedHelperProvisioned: true,
        localService: localService,
        helperService: helperService,
      );

      expect(
        await service.canLaunchWithEmbeddedPrivilegeBroker(
          mode: RuntimeMode.tun,
        ),
        isFalse,
      );

      final session = await service.start(
        profileId: 'profile-1',
        templateConfig: '{}',
        urlTestUrl: 'https://example.com',
        mode: RuntimeMode.tun,
      );

      expect(session.profileId, 'local');
      expect(localService.startCalls, 1);
      expect(helperService.startCalls, 0);
    },
  );

  test(
    'adaptive sing-box runtime keeps helper path for TUN when helper is available',
    () async {
      final localService = _FakeAdaptiveSingboxRuntimeService(
        canUseEmbeddedBroker: false,
        sessionTemplate: _runtimeSession('local'),
      );
      final helperService = _FakeAdaptiveSingboxRuntimeService(
        canUseEmbeddedBroker: true,
        sessionTemplate: _runtimeSession('helper'),
      );
      final service = buildSingboxRuntimeService(
        privilegedHelperProvisioned: true,
        localService: localService,
        helperService: helperService,
      );

      expect(
        await service.canLaunchWithEmbeddedPrivilegeBroker(
          mode: RuntimeMode.tun,
        ),
        isTrue,
      );

      final session = await service.start(
        profileId: 'profile-1',
        templateConfig: '{}',
        urlTestUrl: 'https://example.com',
        mode: RuntimeMode.tun,
      );

      expect(session.profileId, 'helper');
      expect(localService.startCalls, 0);
      expect(helperService.startCalls, 1);
    },
  );

  test(
    'adaptive sing-box runtime serializes stop behind an in-flight start',
    () async {
      final startEntered = Completer<void>();
      final releaseStart = Completer<void>();
      final localService = _FakeAdaptiveSingboxRuntimeService(
        canUseEmbeddedBroker: false,
        sessionTemplate: _runtimeSession('local'),
        beforeStart: () async {
          startEntered.complete();
          await releaseStart.future;
        },
      );
      final helperService = _FakeAdaptiveSingboxRuntimeService(
        canUseEmbeddedBroker: false,
        sessionTemplate: _runtimeSession('helper'),
      );
      final service = buildSingboxRuntimeService(
        privilegedHelperProvisioned: true,
        localService: localService,
        helperService: helperService,
      );

      final startFuture = service.start(
        profileId: 'profile-1',
        templateConfig: '{}',
        urlTestUrl: 'https://example.com',
        mode: RuntimeMode.tun,
      );
      await startEntered.future;

      final stopFuture = service.stop();
      await Future<void>.delayed(Duration.zero);

      expect(localService.stopCalls, 0);

      releaseStart.complete();
      await startFuture;
      await stopFuture;

      expect(localService.startCalls, 1);
      expect(localService.stopCalls, 1);
      expect(service.session, isNull);
      expect(service.logs, contains('stopped local'));
    },
  );
}

class _FakeAdaptiveSingboxRuntimeService extends SingboxRuntimeService {
  _FakeAdaptiveSingboxRuntimeService({
    required this.canUseEmbeddedBroker,
    required this.sessionTemplate,
    this.beforeStart,
  });

  final bool canUseEmbeddedBroker;
  final RuntimeSession sessionTemplate;
  final Future<void> Function()? beforeStart;
  RuntimeSession? _activeSession;
  final List<String> _logs = <String>[];
  int startCalls = 0;
  int stopCalls = 0;

  @override
  RuntimeSession? get session => _activeSession;

  @override
  List<String> get logs => List.unmodifiable(_logs);

  @override
  Future<bool> canLaunchWithEmbeddedPrivilegeBroker({
    required RuntimeMode mode,
  }) async {
    return canUseEmbeddedBroker;
  }

  @override
  Future<RuntimeSession> start({
    required String profileId,
    required String templateConfig,
    String? originalTemplateConfig,
    ConnectionTuningSettings connectionTuningSettings =
        const ConnectionTuningSettings(),
    required String urlTestUrl,
    required RuntimeMode mode,
    String? selectedServerTag,
    RuntimeExitCallback? onExit,
  }) async {
    startCalls += 1;
    await beforeStart?.call();
    _activeSession = sessionTemplate;
    _logs.add('started ${sessionTemplate.profileId}');
    return sessionTemplate;
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
    _logs.add('stopped ${sessionTemplate.profileId}');
    _activeSession = null;
  }
}

RuntimeSession _runtimeSession(String profileId) {
  return RuntimeSession(
    profileId: profileId,
    mode: RuntimeMode.tun,
    binaryPath: 'sing-box.exe',
    configPath: 'config.json',
    controllerPort: 9090,
    mixedPort: 2080,
    secret: 'secret',
    manualSelectorTag: 'manual',
    autoGroupTag: 'auto',
  );
}
