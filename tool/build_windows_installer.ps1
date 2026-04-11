[CmdletBinding()]
param(
    [string]$AppName = 'Gorion',
    [string]$Publisher = 'Gorion',
    [string]$ExeName = 'gorion_clean.exe',
    [string]$FlutterOutputDir = 'build\windows\x64\runner\Release',
    [string]$InstallerScript = 'installer\windows\gorion_windows_installer.iss',
    [string]$OutputDir = 'dist\windows-installer',
    [switch]$SkipFlutterBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-AppVersion {
    param(
        [string]$PubspecPath
    )

    $versionLine = Select-String -Path $PubspecPath -Pattern '^\s*version:\s*([0-9]+\.[0-9]+\.[0-9]+)(?:\+\d+)?\s*$' |
        Select-Object -First 1

    if (-not $versionLine) {
        throw "Не удалось найти строку version: в $PubspecPath"
    }

    return $versionLine.Matches[0].Groups[1].Value
}

function Find-InnoCompiler {
    $candidates = @(
        'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
        'C:\Program Files\Inno Setup 6\ISCC.exe'
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    throw "Inno Setup 6 не найден. Установите его с https://jrsoftware.org/isdl.php"
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$pubspecPath = Join-Path $repoRoot 'pubspec.yaml'
$resolvedOutputDir = Join-Path $repoRoot $OutputDir
$resolvedFlutterOutputDir = Join-Path $repoRoot $FlutterOutputDir
$resolvedInstallerScript = Join-Path $repoRoot $InstallerScript
$version = Get-AppVersion -PubspecPath $pubspecPath

if (-not $SkipFlutterBuild) {
    Write-Host "==> Flutter release build"
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) {
        throw "flutter build windows --release завершился с ошибкой."
    }
}

if (-not (Test-Path $resolvedFlutterOutputDir)) {
    throw "Каталог сборки не найден: $resolvedFlutterOutputDir"
}

if (-not (Test-Path (Join-Path $resolvedFlutterOutputDir $ExeName))) {
    throw "Не найден исполняемый файл: $(Join-Path $resolvedFlutterOutputDir $ExeName)"
}

if (-not (Test-Path $resolvedInstallerScript)) {
    throw "Не найден Inno Setup script: $resolvedInstallerScript"
}

$null = New-Item -ItemType Directory -Path $resolvedOutputDir -Force
$iscc = Find-InnoCompiler

Write-Host "==> Inno Setup packaging"
& $iscc `
    "/DAppName=$AppName" `
    "/DAppPublisher=$Publisher" `
    "/DAppExeName=$ExeName" `
    "/DAppVersion=$version" `
    "/DSourceDir=$resolvedFlutterOutputDir" `
    "/DOutputDir=$resolvedOutputDir" `
    $resolvedInstallerScript

if ($LASTEXITCODE -ne 0) {
    throw "Сборка установщика завершилась с ошибкой."
}

Write-Host ""
Write-Host "Готово."
Write-Host "Инсталлятор лежит в: $resolvedOutputDir"
