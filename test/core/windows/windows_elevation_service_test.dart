import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/core/windows/windows_elevation_service.dart';

void main() {
  test('parses a pending elevated launch action from startup args', () {
    final request = AppLaunchRequest.fromArgs(const [
      '--foo=bar',
      '--gorion-pending-action=connect-tun',
    ]);

    expect(
      request.pendingElevatedAction,
      PendingElevatedLaunchAction.connectTun,
    );
    expect(request.resumesAfterElevation, isTrue);
  });

  test('parses the launch-at-startup marker from startup args', () {
    final request = AppLaunchRequest.fromArgs(const [
      '--foo=bar',
      gorionLaunchAtStartupArg,
    ]);

    expect(request.launchedAtStartup, isTrue);
    expect(request.pendingElevatedAction, isNull);
    expect(request.resumesAfterElevation, isFalse);
  });

  test('strips only pending-action args from elevated relaunches', () {
    final args =
        PowerShellWindowsElevationService.sanitizeArgsForRelaunch(const [
          '--foo=bar',
          gorionLaunchAtStartupArg,
          '--gorion-pending-action=connect-tun',
          '--bar=baz',
        ]);

    expect(args, ['--foo=bar', gorionLaunchAtStartupArg, '--bar=baz']);
  });
}
