import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/runtime/data/windows_runtime_cleanup_watchdog.dart';

void main() {
  test(
    'buildWindowsRuntimeCleanupWatchdogScript embeds pids and marker paths',
    () {
      final script = buildWindowsRuntimeCleanupWatchdogScript(
        runtimeDirPath: r"C:\Users\O'Brien\AppData\Roaming\gorion\runtime",
        parentPid: 1234,
        childPid: 5678,
      );

      expect(script, contains(r"$parentPid = 1234"));
      expect(script, contains(r"$childPid = 5678"));
      expect(script, contains("O''Brien"));
      expect(script, contains('runtime-process.json'));
      expect(script, contains('system-proxy.json'));
      expect(script, contains('Get-ProxyEndpointKeys'));
      expect(script, contains('Test-ManagedProxySettingsMatch'));
      expect(script, contains(r'Stop-Process -Id $childPid -Force'));
      expect(
        script,
        contains(
          "if (!(Test-ProcessAlive \$childPid)) {\n    Cleanup-ProxyState\n    if (\$markerPid -eq \$childPid) {",
        ),
      );
    },
  );
}
