#Requires -Version 7.4
# Requires Environment Variables for GitHub Actions
# GH_TOKEN
# Import Avm.Authoring and supply GH_TOKEN or an existing gh login.

[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]] $Repository = @('Azure/bicep-registry-modules'),
    [string] $PullRequestUrl = '',
    [ValidateRange(0, [int]::MaxValue)] [int] $UpdatedWithinMinutes = 0
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..'))
$sharedLibDir = Join-Path $repositoryRoot 'repository-management' 'repository-sync' 'scripts' 'lib'
. (Join-Path $sharedLibDir 'RetryHelpers.ps1')
. (Join-Path $sharedLibDir 'RepoTree.ps1')
. (Join-Path $sharedLibDir 'RepositoryDiscovery.ps1')

$libDir = Join-Path $PSScriptRoot 'lib'
. (Join-Path $libDir 'RepositoryFileAccess.ps1')
. (Join-Path $libDir 'ModuleOwners.ps1')
. (Join-Path $libDir 'RunSummary.ps1')
. (Join-Path $libDir 'PrReviewerRouting.ps1')
. (Join-Path $libDir 'PrReviewerRoutingDiscovery.ps1')

try {
    Invoke-AvmPrReviewerRoutingSweep -Repository $Repository -PullRequestUrl $PullRequestUrl `
        -UpdatedWithinMinutes $UpdatedWithinMinutes -WhatIf:$WhatIfPreference
}
catch {
    # Defense-in-depth: guarantee full exception detail always reaches the workflow log,
    # then rethrow so the step still fails with a non-zero exit code exactly as today.
    Write-Host "FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    throw
}
