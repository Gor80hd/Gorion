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
$winHttpProxyMarkerPath = Join-Path $runtimeDir 'winhttp-proxy.json'

function Normalize-ProxyValue([object] $value) {
  $text = [string]$value
  if ([string]::IsNullOrWhiteSpace($text)) {
    return $null
  }
  return $text.Trim()
}

function Get-BypassListKeys([object] $value) {
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
    [void]$keys.Add($candidate.ToLowerInvariant())
  }

  return @($keys)
}

function Test-BypassListMatch($left, $right) {
  $leftKeys = Get-BypassListKeys $left
  $rightKeys = Get-BypassListKeys $right
  if ($leftKeys.Count -ne $rightKeys.Count) {
    return $false
  }

  foreach ($key in $rightKeys) {
    if ($key -notin $leftKeys) {
      return $false
    }
  }

  return $true
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
    (Test-BypassListMatch $left.proxyOverride $right.proxyOverride) -and
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
  if (!(Test-BypassListMatch $current.proxyOverride $managed.proxyOverride)) {
    return $false
  }
  if ((Normalize-ProxyValue $current.autoConfigUrl) -ne (Normalize-ProxyValue $managed.autoConfigUrl)) {
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

function Get-WinHttpProxySettings() {
  $output = (& netsh.exe winhttp show proxy 2>$null | Out-String)
  if ($LASTEXITCODE -ne 0) {
    return $null
  }
  $normalized = ([string]$output) -replace "`r", ''
  if ($normalized.Contains('Direct access (no proxy server).') -or $normalized.Contains('Прямой доступ (без прокси-сервера).')) {
    return [pscustomobject]@{
      proxyServer = $null
      bypassList = $null
    }
  }

  $proxyMatch = [regex]::Match(
    $normalized,
    '^\s*Proxy Server\(s\)\s*:\s*(.+?)\s*$',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline
  )
  $bypassMatch = [regex]::Match(
    $normalized,
    '^\s*Bypass List\s*:\s*(.*?)\s*$',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline
  )
  $proxyServer = if ($proxyMatch.Success) { Normalize-ProxyValue $proxyMatch.Groups[1].Value } else { $null }
  $bypassList = if ($bypassMatch.Success) { Normalize-ProxyValue $bypassMatch.Groups[1].Value } else { $null }
  if ($null -eq $proxyServer -and $null -eq $bypassList) {
    $genericMatches = [regex]::Matches(
      $normalized,
      '^\s+\S.*?:\s*(.*?)\s*$',
      [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline
    )
    if ($genericMatches.Count -ge 1) {
      $proxyServer = Normalize-ProxyValue $genericMatches[0].Groups[1].Value
    }
    if ($genericMatches.Count -ge 2) {
      $bypassList = Normalize-ProxyValue $genericMatches[1].Groups[1].Value
    }
  }

  return [pscustomobject]@{
    proxyServer = $proxyServer
    bypassList = $bypassList
  }
}

function Test-WinHttpSettingsMatch($left, $right) {
  if ($null -eq $left -or $null -eq $right) {
    return $false
  }
  return (Normalize-ProxyValue $left.proxyServer) -eq (Normalize-ProxyValue $right.proxyServer) -and
    (Test-BypassListMatch $left.bypassList $right.bypassList)
}

function Test-ManagedWinHttpSettingsMatch($current, $managed) {
  if (Test-WinHttpSettingsMatch $current $managed) {
    return $true
  }
  if ($null -eq $current -or $null -eq $managed) {
    return $false
  }
  if (!(Test-BypassListMatch $current.bypassList $managed.bypassList)) {
    return $false
  }
  return Test-ProxyServerTargetsManagedEndpoint $current.proxyServer $managed.proxyServer
}

function Invoke-Netsh([string[]] $arguments) {
  & netsh.exe @arguments | Out-Null
  return $LASTEXITCODE -eq 0
}

function Apply-WinHttpProxySettings($settings) {
  $proxyServer = Normalize-ProxyValue $settings.proxyServer
  if ([string]::IsNullOrWhiteSpace($proxyServer)) {
    return Invoke-Netsh -arguments @('winhttp', 'reset', 'proxy')
  }

  $arguments = @(
    'winhttp',
    'set',
    'proxy',
    "proxy-server=$proxyServer"
  )
  $bypassList = Normalize-ProxyValue $settings.bypassList
  if (-not [string]::IsNullOrWhiteSpace($bypassList)) {
    $arguments += "bypass-list=$bypassList"
  }

  return Invoke-Netsh -arguments $arguments
}

function Cleanup-ProxyState() {
  if (!(Test-Path $systemProxyMarkerPath)) {
    return
  }

  $shouldDeleteMarker = $false
  try {
    $marker = Get-Content $systemProxyMarkerPath -Raw | ConvertFrom-Json
    if ($null -eq $marker) {
      return
    }

    $current = Get-CurrentProxySettings
    if (Test-ManagedProxySettingsMatch $current $marker.managedSettings) {
      Apply-ProxySettings $marker.previousSettings
      $shouldDeleteMarker = $true
    } else {
      $shouldDeleteMarker = $true
    }
  } catch {
  } finally {
    if ($shouldDeleteMarker) {
      Remove-Item $systemProxyMarkerPath -Force -ErrorAction SilentlyContinue
    }
  }
}

function Cleanup-WinHttpProxyState() {
  if (!(Test-Path $winHttpProxyMarkerPath)) {
    return
  }

  $shouldDeleteMarker = $false
  try {
    $marker = Get-Content $winHttpProxyMarkerPath -Raw | ConvertFrom-Json
    if ($null -eq $marker) {
      return
    }

    $current = Get-WinHttpProxySettings
    if ($null -eq $current) {
      return
    }
    if (Test-ManagedWinHttpSettingsMatch $current $marker.managedSettings) {
      if (Apply-WinHttpProxySettings $marker.previousSettings) {
        $shouldDeleteMarker = $true
      }
    } else {
      $shouldDeleteMarker = $true
    }
  } catch {
  } finally {
    if ($shouldDeleteMarker) {
      Remove-Item $winHttpProxyMarkerPath -Force -ErrorAction SilentlyContinue
    }
  }
}

function Cleanup-OwnedRuntimeState([object] $markerPid) {
  if ($null -ne $markerPid -and $markerPid -ne $childPid) {
    return
  }
  Cleanup-ProxyState
  Cleanup-WinHttpProxyState
  if ($markerPid -eq $childPid) {
    Remove-Item $runtimeProcessMarkerPath -Force -ErrorAction SilentlyContinue
  }
}

while ($true) {
  $markerPid = Get-MarkerPid
  if (!(Test-ProcessAlive $parentPid)) {
    if (Test-ProcessAlive $childPid) {
      Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue
    }
    Cleanup-OwnedRuntimeState $markerPid
    break
  }

  if (!(Test-ProcessAlive $childPid)) {
    Cleanup-OwnedRuntimeState $markerPid
    break
  }

  if ($null -ne $markerPid -and $markerPid -ne $childPid) {
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
