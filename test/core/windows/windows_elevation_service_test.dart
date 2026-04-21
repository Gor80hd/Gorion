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

  test('parses a pending zapret config test action from startup args', () {
    final request = AppLaunchRequest.fromArgs(const [
      '--gorion-pending-action=test-zapret-configs',
    ]);

    expect(
      request.pendingElevatedAction,
      PendingElevatedLaunchAction.testZapretConfigs,
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
          '--gorion-pending-action=start-zapret',
          '--bar=baz',
        ]);

    expect(args, ['--foo=bar', gorionLaunchAtStartupArg, '--bar=baz']);
  });
}
