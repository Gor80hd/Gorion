import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Thrown when a process started through [runProcessWithTimeout] does not
/// exit within the requested timeout. The process is force-killed before this
/// exception is thrown, so a stuck child can never outlive the caller.
class ProcessRunTimeoutException implements Exception {
  const ProcessRunTimeoutException({
    required this.executable,
    required this.arguments,
    required this.timeout,
  });

  final String executable;
  final List<String> arguments;
  final Duration timeout;

  @override
  String toString() {
    return 'Process "$executable" did not exit within '
        '${timeout.inMilliseconds} ms and was killed.';
  }
}

/// Runs [executable] to completion with a hard [timeout].
///
/// Unlike a bare `Process.run`, a timed-out child is terminated (SIGKILL
/// where the platform supports it) and the caller gets a
/// [ProcessRunTimeoutException] instead of hanging forever. Standard streams
/// are drained concurrently so a chatty child can never deadlock on a full
/// pipe buffer.
Future<ProcessResult> runProcessWithTimeout(
  String executable,
  List<String> arguments, {
  Duration timeout = const Duration(seconds: 15),
  String? workingDirectory,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
  );

  final stdoutBuffer = StringBuffer();
  final stderrBuffer = StringBuffer();
  final stdoutSubscription = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .listen(stdoutBuffer.write);
  final stderrSubscription = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .listen(stderrBuffer.write);
  final stdoutDone = stdoutSubscription.asFuture<void>();
  final stderrDone = stderrSubscription.asFuture<void>();

  int exitCode;
  try {
    exitCode = await (() async {
      final code = await process.exitCode;
      await Future.wait<void>([stdoutDone, stderrDone]);
      return code;
    })().timeout(timeout);
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    try {
      await process.exitCode.timeout(const Duration(seconds: 2));
    } on Object {
      // The kill itself timed out; nothing more we can do from here.
    }
    // Descendants may have inherited the pipes. Do not wait for them after
    // the command deadline; cancel our subscriptions instead.
    await stdoutSubscription.cancel();
    await stderrSubscription.cancel();
    throw ProcessRunTimeoutException(
      executable: executable,
      arguments: arguments,
      timeout: timeout,
    );
  }

  return ProcessResult(
    process.pid,
    exitCode,
    stdoutBuffer.toString(),
    stderrBuffer.toString(),
  );
}
