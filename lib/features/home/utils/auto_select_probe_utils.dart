import 'dart:io';

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
