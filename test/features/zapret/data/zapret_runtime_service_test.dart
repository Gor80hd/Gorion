import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/zapret/data/zapret_runtime_service.dart';
import 'package:gorion_clean/features/zapret/model/zapret_models.dart';
import 'package:gorion_clean/features/zapret/model/zapret_settings.dart';

void main() {
  test(
    'adaptive zapret runtime falls back to local start when helper is unavailable',
    () async {
      final localService = _FakeAdaptiveZapretRuntimeService(
        canUseEmbeddedBroker: false,
        sessionTemplate: _session('local'),
      );
      final helperService = _FakeAdaptiveZapretRuntimeService(
        canUseEmbeddedBroker: false,
        sessionTemplate: _session('helper'),
      );
      final service = buildZapretRuntimeService(
        privilegedHelperProvisioned: true,
        localService: localService,
        helperService: helperService,
      );

      expect(await service.canLaunchWithEmbeddedPrivilegeBroker(), isFalse);

      final session = await service.start(
        settings: const ZapretSettings(installDirectory: r'E:\Tools\zapret2'),
        onExit: (_) {},
      );

      expect(session.commandPreview, 'local');
      expect(localService.startCalls, 1);
      expect(helperService.startCalls, 0);
    },
  );

  test(
    'adaptive zapret runtime keeps helper path when helper is available',
    () async {
      final localService = _FakeAdaptiveZapretRuntimeService(
        canUseEmbeddedBroker: false,
        sessionTemplate: _session('local'),
      );
      final helperService = _FakeAdaptiveZapretRuntimeService(
        canUseEmbeddedBroker: true,
        sessionTemplate: _session('helper'),
      );
      final service = buildZapretRuntimeService(
        privilegedHelperProvisioned: true,
        localService: localService,
        helperService: helperService,
      );

      expect(await service.canLaunchWithEmbeddedPrivilegeBroker(), isTrue);

      final session = await service.start(
        settings: const ZapretSettings(installDirectory: r'E:\Tools\zapret2'),
        onExit: (_) {},
      );

      expect(session.commandPreview, 'helper');
      expect(localService.startCalls, 0);
      expect(helperService.startCalls, 1);
    },
  );

  test(
    'adaptive zapret runtime serializes stop behind an in-flight start',
    () async {
      final startEntered = Completer<void>();
      final releaseStart = Completer<void>();
      final localService = _FakeAdaptiveZapretRuntimeService(
        canUseEmbeddedBroker: false,
        sessionTemplate: _session('local'),
        beforeStart: () async {
          startEntered.complete();
          await releaseStart.future;
        },
      );
      final helperService = _FakeAdaptiveZapretRuntimeService(
        canUseEmbeddedBroker: false,
        sessionTemplate: _session('helper'),
      );
      final service = buildZapretRuntimeService(
        privilegedHelperProvisioned: true,
        localService: localService,
        helperService: helperService,
      );

      final startFuture = service.start(
        settings: const ZapretSettings(installDirectory: r'E:\Tools\zapret2'),
        onExit: (_) {},
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

  test(
    'adaptive zapret runtime replays pending diagnostics into selected helper',
    () async {
      final localService = _FakeAdaptiveZapretRuntimeService(
        canUseEmbeddedBroker: false,
        sessionTemplate: _session('local'),
      );
      final helperService = _FakeAdaptiveZapretRuntimeService(
        canUseEmbeddedBroker: true,
        sessionTemplate: _session('helper'),
      );
      final service = buildZapretRuntimeService(
        privilegedHelperProvisioned: true,
        localService: localService,
        helperService: helperService,
      );

      service.recordDiagnostic('pre-start probe', isError: true);
      await service.start(
        settings: const ZapretSettings(installDirectory: r'E:\Tools\zapret2'),
        onExit: (_) {},
        preserveLogs: true,
      );

      expect(localService.logs, isEmpty);
      expect(helperService.logs, contains('[ошибка] pre-start probe'));
      expect(service.logs, contains('[ошибка] pre-start probe'));
    },
  );
}

class _FakeAdaptiveZapretRuntimeService extends ZapretRuntimeService {
  _FakeAdaptiveZapretRuntimeService({
    required this.canUseEmbeddedBroker,
    required this.sessionTemplate,
    this.beforeStart,
  });

  final bool canUseEmbeddedBroker;
  final ZapretRuntimeSession sessionTemplate;
  final Future<void> Function()? beforeStart;
  int startCalls = 0;
  int stopCalls = 0;
  ZapretRuntimeSession? _activeSession;
  final List<String> _logs = <String>[];

  @override
  ZapretRuntimeSession? get session => _activeSession;

  @override
  List<String> get logs => List.unmodifiable(_logs);

  @override
  Future<bool> canLaunchWithEmbeddedPrivilegeBroker() async {
    return canUseEmbeddedBroker;
  }

  @override
  Future<ZapretRuntimeSession> start({
    required ZapretSettings settings,
    required void Function(int exitCode) onExit,
    bool preserveLogs = false,
  }) async {
    startCalls += 1;
    await beforeStart?.call();
    _activeSession = sessionTemplate;
    _logs.add('started ${sessionTemplate.commandPreview}');
    return sessionTemplate;
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
    _logs.add('stopped ${sessionTemplate.commandPreview}');
    _activeSession = null;
  }

  @override
  void recordDiagnostic(String line, {bool isError = false}) {
    final prefix = isError ? '[ошибка]' : '[инфо]';
    _logs.add('$prefix $line');
  }
}

ZapretRuntimeSession _session(String preview) {
  return ZapretRuntimeSession(
    executablePath: r'E:\Tools\zapret2\bin\winws.exe',
    workingDirectory: r'E:\Tools\zapret2\bin',
    processId: 4242,
    startedAt: DateTime(2026, 4, 22, 12),
    arguments: const ['--wf-tcp=80,443,12'],
    commandPreview: preview,
  );
}
