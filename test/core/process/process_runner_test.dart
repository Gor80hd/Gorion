import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/core/process/process_runner.dart';

void main() {
  group('runProcessWithTimeout', () {
    test('returns stdout and exit code for a fast process', () async {
      final result = await runProcessWithTimeout('sh', const [
        '-c',
        'echo hello; exit 3',
      ], timeout: const Duration(seconds: 10));

      expect(result.exitCode, 3);
      expect(result.stdout.toString().trim(), 'hello');
    }, testOn: '!windows');

    test('kills a stuck process and throws a timeout error', () async {
      final stopwatch = Stopwatch()..start();
      Object? error;
      try {
        await runProcessWithTimeout('sh', const [
          '-c',
          'sleep 60',
        ], timeout: const Duration(milliseconds: 300));
      } on Object catch (caught) {
        error = caught;
      }
      stopwatch.stop();

      expect(error, isA<ProcessRunTimeoutException>());
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 10)),
        reason: 'The call must return quickly instead of waiting for sleep.',
      );
    }, testOn: '!windows');

    test('drains large output without deadlocking on pipe buffers', () async {
      final result = await runProcessWithTimeout('sh', const [
        '-c',
        'yes ABCDEFGH | head -c 2000000',
      ], timeout: const Duration(seconds: 30));

      expect(result.exitCode, 0);
      expect(result.stdout.toString().length, 2000000);
    }, testOn: '!windows');
  });
}
