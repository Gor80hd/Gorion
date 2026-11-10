import 'dart:async';

import 'package:gorion_clean/features/runtime/data/system_proxy_service.dart';
import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';
import 'package:gorion_clean/features/settings/model/connection_tuning_settings.dart';

typedef RuntimeExitCallback =
    void Function(RuntimeSession session, int exitCode);

/// The contract between the app and whatever runs the proxy core.
///
/// The UI and controllers depend only on this interface. Implementations
/// decide how the core actually runs: a local child process, a privileged
/// helper daemon, or (on mobile) a platform VPN service.
abstract interface class RuntimeEngine {
  /// The running session, or null when the core is stopped.
  RuntimeSession? get session;

  /// Recent core and lifecycle log lines, oldest first.
  List<String> get logs;

  /// Whether this engine can obtain elevated rights by itself, without
  /// relaunching the whole app elevated.
  bool get launchesWithEmbeddedPrivilegeBroker;

  /// Whether [mode] can start right now through the embedded privilege
  /// broker (for example, the helper is installed and reachable).
  Future<bool> canLaunchWithEmbeddedPrivilegeBroker({
    required RuntimeMode mode,
  });

  /// Starts the core, replacing any running session. On failure nothing is
  /// left half-configured.
  Future<RuntimeSession> start({
    required String profileId,
    required String templateConfig,
    String? originalTemplateConfig,
    ConnectionTuningSettings connectionTuningSettings,
    required String urlTestUrl,
    required RuntimeMode mode,
    String? selectedServerTag,
    RuntimeExitCallback? onExit,
  });

  /// Stops the core and restores system state. Idempotent.
  Future<void> stop();

  /// Best-effort stop used while the app is quitting.
  Future<void> stopForAppExit();

  /// Cleans up or re-adopts whatever a previous app run left behind.
  Future<void> recoverFromPreviousSession({ProxyLogSink? onLog});

  void dispose();
}

/// Runs lifecycle operations strictly one after another, so a start can
/// never race a stop. A failed operation does not block the ones behind it.
class LifecycleQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await action());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
