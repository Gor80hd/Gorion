import 'dart:io';

import 'package:path/path.dart' as p;

typedef RuntimeWatchdogLogSink = void Function(String line, {bool isError});

class WindowsRuntimeCleanupWatchdog {
  const WindowsRuntimeCleanupWatchdog();

  Future<void> arm({
    required Directory runtimeDir,
    required int parentPid,
    required int childPid,
    required RuntimeWatchdogLogSink onLog,
  }) async {
    if (!Platform.isWindows) {
      return;
    }

    final scriptFile = File(
      p.join(runtimeDir.path, 'runtime-cleanup-watchdog.ps1'),
    );
    await scriptFile.writeAsString(
      buildWindowsRuntimeCleanupWatchdogScript(
        runtimeDirPath: runtimeDir.path,
        parentPid: parentPid,
        childPid: childPid,
      ),
      flush: true,
    );

    try {
      await Process.start(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-File',
          scriptFile.path,
        ],
        workingDirectory: runtimeDir.path,
        mode: ProcessStartMode.detached,
      );
    } on Object catch (error) {
      onLog(
        'Failed to arm the Windows runtime cleanup watchdog: $error',
        isError: true,
      );
    }
  }
}

String buildWindowsRuntimeCleanupWatchdogScript({
  required String runtimeDirPath,
  required int parentPid,
  required int childPid,
}) {
  final escapedRuntimeDirPath = _escapePowerShellSingleQuotedString(
    runtimeDirPath,
  );
  final template = r'''
$ErrorActionPreference = 'SilentlyContinue'
$parentPid = __PARENT_PID__
$childPid = __CHILD_PID__
$runtimeDir = '__RUNTIME_DIR__'
$runtimeProcessMarkerPath = Join-Path $runtimeDir 'runtime-process.json'
$systemProxyMarkerPath = Join-Path $runtimeDir 'system-proxy.json'

function Normalize-ProxyValue([object] $value) {
  $text = [string]$value
  if ([string]::IsNullOrWhiteSpace($text)) {
    return $null
  }
  return $text.Trim()
}

function Normalize-ProxyHost([string] $host) {
  $normalized = ([string]$host).Trim().ToLowerInvariant()
  switch ($normalized) {
    '127.0.0.1' { return 'loopback' }
    'localhost' { return 'loopback' }
    '::1' { return 'loopback' }
    '0:0:0:0:0:0:0:1' { return 'loopback' }
    default { return $normalized }
  }
}

function Get-ProxyEndpointKeys([object] $value) {
  $normalized = Normalize-ProxyValue $value
  $keys = New-Object 'System.Collections.Generic.HashSet[string]'
  if ([string]::IsNullOrWhiteSpace($normalized)) {
    return @($keys)
  }

  foreach ($entry in ($normalized -split ';')) {
    $candidate = Normalize-ProxyValue $entry
    if ([string]::IsNullOrWhiteSpace($candidate)) {
      continue
    }

    if ($candidate.Contains('=')) {
      $parts = $candidate.Split('=', 2)
      if ($parts.Length -eq 2) {
        $candidate = Normalize-ProxyValue $parts[1]
      }
    }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
      continue
    }

    if (-not $candidate.Contains('://')) {
      $candidate = "http://$candidate"
    }

    try {
      $uri = [Uri]$candidate
    } catch {
      continue
    }

    if ($null -eq $uri -or [string]::IsNullOrWhiteSpace($uri.Host) -or $uri.Port -le 0) {
      continue
    }

    $key = '{0}:{1}' -f (Normalize-ProxyHost $uri.Host), $uri.Port
    [void]$keys.Add($key)
  }

  return @($keys)
}

function Test-ProxyServerTargetsManagedEndpoint([object] $currentProxyServer, [object] $managedProxyServer) {
  $currentKeys = Get-ProxyEndpointKeys $currentProxyServer
  $managedKeys = Get-ProxyEndpointKeys $managedProxyServer
  if ($currentKeys.Count -eq 0 -or $currentKeys.Count -ne $managedKeys.Count) {
    return $false
  }

  foreach ($key in $managedKeys) {
    if ($key -notin $currentKeys) {
      return $false
    }
  }

  return $true
}

function Test-ProcessAlive([int] $processId) {
  if ($processId -le 0) {
    return $false
  }
  return $null -ne (Get-Process -Id $processId -ErrorAction SilentlyContinue)
}

function Get-MarkerPid() {
  if (!(Test-Path $runtimeProcessMarkerPath)) {
    return $null
  }
  try {
    $marker = Get-Content $runtimeProcessMarkerPath -Raw | ConvertFrom-Json
    if ($null -eq $marker) {
      return $null
    }
    return [int]$marker.pid
  } catch {
    return $null
  }
}

function Get-CurrentProxySettings() {
  $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
  $props = Get-ItemProperty -Path $path
  return [pscustomobject]@{
    proxyEnable = [int]($props.ProxyEnable)
    proxyServer = Normalize-ProxyValue $props.ProxyServer
    proxyOverride = Normalize-ProxyValue $props.ProxyOverride
    autoConfigUrl = Normalize-ProxyValue $props.AutoConfigURL
  }
}

function Test-ProxySettingsMatch($left, $right) {
  if ($null -eq $left -or $null -eq $right) {
    return $false
  }
  return [int]$left.proxyEnable -eq [int]$right.proxyEnable -and
    (Normalize-ProxyValue $left.proxyServer) -eq (Normalize-ProxyValue $right.proxyServer) -and
    (Normalize-ProxyValue $left.proxyOverride) -eq (Normalize-ProxyValue $right.proxyOverride) -and
    (Normalize-ProxyValue $left.autoConfigUrl) -eq (Normalize-ProxyValue $right.autoConfigUrl)
}

function Test-ManagedProxySettingsMatch($current, $managed) {
  if (Test-ProxySettingsMatch $current $managed) {
    return $true
  }
  if ($null -eq $current -or $null -eq $managed) {
    return $false
  }
  if ([int]$current.proxyEnable -ne 1 -or [int]$managed.proxyEnable -ne 1) {
    return $false
  }
  return Test-ProxyServerTargetsManagedEndpoint $current.proxyServer $managed.proxyServer
}

function Refresh-WinInet() {
  Add-Type -Namespace Gorion -Name WinInet -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("wininet.dll", SetLastError = true)]
public static extern bool InternetSetOption(System.IntPtr hInternet, int dwOption, System.IntPtr lpBuffer, int dwBufferLength);
"@
  [Gorion.WinInet]::InternetSetOption([System.IntPtr]::Zero, 39, [System.IntPtr]::Zero, 0) | Out-Null
  [Gorion.WinInet]::InternetSetOption([System.IntPtr]::Zero, 37, [System.IntPtr]::Zero, 0) | Out-Null
}

function Apply-ProxySettings($settings) {
  $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
  New-ItemProperty -Path $path -Name ProxyEnable -PropertyType DWord -Value ([int]$settings.proxyEnable) -Force | Out-Null

  $proxyServer = Normalize-ProxyValue $settings.proxyServer
  if ([string]::IsNullOrWhiteSpace($proxyServer)) {
    Remove-ItemProperty -Path $path -Name ProxyServer -ErrorAction SilentlyContinue
  } else {
    New-ItemProperty -Path $path -Name ProxyServer -PropertyType String -Value $proxyServer -Force | Out-Null
  }

  $proxyOverride = Normalize-ProxyValue $settings.proxyOverride
  if ([string]::IsNullOrWhiteSpace($proxyOverride)) {
    Remove-ItemProperty -Path $path -Name ProxyOverride -ErrorAction SilentlyContinue
  } else {
    New-ItemProperty -Path $path -Name ProxyOverride -PropertyType String -Value $proxyOverride -Force | Out-Null
  }

  $autoConfigUrl = Normalize-ProxyValue $settings.autoConfigUrl
  if ([string]::IsNullOrWhiteSpace($autoConfigUrl)) {
    Remove-ItemProperty -Path $path -Name AutoConfigURL -ErrorAction SilentlyContinue
  } else {
    New-ItemProperty -Path $path -Name AutoConfigURL -PropertyType String -Value $autoConfigUrl -Force | Out-Null
  }

  Refresh-WinInet
}

function Cleanup-ProxyState() {
  if (!(Test-Path $systemProxyMarkerPath)) {
    return
  }

  try {
    $marker = Get-Content $systemProxyMarkerPath -Raw | ConvertFrom-Json
    if ($null -eq $marker) {
      return
    }

    $current = Get-CurrentProxySettings
    if (Test-ManagedProxySettingsMatch $current $marker.managedSettings) {
      Apply-ProxySettings $marker.previousSettings
    }
  } catch {
  } finally {
    Remove-Item $systemProxyMarkerPath -Force -ErrorAction SilentlyContinue
  }
}

while ($true) {
  $markerPid = Get-MarkerPid
  if ($null -ne $markerPid -and $markerPid -ne $childPid) {
    break
  }

  if (!(Test-ProcessAlive $parentPid)) {
    if (Test-ProcessAlive $childPid) {
      Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue
    }
    Cleanup-ProxyState
    if ($markerPid -eq $childPid) {
      Remove-Item $runtimeProcessMarkerPath -Force -ErrorAction SilentlyContinue
    }
    break
  }

  if (!(Test-ProcessAlive $childPid)) {
    Cleanup-ProxyState
    if ($markerPid -eq $childPid) {
      Remove-Item $runtimeProcessMarkerPath -Force -ErrorAction SilentlyContinue
    }
    break
  }

  Start-Sleep -Milliseconds 750
}
''';
  return template
      .replaceAll('__PARENT_PID__', parentPid.toString())
      .replaceAll('__CHILD_PID__', childPid.toString())
      .replaceAll('__RUNTIME_DIR__', escapedRuntimeDirPath);
}

String _escapePowerShellSingleQuotedString(String value) {
  return value.replaceAll("'", "''");
}
