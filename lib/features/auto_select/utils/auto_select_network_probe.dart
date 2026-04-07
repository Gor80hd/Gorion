import 'dart:async';
import 'dart:io';

/// Polls [port] on loopback until a TCP connection succeeds or [timeout]
/// expires.  Each poll attempt has its own 500 ms connection timeout.
///
/// If [abortReason] is provided it is called before every poll; a non-null
/// return value causes an exception to be thrown immediately with that text.
Future<bool> waitForLocalPortReady(
  int port, {
  Duration timeout = const Duration(seconds: 8),
  Duration pollInterval = const Duration(milliseconds: 150),
  String? Function()? abortReason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final reason = abortReason?.call();
    if (reason != null) {
      throw Exception(reason);
    }
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 500),
      );
      await socket.close();
      return true;
    } on SocketException {
      await Future<void>.delayed(pollInterval);
    }
  }
  return false;
}

Future<bool> probeHttpViaLocalProxy({
  required int mixedPort,
  required Uri url,
  Duration timeout = const Duration(seconds: 6),
  String? Function()? abortReason,
}) async {
  final reason = abortReason?.call();
  if (reason != null) {
    throw Exception(reason);
  }

  final client = HttpClient()
    ..connectionTimeout = timeout
    ..findProxy = ((_) => 'PROXY 127.0.0.1:$mixedPort')
    ..userAgent = null;

  try {
    final request = await client.getUrl(url);
    final response = await request.close().timeout(timeout);
    await response.drain();
    final acceptedStatus =
        response.statusCode == HttpStatus.noContent ||
        (response.statusCode >= HttpStatus.ok &&
            response.statusCode < HttpStatus.multipleChoices);
    return acceptedStatus;
  } on Object {
    final abort = abortReason?.call();
    if (abort != null) {
      throw Exception(abort);
    }
    return false;
  } finally {
    client.close(force: true);
  }
}

Future<bool> probeHttpViaLocalProxyTargets({
  required int mixedPort,
  required Iterable<Uri> urls,
  Duration timeout = const Duration(seconds: 6),
  String? Function()? abortReason,
}) async {
  for (final url in urls) {
    final reason = abortReason?.call();
    if (reason != null) {
      throw Exception(reason);
    }
    final ok = await probeHttpViaLocalProxy(
      mixedPort: mixedPort,
      url: url,
      timeout: timeout,
      abortReason: abortReason,
    );
    if (ok) {
      return true;
    }
  }
  return false;
}

Future<int> measureDownloadThroughputViaLocalProxy({
  required int mixedPort,
  required Uri url,
  Duration timeout = const Duration(seconds: 3),
  String? Function()? abortReason,
}) async {
  final reason = abortReason?.call();
  if (reason != null) {
    throw Exception(reason);
  }

  final client = HttpClient()
    ..connectionTimeout = timeout
    ..findProxy = ((_) => 'PROXY 127.0.0.1:$mixedPort')
    ..userAgent = null;

  final stopwatch = Stopwatch()..start();
  try {
    final request = await client.getUrl(url);
    final response = await request.close().timeout(timeout);
    if (response.statusCode < HttpStatus.ok ||
        response.statusCode >= HttpStatus.multipleChoices) {
      return 0;
    }

    final bytes = await response
        .fold<int>(0, (sum, chunk) => sum + chunk.length)
        .timeout(timeout);
    final elapsedMs = stopwatch.elapsedMilliseconds;
    if (bytes <= 0) {
      return 0;
    }
    if (elapsedMs <= 0) {
      return bytes;
    }
    return ((bytes * 1000) / elapsedMs).round();
  } on Object {
    final abort = abortReason?.call();
    if (abort != null) {
      throw Exception(abort);
    }
    return 0;
  } finally {
    stopwatch.stop();
    client.close(force: true);
  }
}

Future<int> measureDownloadThroughputViaLocalProxyTargets({
  required int mixedPort,
  required Iterable<Uri> urls,
  Duration timeout = const Duration(seconds: 3),
  String? Function()? abortReason,
}) async {
  for (final url in urls) {
    final reason = abortReason?.call();
    if (reason != null) {
      throw Exception(reason);
    }
    final throughput = await measureDownloadThroughputViaLocalProxy(
      mixedPort: mixedPort,
      url: url,
      timeout: timeout,
      abortReason: abortReason,
    );
    if (throughput > 0) {
      return throughput;
    }
  }
  return 0;
}
