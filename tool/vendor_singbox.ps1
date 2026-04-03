param(
    [string]$Version = '1.13.5'
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$assetRoot = Join-Path $repoRoot 'assets\singbox'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("gorion-singbox-" + $Version)

$targets = @(
    @{ url = "https://github.com/SagerNet/sing-box/releases/download/v$Version/sing-box-$Version-windows-amd64.zip"; output = 'windows\x64'; binary = 'sing-box.exe' },
    @{ url = "https://github.com/SagerNet/sing-box/releases/download/v$Version/sing-box-$Version-windows-arm64.zip"; output = 'windows\arm64'; binary = 'sing-box.exe' },
    @{ url = "https://github.com/SagerNet/sing-box/releases/download/v$Version/sing-box-$Version-windows-386.zip"; output = 'windows\x86'; binary = 'sing-box.exe' },
    @{ url = "https://github.com/SagerNet/sing-box/releases/download/v$Version/sing-box-$Version-linux-amd64.tar.gz"; output = 'linux\x64'; binary = 'sing-box' },
    @{ url = "https://github.com/SagerNet/sing-box/releases/download/v$Version/sing-box-$Version-linux-arm64.tar.gz"; output = 'linux\arm64'; binary = 'sing-box' },
    @{ url = "https://github.com/SagerNet/sing-box/releases/download/v$Version/sing-box-$Version-darwin-amd64.tar.gz"; output = 'macos\x64'; binary = 'sing-box' },
    @{ url = "https://github.com/SagerNet/sing-box/releases/download/v$Version/sing-box-$Version-darwin-arm64.tar.gz"; output = 'macos\arm64'; binary = 'sing-box' },
    @{ url = "https://github.com/SagerNet/sing-box/releases/download/v$Version/sing-box-$Version-android-arm.tar.gz"; output = 'android\armeabi-v7a'; binary = 'sing-box' },
    @{ url = "https://github.com/SagerNet/sing-box/releases/download/v$Version/sing-box-$Version-android-arm64.tar.gz"; output = 'android\arm64-v8a'; binary = 'sing-box' },
    @{ url = "https://github.com/SagerNet/sing-box/releases/download/v$Version/sing-box-$Version-android-386.tar.gz"; output = 'android\x86'; binary = 'sing-box' },
    @{ url = "https://github.com/SagerNet/sing-box/releases/download/v$Version/sing-box-$Version-android-amd64.tar.gz"; output = 'android\x86_64'; binary = 'sing-box' }
)

function Expand-SingboxArchive {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$DestinationDirectory,
        [Parameter(Mandatory = $true)][string]$BinaryName
    )

    $extractDir = Join-Path $tempRoot ([System.Guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

    if ($ArchivePath.EndsWith('.zip')) {
        Expand-Archive -Path $ArchivePath -DestinationPath $extractDir -Force
    }
    else {
        tar -xzf $ArchivePath -C $extractDir
    }

    $binary = Get-ChildItem -Path $extractDir -Recurse -File | Where-Object { $_.Name -eq $BinaryName } | Select-Object -First 1
    if (-not $binary) {
        throw "Unable to find $BinaryName inside $ArchivePath"
    }

    New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
    Copy-Item -Path $binary.FullName -Destination (Join-Path $DestinationDirectory $BinaryName) -Force
}

New-Item -ItemType Directory -Path $assetRoot -Force | Out-Null
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

$manifestTargets = @()

foreach ($target in $targets) {
    $archiveName = Split-Path $target.url -Leaf
    $archivePath = Join-Path $tempRoot $archiveName
    if (-not (Test-Path $archivePath)) {
        Write-Host "Downloading $archiveName"
        Invoke-WebRequest -Uri $target.url -OutFile $archivePath
    }
    else {
        Write-Host "Using cached $archiveName"
    }

    $destinationDir = Join-Path $assetRoot $target.output
    Expand-SingboxArchive -ArchivePath $archivePath -DestinationDirectory $destinationDir -BinaryName $target.binary
    $manifestTargets += [ordered]@{
        url = $target.url
        output = ($target.output -replace '\\', '/')
        binary = $target.binary
    }
}

$manifest = [ordered]@{
    version = $Version
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    note = 'iOS runtime assets are intentionally not vendored in this phase.'
    targets = $manifestTargets
}

$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $assetRoot 'manifest.json') -Encoding UTF8

Write-Host "Vendored sing-box $Version into $assetRoot"