import 'dart:async';

import 'package:gorion/core/privileged_helper/privileged_helper_client.dart';
import 'package:gorion/core/privileged_helper/privileged_helper_protocol.dart';
import 'package:gorion/features/runtime/data/privileged_helper_runtime_engine.dart';
import 'package:gorion/features/runtime/data/runtime_engine.dart';
import 'package:gorion/features/runtime/data/singbox_runtime_service.dart';
import 'package:gorion/features/runtime/data/system_proxy_service.dart';
import 'package:gorion/features/runtime/model/runtime_mode.dart';
import 'package:gorion/features/runtime/model/runtime_models.dart';
import 'package:gorion/features/settings/model/connection_tuning_settings.dart';

enum RuntimeBackend { local, privilegedHelper }

/// Only TUN needs elevated rights; mixed and system-proxy modes always run
/// in the user session.
RuntimeBackend selectRuntimeBackend({
  required RuntimeMode mode,
  required bool privilegedHelperProvisioned,
}) {
  if (privilegedHelperProvisioned && mode.usesTun) {
    return RuntimeBackend.privilegedHelper;
  }
  return RuntimeBackend.local;
}

/// Builds the engine for the current platform.
RuntimeEngine buildRuntimeEngine({
  bool? privilegedHelperProvisioned,
  PrivilegedHelperClient? helperClient,
  RuntimeEngine? localService,
  RuntimeEngine? helperService,
}) {
  final resolvedLocalService =
      localService ??
      SingboxRuntimeService(
        privilegedHelperClient: helperClient ?? PrivilegedHelperClient(),
      );
  final helperAvailable =
      privilegedHelperProvisioned ?? isPrivilegedHelperSupported();
  if (!helperAvailable) {
    return resolvedLocalService;
  }
  return AdaptiveRuntimeEngine(
    localService: resolvedLocalService,
    helperService:
        helperService ??
        PrivilegedHelperRuntimeEngine(
          helperClient: helperClient ?? PrivilegedHelperClient(),
        ),
  );
}

/// Picks the engine per start: the privileged helper for TUN when it is
/// reachable, the local process otherwise. Helper availability is resolved
/// on every start, so installing the helper mid-session needs no restart.
class AdaptiveRuntimeEngine implements RuntimeEngine {
  AdaptiveRuntimeEngine({
    required RuntimeEngine localService,
    required RuntimeEngine helperService,
  }) : _localService = localService,
       _helperService = helperService;

  final RuntimeEngine _localService;
  final RuntimeEngine _helperService;
  final List<String> _lastLogs = <String>[];
  RuntimeEngine? _activeService;
  final _lifecycle = LifecycleQueue();

  @override
  RuntimeSession? get session => _activeService?.session;

  @override
  List<String> get logs {
    final activeService = _activeService;
    if (activeService != null) {
      return activeService.logs;
    }
    return List.unmodifiable(_lastLogs);
  }

  @override
  bool get launchesWithEmbeddedPrivilegeBroker => true;

  @override
  Future<bool> canLaunchWithEmbeddedPrivilegeBroker({
    required RuntimeMode mode,
  }) async {
    return identical(await _resolveServiceForStart(mode), _helperService);
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
  }) {
    return _lifecycle.run(
      () => _startAdaptive(
        profileId: profileId,
        templateConfig: templateConfig,
        originalTemplateConfig: originalTemplateConfig,
        connectionTuningSettings: connectionTuningSettings,
        urlTestUrl: urlTestUrl,
        mode: mode,
        selectedServerTag: selectedServerTag,
        onExit: onExit,
      ),
    );
  }

  Future<RuntimeSession> _startAdaptive({
    required String profileId,
    required String templateConfig,
    String? originalTemplateConfig,
    required ConnectionTuningSettings connectionTuningSettings,
    required String urlTestUrl,
    required RuntimeMode mode,
    String? selectedServerTag,
    RuntimeExitCallback? onExit,
  }) async {
    final nextService = await _resolveServiceForStart(mode);
    final previousService = _activeService;
    if (previousService != null && !identical(previousService, nextService)) {
      await previousService.stop();
      _rememberLogs(previousService);
      _activeService = null;
    }

    try {
      final session = await nextService.start(
        profileId: profileId,
        templateConfig: templateConfig,
        originalTemplateConfig: originalTemplateConfig,
        connectionTuningSettings: connectionTuningSettings,
        urlTestUrl: urlTestUrl,
        mode: mode,
        selectedServerTag: selectedServerTag,
        onExit: onExit,
      );
      _activeService = nextService;
      _rememberLogs(nextService);
      return session;
    } on Object {
      _rememberLogs(nextService);
      rethrow;
    }
  }

  @override
  Future<void> stop() {
    return _lifecycle.run(_stopAdaptive);
  }

  Future<void> _stopAdaptive() async {
    final activeService = _activeService;
    if (activeService != null) {
      try {
        await activeService.stop();
        _activeService = null;
      } finally {
        _rememberLogs(activeService);
      }
      return;
    }

    if (_localService.session != null) {
      try {
        await _localService.stop();
      } finally {
        _rememberLogs(_localService);
      }
    }
    if (_helperService.session != null) {
      try {
        await _helperService.stop();
      } finally {
        _rememberLogs(_helperService);
      }
    }
  }

  @override
  Future<void> stopForAppExit() {
    if (_activeService == null &&
        _localService.session == null &&
        _helperService.session == null) {
      return Future<void>.value();
    }
    return _lifecycle.run(_stopForAppExitAdaptive);
  }

  Future<void> _stopForAppExitAdaptive() async {
    final activeService = _activeService;
    if (activeService != null) {
      try {
        await activeService.stopForAppExit();
        _activeService = null;
      } finally {
        _rememberLogs(activeService);
      }
      return;
    }

    if (_localService.session != null) {
      try {
        await _localService.stopForAppExit();
      } finally {
        _rememberLogs(_localService);
      }
    }
    if (_helperService.session != null) {
      try {
        await _helperService.stopForAppExit();
      } finally {
        _rememberLogs(_helperService);
      }
    }
  }

  /// Recovery fan-out: re-attach to a helper-side runtime if one survived,
  /// then clean up local orphans.
  @override
  Future<void> recoverFromPreviousSession({ProxyLogSink? onLog}) async {
    await _helperService.recoverFromPreviousSession(onLog: onLog);
    if (_helperService.session != null) {
      _activeService = _helperService;
      _rememberLogs(_helperService);
    }
    await _localService.recoverFromPreviousSession(onLog: onLog);
  }

  @override
  void dispose() {
    unawaited(stopForAppExit());
  }

  RuntimeEngine _serviceForMode(RuntimeMode mode) {
    return switch (selectRuntimeBackend(
      mode: mode,
      privilegedHelperProvisioned: true,
    )) {
      RuntimeBackend.local => _localService,
      RuntimeBackend.privilegedHelper => _helperService,
    };
  }

  Future<RuntimeEngine> _resolveServiceForStart(RuntimeMode mode) async {
    final preferredService = _serviceForMode(mode);
    if (!identical(preferredService, _helperService)) {
      return preferredService;
    }
    if (await _helperService.canLaunchWithEmbeddedPrivilegeBroker(mode: mode)) {
      return _helperService;
    }
    return _localService;
  }

  void _rememberLogs(RuntimeEngine service) {
    _lastLogs
      ..clear()
      ..addAll(service.logs);
  }
}
