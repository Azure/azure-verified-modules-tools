#Requires -Version 7.4

[CmdletBinding(SupportsShouldProcess)]
param([switch] $PlanOnly, [switch] $UpdateSource)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
Import-Module (Join-Path $repositoryRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force -ErrorAction Stop
. (Join-Path $repositoryRoot 'repository-management' 'repository-sync' 'scripts' 'lib' 'RepositoryFileSync.ps1')
. (Join-Path $PSScriptRoot 'MetadataBackfillSync.ps1')

if ($PSCmdlet.ShouldProcess('Azure/bicep-registry-modules', 'Run reviewed Bicep metadata backfill synchronization')) {
    $result = Invoke-AvmBicepMetadataBackfillSync -PlanOnly:$PlanOnly -UpdateSource:$UpdateSource
    $result | ConvertTo-Json -Depth 5
    if ($env:GITHUB_STEP_SUMMARY) {
        $summary = @("Bicep metadata backfill: **$($result.Status)**")
        if ($result.PullRequestUrl) {
            $summary += "Review: $($result.PullRequestUrl)"
        }
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ($summary -join "`n") -Encoding utf8NoBOM
    }
}
