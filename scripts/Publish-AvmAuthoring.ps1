[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'PowerShell Gallery API key from https://www.powershellgallery.com/account/apikeys')]
    [string] $ApiKey,

    [Parameter()]
    [string] $ModulePath = (Join-Path $PSScriptRoot '..' 'src' 'Avm.Authoring'),

    [Parameter()]
    [string] $Repository = 'PSGallery'
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
        throw "Module '$ExpectedPackageId' version $($manifest.Version) is already published on $Repository (latest: $latestPublished). Bump ModuleVersion in $ExpectedManifest before re-running."
    }
    Write-Host ("  Latest published version: {0}" -f $latestPublished) -ForegroundColor Yellow
    Write-Host ("  About to publish new version: {0}" -f $manifest.Version) -ForegroundColor Cyan
}
else {
    Write-Host '  Name is available (first publish).' -ForegroundColor Green
}

if ($PSCmdlet.ShouldProcess("$ExpectedPackageId $($manifest.Version)", "Publish to $Repository")) {
    Write-Host "Publishing $ExpectedPackageId $($manifest.Version) to $Repository" -ForegroundColor Cyan
    Publish-PSResource -Path $ModulePath -Repository $Repository -ApiKey $ApiKey -Verbose
    Write-Host 'Publish complete. It may take a few minutes to appear in the gallery.' -ForegroundColor Green
    Write-Host ("View at https://www.powershellgallery.com/packages/{0}" -f $ExpectedPackageId)
}
