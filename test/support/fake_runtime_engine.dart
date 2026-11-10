import 'package:gorion/features/runtime/data/runtime_engine.dart';
import 'package:gorion/features/runtime/data/system_proxy_service.dart';
import 'package:gorion/features/runtime/model/runtime_mode.dart';
import 'package:gorion/features/runtime/model/runtime_models.dart';
import 'package:gorion/features/settings/model/connection_tuning_settings.dart';

/// A [RuntimeEngine] that never touches processes, the network or the
/// filesystem. Tests extend it and override only what they observe.
class FakeRuntimeEngine implements RuntimeEngine {
  @override
  RuntimeSession? get session => null;

  @override
  List<String> get logs => const <String>[];

  @override
  bool get launchesWithEmbeddedPrivilegeBroker => false;

  @override
  Future<bool> canLaunchWithEmbeddedPrivilegeBroker({
    required RuntimeMode mode,
  }) async => false;

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
    throw UnimplementedError('This test does not start the runtime.');
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> stopForAppExit() async {}

  @override
  Future<void> recoverFromPreviousSession({ProxyLogSink? onLog}) async {}

  @override
  void dispose() {}
}
