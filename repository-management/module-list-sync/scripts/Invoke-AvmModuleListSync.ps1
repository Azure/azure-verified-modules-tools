#Requires -Version 7.4
# Requires Environment Variables for GitHub Actions
# GH_TOKEN
# Must run gh auth login -h "GitHub.com" and Import-Module Avm.Authoring before running this script

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Repository = 'Azure/bicep-registry-modules',
    [string] $DefaultBranch = 'main'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..'))
$sharedLibDir = Join-Path $repositoryRoot 'repository-management' 'repository-sync' 'scripts' 'lib'
. (Join-Path $sharedLibDir 'RepositoryFileSync.ps1')

$reviewerRoutingLibDir = Join-Path $repositoryRoot 'repository-management' 'reviewer-routing' 'scripts' 'lib'
. (Join-Path $reviewerRoutingLibDir 'RepositoryFileAccess.ps1')
. (Join-Path $reviewerRoutingLibDir 'ModuleOwners.ps1')

$libDir = Join-Path $PSScriptRoot 'lib'
. (Join-Path $libDir 'ModuleListSync.ps1')

Invoke-AvmModuleListSync -Repository $Repository -DefaultBranch $DefaultBranch -WhatIf:$WhatIfPreference
