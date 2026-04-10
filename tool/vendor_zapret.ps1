param(
    [string]$Version = '0.9.4.7'
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$assetRoot = Join-Path $repoRoot 'assets\zapret'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("gorion-zapret-" + $Version)
$tag = "v$Version"
$archiveName = "zapret2-$tag.zip"
$archiveUrl = "https://github.com/bol-van/zapret2/releases/download/$tag/$archiveName"
$archivePath = Join-Path $tempRoot $archiveName

$targets = @(
    @{
        output = 'windows\x64'
        binaryRoot = 'binaries/windows-x86_64'
        files = @('winws2.exe', 'cygwin1.dll', 'WinDivert.dll', 'WinDivert64.sys', 'mdig.exe', 'ip2net.exe', 'killall.exe')
    },
    @{
        output = 'windows\x86'
        binaryRoot = 'binaries/windows-x86'
        files = @('winws2.exe', 'cygwin1.dll', 'WinDivert.dll', 'WinDivert32.sys', 'mdig.exe', 'ip2net.exe', 'killall.exe')
    }
)

$sharedPrefixes = @(
    'lua/',
    'files/fake/',
    'init.d/windivert.filter.examples/'
)

$youtubeHostlist = @(
    'youtube.com',
    'www.youtube.com',
    'm.youtube.com',
    'youtu.be',
    'youtubei.googleapis.com',
    'ytimg.com',
    'yt3.ggpht.com',
    'googlevideo.com',
    'youtube-nocookie.com'
)

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Write-ZipEntryToFile {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    New-Item -ItemType Directory -Path (Split-Path -Parent $DestinationPath) -Force | Out-Null

    $entryStream = $Entry.Open()
    $fileStream = [System.IO.File]::Open($DestinationPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    try {
        $entryStream.CopyTo($fileStream)
    }
    finally {
        $fileStream.Dispose()
        $entryStream.Dispose()
    }
}

function Extract-ZipPrefix {
    param(
        [Parameter(Mandatory = $true)]$Archive,
        [Parameter(Mandatory = $true)][string]$ArchiveRoot,
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$DestinationRoot
    )

    $fullPrefix = "$ArchiveRoot$Prefix"
    $entries = $Archive.Entries | Where-Object {
        $_.FullName.StartsWith($fullPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $_.FullName.EndsWith('/')
    }

    foreach ($entry in $entries) {
        $relative = $entry.FullName.Substring($fullPrefix.Length)
        $destinationPath = Join-Path $DestinationRoot ($relative -replace '/', '\\')
        Write-ZipEntryToFile -Entry $entry -DestinationPath $destinationPath
    }
}

function Extract-ZipFile {
    param(
        [Parameter(Mandatory = $true)]$Archive,
        [Parameter(Mandatory = $true)][string]$EntryPath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    $entry = $Archive.Entries | Where-Object { $_.FullName -eq $EntryPath } | Select-Object -First 1
    if (-not $entry) {
        throw "Unable to find $EntryPath inside $archiveName"
    }

    Write-ZipEntryToFile -Entry $entry -DestinationPath $DestinationPath
}

New-Item -ItemType Directory -Path $assetRoot -Force | Out-Null
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

if (-not (Test-Path $archivePath)) {
    Write-Host "Downloading $archiveName"
    Invoke-WebRequest -Uri $archiveUrl -OutFile $archivePath
}
else {
    Write-Host "Using cached $archiveName"
}

$archive = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
try {
    $archiveRootEntry = $archive.Entries | Select-Object -First 1
    if (-not $archiveRootEntry) {
        throw "Archive $archiveName is empty"
    }

    $archiveRoot = ($archiveRootEntry.FullName.Split('/')[0]) + '/'
    $commonRoot = Join-Path $assetRoot 'common'
    if (Test-Path $commonRoot) {
        Remove-Item -Path $commonRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $commonRoot -Force | Out-Null

    foreach ($prefix in $sharedPrefixes) {
        $sharedDestinationRoot = Join-Path $commonRoot (($prefix.TrimEnd('/')) -replace '/', '\\')
        Extract-ZipPrefix -Archive $archive -ArchiveRoot $archiveRoot -Prefix $prefix -DestinationRoot $sharedDestinationRoot
    }

    $youtubeListPath = Join-Path $commonRoot 'files\list-youtube.txt'
    New-Item -ItemType Directory -Path (Split-Path -Parent $youtubeListPath) -Force | Out-Null
    $youtubeHostlist | Set-Content -Path $youtubeListPath -Encoding UTF8

    $ipsetAllPath = Join-Path $commonRoot 'files\ipset-all.txt'
    @(
        '0.0.0.0/0',
        '::/0'
    ) | Set-Content -Path $ipsetAllPath -Encoding UTF8

    $manifestTargets = @()

    foreach ($target in $targets) {
        $destinationRoot = Join-Path $assetRoot $target.output
        if (Test-Path $destinationRoot) {
            Remove-Item -Path $destinationRoot -Recurse -Force
        }
        New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null

        foreach ($fileName in $target.files) {
            $entryPath = "$archiveRoot$($target.binaryRoot)/$fileName"
            $destinationPath = Join-Path $destinationRoot ($target.binaryRoot -replace '/', '\\')
            $destinationPath = Join-Path $destinationPath $fileName
            Extract-ZipFile -Archive $archive -EntryPath $entryPath -DestinationPath $destinationPath
        }

        $manifestTargets += [ordered]@{
            output = ($target.output -replace '\\', '/')
            binaryRoot = $target.binaryRoot
            files = $target.files
        }
    }

    $manifest = [ordered]@{
        version = $Version
        sourceUrl = $archiveUrl
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        sharedPrefixes = $sharedPrefixes
        generatedFiles = @('files/list-youtube.txt', 'files/ipset-all.txt')
        targets = $manifestTargets
    }

    $manifest | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $assetRoot 'manifest.json') -Encoding UTF8
}
finally {
    $archive.Dispose()
}

Write-Host "Vendored zapret2 $Version into $assetRoot"
