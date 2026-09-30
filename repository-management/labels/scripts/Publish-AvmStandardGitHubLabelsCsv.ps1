#Requires -Version 7.4

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param([switch] $Publish)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'LabelCatalog.ps1')
. (Join-Path $PSScriptRoot 'LabelPublication.ps1')

$toolsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..'))
$labels = @(Read-AvmStandardGitHubLabels -Path (Join-Path $PSScriptRoot '..' 'avm-standard-github-labels.json'))
$csv = ConvertTo-AvmStandardGitHubLabelsCsv -Labels $labels

if ($Publish -and -not $WhatIfPreference -and
    ($env:GITHUB_ACTIONS -cne 'true' -or $env:GITHUB_REPOSITORY -cne 'Azure/azure-verified-modules-tools' -or
        $env:GITHUB_REF -cne 'refs/heads/main' -or $env:AVM_APP_SLUG -cne 'azure-verified-modules' -or
        $env:GITHUB_RUN_ID -cnotmatch '^[0-9]+$' -or $env:GITHUB_RUN_ATTEMPT -cnotmatch '^[0-9]+$' -or
        $env:GITHUB_SHA -cnotmatch '^[0-9a-f]{40}$' -or -not $env:GH_TOKEN)) {
    throw [System.InvalidOperationException]::new('Publishing labels requires the trusted tools main-branch workflow and its scoped GitHub App token.')
}

$null = Import-Module -Name (Join-Path $toolsRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -PassThru -ErrorAction Stop
$gh = (Get-Command -Name gh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
Invoke-AvmStandardGitHubLabelsPublication -GitHubPath $gh -Csv $csv -Publish:$Publish `
    -BotLogin "$($env:AVM_APP_SLUG)[bot]" -RunId $env:GITHUB_RUN_ID -RunAttempt $env:GITHUB_RUN_ATTEMPT `
    -SourceSha $env:GITHUB_SHA -WhatIf:$WhatIfPreference -Confirm:$false
