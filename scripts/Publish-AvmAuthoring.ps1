#Requires -Version 7.4

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^v\d+\.\d+\.\d+$')]
    [string] $ReleaseTag,

    [Parameter(Mandatory = $true)]
    [string] $ArtifactPath,

    [Parameter(Mandatory = $true)]
    [SecureString] $ApiKey,

    [Parameter()]
    [string] $Repository = 'PSGallery',

    [Parameter()]
    [switch] $SkipIfAlreadyPublished
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$packageId = 'Avm.Authoring'
$version = $ReleaseTag.Substring(1)
$artifactPath = (Resolve-Path -LiteralPath $ArtifactPath).Path
$archiveName = "$packageId-$version.zip"
$archivePath = Join-Path $artifactPath $archiveName
$sumsPath = Join-Path $artifactPath 'SHA256SUMS'

if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    throw "Release archive '$archiveName' was not found in '$artifactPath'."
}
if (-not (Test-Path -LiteralPath $sumsPath -PathType Leaf)) {
    throw "Checksum file 'SHA256SUMS' was not found in '$artifactPath'."
}

$sumLines = @(
    [System.IO.File]::ReadAllLines($sumsPath) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
if ($sumLines.Count -ne 1) {
    throw "SHA256SUMS must contain exactly one non-empty checksum line; found $($sumLines.Count)."
}

$sumPattern = '^(?<hash>[a-fA-F0-9]{64}) \*' + [regex]::Escape($archiveName) + '$'
$sumMatch = [regex]::Match($sumLines[0], $sumPattern)
if (-not $sumMatch.Success) {
    throw "SHA256SUMS does not contain the expected entry for '$archiveName'."
}

$expectedHash = $sumMatch.Groups['hash'].Value.ToLowerInvariant()
$actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualHash -cne $expectedHash) {
    throw "Checksum mismatch for '$archiveName': expected $expectedHash, got $actualHash."
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
try {
    $entries = @($archive.Entries)
    if ($entries.Count -eq 0) {
        throw "Release archive '$archiveName' is empty."
    }

    $entryNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $requiredEntries = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    $requiredEntries.Add('Avm.Authoring/Avm.Authoring.psd1') | Out-Null
    $requiredEntries.Add('Avm.Authoring/Avm.Authoring.psm1') | Out-Null

    foreach ($entry in $entries) {
        $entryName = $entry.FullName
        if ([string]::IsNullOrWhiteSpace($entryName) -or
            $entryName.Contains('\') -or
            $entryName.StartsWith('/') -or
            -not $entryName.StartsWith('Avm.Authoring/', [System.StringComparison]::Ordinal)) {
            throw "Unsafe or unexpected archive entry '$entryName'."
        }

        $segments = $entryName.Split(
            [char[]]@('/'),
            [System.StringSplitOptions]::RemoveEmptyEntries
        )
        if ($segments -contains '..' -or $segments -contains '.') {
            throw "Unsafe archive entry '$entryName'."
        }
        if (-not $entryNames.Add($entryName)) {
            throw "Archive contains a duplicate or case-colliding entry '$entryName'."
        }

        $unixFileType = ($entry.ExternalAttributes -shr 16) -band 0xF000
        if ($unixFileType -eq 0xA000) {
            throw "Archive contains unsupported symbolic link '$entryName'."
        }

        $requiredEntries.Remove($entryName) | Out-Null
    }

    if ($requiredEntries.Count -gt 0) {
        throw "Archive is missing required module entries: $($requiredEntries -join ', ')."
    }
}
finally {
    $archive.Dispose()
}

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "avm-publish-$([Guid]::NewGuid().ToString('N'))"
try {
    New-Item -ItemType Directory -Path $temporaryRoot -WhatIf:$false | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $temporaryRoot)

    $rootEntries = @(Get-ChildItem -LiteralPath $temporaryRoot -Force)
    $moduleEntry = @($rootEntries | Where-Object { $_.Name -ceq $packageId -and $_.PSIsContainer })
    if ($rootEntries.Count -ne 1 -or $moduleEntry.Count -ne 1) {
        throw "Archive root must contain only the '$packageId' module folder."
    }

    $modulePath = $moduleEntry[0].FullName
    $moduleEntries = @(Get-ChildItem -LiteralPath $modulePath -Force)
    $manifestEntry = @($moduleEntries | Where-Object { $_.Name -ceq "$packageId.psd1" -and -not $_.PSIsContainer })
    $scriptEntry = @($moduleEntries | Where-Object { $_.Name -ceq "$packageId.psm1" -and -not $_.PSIsContainer })
    if ($manifestEntry.Count -ne 1 -or $scriptEntry.Count -ne 1) {
        throw "Module folder must contain '$packageId.psd1' and '$packageId.psm1' with exact casing."
    }

    $manifestData = Import-PowerShellDataFile -LiteralPath $manifestEntry[0].FullName
    if ([string]$manifestData.ModuleVersion -cne $version) {
        throw "Manifest version '$($manifestData.ModuleVersion)' does not match release version '$version'."
    }
    if ([string]$manifestData.RootModule -cne "$packageId.psm1") {
        throw "Manifest RootModule must be '$packageId.psm1', found '$($manifestData.RootModule)'."
    }

    $manifest = Test-ModuleManifest -Path $manifestEntry[0].FullName
    if ($manifest.Name -cne $packageId) {
        throw "Manifest package id must be '$packageId', found '$($manifest.Name)'."
    }

    $powerShellFiles = @(
        Get-ChildItem -LiteralPath $modulePath -Recurse -File |
            Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1') }
    )
    if ($powerShellFiles.Count -eq 0) {
        throw "No PowerShell files were found in '$archiveName'."
    }

    $unsignedFiles = @()
    foreach ($file in $powerShellFiles) {
        $content = [System.IO.File]::ReadAllText($file.FullName)
        $beginIndex = $content.IndexOf(
            '# SIG # Begin signature block',
            [System.StringComparison]::Ordinal
        )
        $endIndex = $content.LastIndexOf(
            '# SIG # End signature block',
            [System.StringComparison]::Ordinal
        )
        if ($beginIndex -lt 0 -or $endIndex -le $beginIndex) {
            $unsignedFiles += $file.FullName.Substring($modulePath.Length).TrimStart('\', '/')
        }
    }
    if ($unsignedFiles.Count -gt 0) {
        throw "Release archive contains unsigned PowerShell files: $($unsignedFiles -join ', ')."
    }

    Write-Host "Validated signed $packageId $version ($($powerShellFiles.Count) PowerShell files)."

    if ($PSCmdlet.ShouldProcess("$packageId $version", "Publish to $Repository")) {
        $psResourceGet = Get-Module -ListAvailable -Name 'Microsoft.PowerShell.PSResourceGet' |
            Sort-Object Version -Descending |
            Select-Object -First 1
        if (-not $psResourceGet) {
            throw 'Microsoft.PowerShell.PSResourceGet is required to publish the module.'
        }
        Import-Module 'Microsoft.PowerShell.PSResourceGet' -Force

        $existing = Find-PSResource `
            -Name $packageId `
            -Version $version `
            -Repository $Repository `
            -ErrorAction SilentlyContinue
        if ($existing) {
            $message = "$packageId $version is already published on $Repository."
            if ($SkipIfAlreadyPublished) {
                Write-Warning "$message Skipping publish."
                return
            }
            throw $message
        }

        $plainApiKey = ConvertFrom-SecureString -SecureString $ApiKey -AsPlainText
        try {
            Publish-PSResource `
                -Path $modulePath `
                -Repository $Repository `
                -ApiKey $plainApiKey `
                -Verbose
        }
        finally {
            $plainApiKey = $null
        }
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item `
            -LiteralPath $temporaryRoot `
            -Recurse `
            -Force `
            -WhatIf:$false `
            -ProgressAction SilentlyContinue
    }
}
