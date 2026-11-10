import 'dart:async';

import 'package:gorion/core/privileged_helper/privileged_helper_client.dart';
import 'package:gorion/features/runtime/data/runtime_engine.dart';
import 'package:gorion/features/runtime/data/system_proxy_service.dart';
import 'package:gorion/features/runtime/model/runtime_mode.dart';
import 'package:gorion/features/runtime/model/runtime_models.dart';
import 'package:gorion/features/settings/model/connection_tuning_settings.dart';

/// Drives a core that runs inside the privileged helper daemon. Used for
/// TUN, which needs rights the GUI process does not have.
class PrivilegedHelperRuntimeEngine implements RuntimeEngine {
  PrivilegedHelperRuntimeEngine({required PrivilegedHelperClient helperClient})
    : _helperClient = helperClient;

  final PrivilegedHelperClient _helperClient;
  RuntimeSession? _remoteSession;
  final List<String> _remoteLogs = <String>[];
  Timer? _stateTimer;
  bool _pollingState = false;

  @override
  RuntimeSession? get session => _remoteSession;

  @override
  List<String> get logs => List.unmodifiable(_remoteLogs);

  @override
  bool get launchesWithEmbeddedPrivilegeBroker => true;

  @override
  Future<bool> canLaunchWithEmbeddedPrivilegeBroker({
    required RuntimeMode mode,
  }) async {
    if (!mode.usesTun) {
      return false;
    }

    try {
      await _helperClient.ensureAvailable();
      return true;
    } on Object {
      return false;
    }
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
    _stateTimer?.cancel();
    final snapshot = await _helperClient.startRuntime(
      profileId: profileId,
      templateConfig: templateConfig,
      originalTemplateConfig: originalTemplateConfig,
      connectionTuningSettings: connectionTuningSettings,
      urlTestUrl: urlTestUrl,
      mode: mode,
      selectedServerTag: selectedServerTag,
    );
    _remoteSession = snapshot.session;
    _replaceLogs(snapshot.logs);
    final session = _remoteSession;
    if (session == null) {
      throw StateError(
        'Privileged helper did not return a running sing-box session.',
      );
    }
    _stateTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_pollingState) return;
      _pollingState = true;
      try {
        final current = await _helperClient.fetchRuntimeState();
        if (!identical(_remoteSession, session)) return;
        _replaceLogs(current.logs);
        if (current.session == null) {
          _stateTimer?.cancel();
          _remoteSession = null;
          onExit?.call(session, -1);
        }
      } on Object {
        // A transient IPC failure does not prove the tunnel has stopped.
      } finally {
        _pollingState = false;
      }
    });
    return session;
  }

  @override
  Future<void> stop() async {
    final snapshot = await _helperClient.stopRuntime();
    _stateTimer?.cancel();
    _remoteSession = snapshot.session;
    _replaceLogs(snapshot.logs);
  }

  @override
  Future<void> stopForAppExit() async {
    if (_remoteSession == null) {
      return;
    }

    final snapshot = await _helperClient.stopRuntimeIfAvailable();
    _stateTimer?.cancel();
    if (snapshot == null) {
      return;
    }

    _remoteSession = snapshot.session;
    _replaceLogs(snapshot.logs);
  }

  /// Re-adopts a runtime session that survived an app restart inside the
  /// privileged helper. Without this the UI would show "disconnected" while
  /// the helper keeps routing traffic (or, worse, nobody would ever stop it).
  @override
  Future<void> recoverFromPreviousSession({ProxyLogSink? onLog}) async {
    try {
      final snapshot = await _helperClient.fetchRuntimeState();
      _remoteSession = snapshot.session;
      _replaceLogs(snapshot.logs);
      if (_remoteSession != null) {
        onLog?.call(
          'Re-attached to the privileged helper runtime from a previous app session.',
        );
      }
    } on Object {
      // Helper unavailable — nothing to re-attach to.
    }
  }

  @override
  void dispose() {
    unawaited(stopForAppExit());
  }

  void _replaceLogs(List<String> nextLogs) {
    _remoteLogs
      ..clear()
      ..addAll(nextLogs);
  }
}
