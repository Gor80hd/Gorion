import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/core/windows/privileged_helper_protocol.dart';

void main() {
  test('PrivilegedHelperConnectionInfo round-trips persisted launch state', () {
    const info = PrivilegedHelperConnectionInfo(
      token: 'secret-token',
      host: '127.0.0.1',
      port: 47653,
      pid: 4242,
      launchId: 'launch-123',
      lastError: 'bind failed',
    );

    final json = info.toJson();

    expect(
      PrivilegedHelperConnectionInfo.fromJson(json),
      isA<PrivilegedHelperConnectionInfo>()
          .having((value) => value.token, 'token', 'secret-token')
          .having((value) => value.host, 'host', '127.0.0.1')
          .having((value) => value.port, 'port', 47653)
          .having((value) => value.pid, 'pid', 4242)
          .having((value) => value.launchId, 'launchId', 'launch-123')
          .having((value) => value.lastError, 'lastError', 'bind failed'),
    );
  });

  test(
    'PrivilegedHelperBootstrapRequest round-trips launch bootstrap data',
    () {
      final request = PrivilegedHelperBootstrapRequest(
        token: 'secret-token',
        launchId: 'launch-abc',
        createdAt: DateTime.parse('2026-04-20T12:34:56Z'),
        clientPid: 31415,
      );

      expect(
        PrivilegedHelperBootstrapRequest.fromJson(request.toJson()),
        isA<PrivilegedHelperBootstrapRequest>()
            .having((value) => value.token, 'token', 'secret-token')
            .having((value) => value.launchId, 'launchId', 'launch-abc')
            .having(
              (value) => value.createdAt.toUtc().toIso8601String(),
              'createdAt',
              '2026-04-20T12:34:56.000Z',
            )
            .having((value) => value.clientPid, 'clientPid', 31415),
      );
    },
  );
}
