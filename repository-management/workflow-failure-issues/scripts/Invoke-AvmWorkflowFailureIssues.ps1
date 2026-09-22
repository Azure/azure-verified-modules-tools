#Requires -Version 7.4
# Requires Environment Variables for GitHub Actions
# GH_TOKEN
# Must run gh auth login -h "GitHub.com" and Import-Module Avm.Authoring before running this script

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Repository = 'Azure/bicep-registry-modules',
    [string] $Branch = 'main',
    [string] $DefaultRef = 'main'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..'))
$sharedLibDir = Join-Path $repositoryRoot 'repository-management' 'repository-sync' 'scripts' 'lib'
. (Join-Path $sharedLibDir 'RetryHelpers.ps1')
. (Join-Path $sharedLibDir 'RepoTree.ps1')

$reviewerRoutingLibDir = Join-Path $repositoryRoot 'repository-management' 'reviewer-routing' 'scripts' 'lib'
. (Join-Path $reviewerRoutingLibDir 'RepositoryFileAccess.ps1')
. (Join-Path $reviewerRoutingLibDir 'ModuleOwners.ps1')

$libDir = Join-Path $PSScriptRoot 'lib'
. (Join-Path $libDir 'WorkflowFailureIssues.ps1')

try {
    Invoke-AvmWorkflowFailureIssues -Repository $Repository -Branch $Branch -DefaultRef $DefaultRef -WhatIf:$WhatIfPreference
}
catch {
    # Defense-in-depth: guarantee full exception detail always reaches the workflow log,
    # then rethrow so the step still fails with a non-zero exit code exactly as today.
    Write-Host "FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    throw
}
