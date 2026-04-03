import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';

enum ConnectionStage { disconnected, starting, connected, stopping, failed }

class RuntimeSession {
  const RuntimeSession({
    required this.profileId,
    required this.mode,
    required this.binaryPath,
    required this.configPath,
    required this.controllerPort,
    required this.mixedPort,
    required this.secret,
    required this.manualSelectorTag,
    required this.autoGroupTag,
  });

  final String profileId;
  final RuntimeMode mode;
  final String binaryPath;
  final String configPath;
  final int controllerPort;
  final int mixedPort;
  final String secret;
  final String manualSelectorTag;
  final String autoGroupTag;

  String get controllerBaseUrl => 'http://127.0.0.1:$controllerPort';
  String get mixedProxyAddress => '127.0.0.1:$mixedPort';
}
