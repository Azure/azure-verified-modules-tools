#Requires -Version 7.4

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param([switch] $Apply)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'LabelCatalog.ps1')
. (Join-Path $PSScriptRoot 'LabelSync.ps1')

$toolsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..'))
$labels = @(Read-AvmStandardGitHubLabels -Path (Join-Path $PSScriptRoot '..' 'avm-standard-github-labels.json'))

if ($Apply -and -not $WhatIfPreference -and
    ($env:GITHUB_ACTIONS -cne 'true' -or $env:GITHUB_REPOSITORY -cne 'Azure/azure-verified-modules-tools' -or
        $env:GITHUB_REF -cne 'refs/heads/main' -or $env:AVM_APP_SLUG -cne 'azure-verified-modules' -or
        -not $env:GH_TOKEN)) {
    throw [System.InvalidOperationException]::new('Applying labels requires the trusted tools main-branch workflow and its scoped GitHub App token.')
}

$null = Import-Module -Name (Join-Path $toolsRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -PassThru -ErrorAction Stop
$gh = (Get-Command -Name gh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$repositories = @('Azure/Azure-Verified-Modules', 'Azure/bicep-registry-modules')
Invoke-AvmStandardGitHubLabelSync -Labels $labels -GitHubPath $gh -Repositories $repositories `
    -Apply:$Apply -WhatIf:$WhatIfPreference -Confirm:$false
