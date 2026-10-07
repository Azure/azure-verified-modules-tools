#Requires -Version 7.4
<#
.SYNOPSIS
Audit AVM root module owners to confirm they are still active Microsoft FTEs, and optionally remediate.

.DESCRIPTION
Reads the published AVM module catalog (Azure/Azure-Verified-Modules v1/modules.json on main) and checks every
owner of every root module (Bicep and Terraform; child modules inherit ownership and are never checked or edited).

An owner is an active Microsoft FTE when their GitHub account is a member of the 'Azure' GitHub organization,
which requires a linked Microsoft identity. Owners outside the org, or whose GitHub account no longer exists, are
inactive. Active owners outside the 'azure-verified-modules-module-contributors' team are flagged so they can be
asked to join the access package; they are never removed.

Verdicts per root module, highest priority first: WouldOrphan, OrphanMissingIssue, OwnerReduction,
OrphanIssueCanClose, OrphanIssueNeedsReview, NeedsTeamJoin, IssueHygiene, OK. Proposed modules are reported in
their own section and never changed. See README.md in this folder for details.

Dry run (report + CSVs) by default. With -Apply the script removes inactive owners from root metadata.json
(validated with Avm.Authoring) through pull requests pushed directly to each repository (one batch PR for
Azure/bicep-registry-modules, one PR per Terraform repository), raises or reuses "Orphaned Module" issues and adds
them to projects 529 (Orphaned) and 1011 (Needs: Triage). With -CloseResolvedIssues it also closes orphan issues
for modules that are owned again.

Requires gh authenticated as an Azure org member with the repo, read:org and project scopes, and Avm.Authoring
imported (>= -MinimumAvmAuthoringVersion for -Apply, or this repository's src build).

.PARAMETER IndexPath
Optional local modules.json to use instead of the published catalog (testing).

.PARAMETER Organization
GitHub organization whose membership indicates an active Microsoft FTE.

.PARAMETER ContributorTeam
Slug of the AVM module contributors team in -Organization.

.PARAMETER IssueRepository
Repository that hosts the "Orphaned Module" issues.

.PARAMETER ExemptHandles
GitHub handles that are never treated as inactive (reported as 'Exempt').

.PARAMETER ExemptHandlesPath
Optional text file with one exempt GitHub handle per line ('#' comments allowed).

.PARAMETER ModuleFilter
Wildcard patterns matched against module names, paths and repositories (e.g. 'avm/res/network/*').

.PARAMETER Ecosystem
Languages to audit: bicep, terraform. Default: both.

.PARAMETER ModuleType
Module types to audit: resource, pattern, utility. Default: all.

.PARAMETER OutputPath
Folder for the CSV reports and run log.

.PARAMETER Apply
Make the changes. Each module change asks for confirmation unless -Force. Combine with -WhatIf to preview.

.PARAMETER CloseResolvedIssues
With -Apply, close open orphan issues classified as 'OrphanIssueCanClose'.

.PARAMETER Force
Skip the per-change confirmation prompts in -Apply mode.

.PARAMETER MaxChanges
Maximum number of module-level changes in -Apply mode.

.PARAMETER TargetRepoOverride
Testing only. Write metadata changes and pull requests to this repository instead of the module repositories.
Terraform files are written to 'terraform/<repo-name>/metadata.json'. Requires -IssueRepoOverride.

.PARAMETER IssueRepoOverride
Testing only. Create issues in this repository. Project updates and closing of real issues are skipped.

.PARAMETER MinimumAvmAuthoringVersion
Minimum Avm.Authoring version required for -Apply.

.PARAMETER PassThru
Return the audit result objects.

.EXAMPLE
./Invoke-AvmModuleOwnerAudit.ps1

Dry run. Prints the report and writes the CSV files.

.EXAMPLE
./Invoke-AvmModuleOwnerAudit.ps1 -Ecosystem terraform -ModuleType resource, utility

Reports only on Terraform resource and utility modules.

.EXAMPLE
./Invoke-AvmModuleOwnerAudit.ps1 -ModuleFilter 'avm/res/kusto/cluster' -Apply -WhatIf

Shows the changes that would be made for one module.

.EXAMPLE
./Invoke-AvmModuleOwnerAudit.ps1 -Apply -CloseResolvedIssues -MaxChanges 5

Applies up to 5 module changes, asking for confirmation for each one.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param (
    [string] $IndexPath,
    [string] $Organization = 'Azure',
    [string] $ContributorTeam = 'azure-verified-modules-module-contributors',
    [string] $IssueRepository = 'Azure/Azure-Verified-Modules',
    [string[]] $ExemptHandles = @(),
    [string] $ExemptHandlesPath,
    [string[]] $ModuleFilter,
    [ValidateSet('bicep', 'terraform')]
    [string[]] $Ecosystem = @('bicep', 'terraform'),
    [ValidateSet('resource', 'pattern', 'utility')]
    [string[]] $ModuleType = @('resource', 'pattern', 'utility'),
    [string] $OutputPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'avm-owner-audit'),
    [switch] $Apply,
    [switch] $CloseResolvedIssues,
    [switch] $Force,
    [ValidateRange(1, [int]::MaxValue)]
    [int] $MaxChanges = [int]::MaxValue,
    [string] $TargetRepoOverride,
    [string] $IssueRepoOverride,
    [version] $MinimumAvmAuthoringVersion = '0.20.0',
    [switch] $PassThru
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

. (Join-Path $PSScriptRoot 'lib' 'ModuleOwnerAudit.ps1')

$previousOutputEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
try {
    Invoke-AvmModuleOwnerAudit @PSBoundParameters
}
finally {
    [Console]::OutputEncoding = $previousOutputEncoding
}
