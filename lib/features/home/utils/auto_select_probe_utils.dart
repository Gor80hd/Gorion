import 'dart:io';

import 'package:path/path.dart' as p;

/// Returns the path to the sing-box binary used by gorion_clean.
String hiddifyCliPath() {
  final execDir = File(Platform.resolvedExecutable).parent.path;
  if (Platform.isWindows) {
    final prod = p.join(execDir, 'singbox.exe');
    if (File(prod).existsSync()) return prod;
    // Fallback to sing-box naming convention
    return p.join(execDir, 'sing-box.exe');
  }
  final prod = p.join(execDir, 'singbox');
  if (File(prod).existsSync()) return prod;
  return p.join(execDir, 'sing-box');
}

Future<({ServerSocket socket, int port})> allocateFreePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  return (socket: socket, port: socket.port);
}

Future<bool> waitForLocalPortReady(
  int port, {
  Duration timeout = const Duration(seconds: 4),
  Duration pollInterval = const Duration(milliseconds: 120),
  bool Function()? isCancelled,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (isCancelled != null && isCancelled()) return false;
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 300),
      );
      return true;
    } catch (_) {
      if (isCancelled != null && isCancelled()) return false;
      await Future<void>.delayed(pollInterval);
    } finally {
      socket?.destroy();
    }
  }
  return false;
}
