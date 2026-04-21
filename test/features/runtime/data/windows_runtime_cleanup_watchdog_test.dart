import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/runtime/data/windows_runtime_cleanup_watchdog.dart';

void main() {
  test('buildWindowsRuntimeCleanupWatchdogScript embeds pids and marker paths', () {
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
    expect(script, contains('winhttp-proxy.json'));
    expect(script, contains('Get-ProxyEndpointKeys'));
    expect(script, contains('Get-BypassListKeys'));
    expect(script, contains('Test-BypassListMatch'));
    expect(script, contains('Test-ManagedProxySettingsMatch'));
    expect(script, contains('Test-ManagedWinHttpSettingsMatch'));
    expect(
      script,
      contains(
        r'(Test-BypassListMatch $left.proxyOverride $right.proxyOverride)',
      ),
    );
    expect(
      script,
      contains(
        r'if (!(Test-BypassListMatch $current.proxyOverride $managed.proxyOverride)) {',
      ),
    );
    expect(
      script,
      contains(
        r'if (!(Test-BypassListMatch $current.bypassList $managed.bypassList)) {',
      ),
    );
    expect(script, contains('Get-WinHttpProxySettings'));
    expect(script, contains(r"if ($LASTEXITCODE -ne 0) {"));
    expect(script, contains(r'function Invoke-Netsh([string[]] $arguments) {'));
    expect(script, contains(r'^\s+\S.*?:\s*(.*?)\s*$'));
    expect(script, contains("if (\$null -eq \$current) {\n      return"));
    expect(
      script,
      contains(
        "if (Apply-WinHttpProxySettings \$marker.previousSettings) {\n        \$shouldDeleteMarker = \$true",
      ),
    );
    expect(script, contains('Cleanup-OwnedRuntimeState'));
    expect(script, contains(r'$shouldDeleteMarker = $false'));
    expect(
      script,
      contains(
        "if (\$shouldDeleteMarker) {\n      Remove-Item \$systemProxyMarkerPath -Force -ErrorAction SilentlyContinue\n    }",
      ),
    );
    expect(
      script,
      contains(
        "if (\$shouldDeleteMarker) {\n      Remove-Item \$winHttpProxyMarkerPath -Force -ErrorAction SilentlyContinue\n    }",
      ),
    );
    expect(
      script,
      contains(
        "function Cleanup-OwnedRuntimeState([object] \$markerPid) {\n  if (\$null -ne \$markerPid -and \$markerPid -ne \$childPid) {\n    return",
      ),
    );
    expect(
      script,
      contains(
        "Cleanup-ProxyState\n  Cleanup-WinHttpProxyState\n  if (\$markerPid -eq \$childPid) {\n    Remove-Item \$runtimeProcessMarkerPath",
      ),
    );
    expect(script, contains(r'Stop-Process -Id $childPid -Force'));
    expect(
      script,
      contains(
        "if (!(Test-ProcessAlive \$childPid)) {\n    Cleanup-OwnedRuntimeState \$markerPid\n    break",
      ),
    );
    expect(
      script,
      contains(
        "if (!(Test-ProcessAlive \$parentPid)) {\n    if (Test-ProcessAlive \$childPid) {\n      Stop-Process -Id \$childPid -Force -ErrorAction SilentlyContinue\n    }\n    Cleanup-OwnedRuntimeState \$markerPid",
      ),
    );
    expect(
      script.indexOf(r"if (!(Test-ProcessAlive $parentPid)) {"),
      lessThan(
        script.indexOf(
          "if (\$null -ne \$markerPid -and \$markerPid -ne \$childPid) {\n    break",
        ),
      ),
    );
    expect(
      script.indexOf(r"if (!(Test-ProcessAlive $childPid)) {"),
      lessThan(
        script.indexOf(
          "if (\$null -ne \$markerPid -and \$markerPid -ne \$childPid) {\n    break",
        ),
      ),
    );
  });
}
