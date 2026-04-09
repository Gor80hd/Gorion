import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/core/windows/windows_elevation_service.dart';

void main() {
  test('parses a pending elevated launch action from startup args', () {
    final request = AppLaunchRequest.fromArgs(const [
      '--foo=bar',
      '--gorion-pending-action=start-zapret',
    ]);

    expect(
      request.pendingElevatedAction,
      PendingElevatedLaunchAction.startZapret,
    );
    expect(request.resumesAfterElevation, isTrue);
  });
}
