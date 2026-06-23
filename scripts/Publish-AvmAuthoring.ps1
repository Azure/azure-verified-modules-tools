[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Spec section 17 line 548: the publish script accepts the API key as
    # [SecureString] ONLY. Plain-string callers (e.g. an env var sourced from a
    # CI secret) must wrap with ConvertTo-SecureString -AsPlainText -Force at
    # the call site. The PSResourceGet API takes a plain [string] -ApiKey, so
    # we convert at the boundary below (line 86) with the smallest possible
    # window of plain-text exposure. The conversion lives inside the
    # ShouldProcess branch so -WhatIf / -Confirm:$false dry runs never even
    # extract the secret.
    [Parameter(Mandatory = $true, HelpMessage = 'PowerShell Gallery API key from https://www.powershellgallery.com/account/apikeys')]
    [SecureString] $ApiKey,

    [Parameter()]
    [string] $ModulePath = (Join-Path $PSScriptRoot '..' 'src' 'Avm.Authoring'),

    [Parameter()]
    [string] $Repository = 'PSGallery',

    # Idempotent / re-runnable mode for CI. When the module version is already
    # published on $Repository, warn and return 0 instead of throwing. Local
    # callers omit this so they still get the loud "bump ModuleVersion" error.
    [Parameter()]
    [switch] $SkipIfAlreadyPublished
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Expected casing for the package id. PSGallery locks the displayed casing at
# first publish; we MUST verify the on-disk casing matches because
# Publish-PSResource builds the .nuspec id from the manifest file name as it
# exists on disk, not from the manifest's Name property. Windows/NTFS can
# silently retain old casing when a folder/file is recreated, which is exactly
# how the prior 'Avm' package was published with the wrong display casing.
$ExpectedPackageId   = 'Avm.Authoring'
$ExpectedFolderName  = 'Avm.Authoring'
$ExpectedManifest    = 'Avm.Authoring.psd1'
$ExpectedScript      = 'Avm.Authoring.psm1'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7+ is required (current: $($PSVersionTable.PSVersion))."
}

# Resolve and verify folder casing
$ModulePath = (Resolve-Path -LiteralPath $ModulePath).Path
$actualFolderName = Split-Path -Path $ModulePath -Leaf
if ($actualFolderName -cne $ExpectedFolderName) {
    throw "Folder casing mismatch: expected '$ExpectedFolderName' on disk, found '$actualFolderName'. Rename via 'Rename-Item .\src\$actualFolderName .\src\_tmp_rename; Rename-Item .\src\_tmp_rename .\src\$ExpectedFolderName' before publishing."
}

# Verify file casing inside the module folder
$folderEntries = Get-ChildItem -LiteralPath $ModulePath -Force
$manifestEntry = $folderEntries | Where-Object { $_.Name -ceq $ExpectedManifest }
$scriptEntry   = $folderEntries | Where-Object { $_.Name -ceq $ExpectedScript }
if (-not $manifestEntry) {
    $found = ($folderEntries | Where-Object { $_.Name -ieq $ExpectedManifest }).Name
    throw "Manifest casing mismatch: expected '$ExpectedManifest' on disk, found '$found'. Rename the file before publishing."
}
if (-not $scriptEntry) {
    $found = ($folderEntries | Where-Object { $_.Name -ieq $ExpectedScript }).Name
    throw "Script casing mismatch: expected '$ExpectedScript' on disk, found '$found'. Rename the file before publishing."
}

$manifestPath = $manifestEntry.FullName

Write-Host "Validating manifest at $manifestPath" -ForegroundColor Cyan
$manifest = Test-ModuleManifest -Path $manifestPath
Write-Host ("  Name    : {0}" -f $manifest.Name)
Write-Host ("  Version : {0}" -f $manifest.Version)
Write-Host ("  GUID    : {0}" -f $manifest.Guid)
Write-Host ("  Author  : {0}" -f $manifest.Author)

if ($manifest.Name -cne $ExpectedPackageId) {
    throw "Manifest Name casing mismatch: expected '$ExpectedPackageId', got '$($manifest.Name)'. Check the .psd1 file name on disk."
}

if (-not (Get-Module -ListAvailable -Name Microsoft.PowerShell.PSResourceGet)) {
    Write-Host 'Installing Microsoft.PowerShell.PSResourceGet for CurrentUser' -ForegroundColor Cyan
    Install-Module -Name Microsoft.PowerShell.PSResourceGet -Scope CurrentUser -Force -AllowClobber
}
Import-Module Microsoft.PowerShell.PSResourceGet -Force

Write-Host "Checking whether '$ExpectedPackageId' is already published on $Repository" -ForegroundColor Cyan
$existing = Find-PSResource -Name $ExpectedPackageId -Repository $Repository -ErrorAction SilentlyContinue
if ($existing) {
    $latestPublished = [string]$existing.Version
    if ($latestPublished -eq [string]$manifest.Version) {
        $alreadyMsg = "Module '$ExpectedPackageId' version $($manifest.Version) is already published on $Repository (latest: $latestPublished)."
        if ($SkipIfAlreadyPublished) {
            Write-Warning "$alreadyMsg Skipping publish (idempotent re-run)."
            return
        }
        throw "$alreadyMsg Bump ModuleVersion in $ExpectedManifest before re-running."
    }
    Write-Host ("  Latest published version: {0}" -f $latestPublished) -ForegroundColor Yellow
    Write-Host ("  About to publish new version: {0}" -f $manifest.Version) -ForegroundColor Cyan
}
else {
    Write-Host '  Name is available (first publish).' -ForegroundColor Green
}

if ($PSCmdlet.ShouldProcess("$ExpectedPackageId $($manifest.Version)", "Publish to $Repository")) {
    Write-Host "Publishing $ExpectedPackageId $($manifest.Version) to $Repository" -ForegroundColor Cyan
    # PSResourceGet's -ApiKey parameter takes a plain [string], not a
    # [SecureString], so we must convert at the boundary. Keep the plain-text
    # window as short as possible: extract, hand to Publish-PSResource, drop
    # the variable. (Spec section 17 line 549: no plain-text on disk; this
    # transient in-memory string is destroyed when the function frame unwinds.)
    $plainApiKey = ConvertFrom-SecureString -SecureString $ApiKey -AsPlainText
    try {
        Publish-PSResource -Path $ModulePath -Repository $Repository -ApiKey $plainApiKey -Verbose
    }
    finally {
        $plainApiKey = $null
    }
    Write-Host 'Publish complete. It may take a few minutes to appear in the gallery.' -ForegroundColor Green
    Write-Host ("View at https://www.powershellgallery.com/packages/{0}" -f $ExpectedPackageId)
}
