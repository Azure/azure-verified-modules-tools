#Requires -Version 7.4

# Keeps the "Module Name" dropdown in bicep-registry-modules'
# avm_module_issue.yml in sync with the published module catalog, opening
# and auto-merging a pull request through the shared RepositoryFileSync
# engine instead of the original's drift-report issue.

$script:AvmModuleListSyncCategoryOrder = @('ptn', 'res', 'utl')
$script:AvmModuleListSyncLineRegex = '^(?<indent>\s*)(?<comment>#\s*)?-\s+"(?<path>avm/(?:res|ptn|utl)/[^"]+)"\s*$'
$script:AvmModuleListSyncIncludedStatuses = @('Available', 'Orphaned')

function Get-AvmModuleListSyncCatalogModulePaths {
    <#
    .SYNOPSIS
    Returns the desired, sorted dropdown module paths per category (ptn/res/utl)
    for one repository, derived from the published module catalog.

    .DESCRIPTION
    Only top-level modules (an empty/absent `parentModule`) with a
    moduleStatus of Available or Orphaned are included; child modules and
    Proposed/Deprecated modules are excluded.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] [string] $Repository)

    $index = Get-AvmReviewerRoutingCatalogIndex -Repository $Repository
    $byCategory = @{}
    foreach ($category in $script:AvmModuleListSyncCategoryOrder) { $byCategory[$category] = [System.Collections.Generic.List[string]]::new() }
    foreach ($entry in $index.Values) {
        if ($entry.moduleStatus -cnotin $script:AvmModuleListSyncIncludedStatuses) { continue }
        if (-not [string]::IsNullOrWhiteSpace([string]$entry.parentModule)) { continue }
        $path = [string]$entry.modulePath
        if ($path -notmatch '^avm/(?<category>res|ptn|utl)/') { continue }
        $byCategory[$Matches['category']].Add($path)
    }

    $result = @{}
    foreach ($category in $script:AvmModuleListSyncCategoryOrder) {
        $result[$category] = @($byCategory[$category] | Sort-Object)
    }
    return $result
}

function Resolve-AvmModuleDropdownSync {
    <#
    .SYNOPSIS
    Side-effect-free comparison of the current avm_module_issue.yml content
    against the desired catalog module list.

    .DESCRIPTION
    Only the active (uncommented) dropdown lines are added, removed, or
    re-sorted; commented-out lines are preserved verbatim and left in place,
    matching the original script's behaviour of never touching them.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Content,
        [Parameter(Mandatory)] [hashtable] $DesiredModulePaths
    )

    $normalized = $Content.Replace("`r`n", "`n")
    $lines = @($normalized.Split("`n"))

    $startIndex = 0
    while ($startIndex -lt $lines.Length -and $lines[$startIndex] -notmatch $script:AvmModuleListSyncLineRegex) { $startIndex++ }
    if ($startIndex -ge $lines.Length) {
        throw [System.IO.InvalidDataException]::new('Could not find the module dropdown list in avm_module_issue.yml.')
    }
    $endIndex = $startIndex
    while ($endIndex -lt $lines.Length -and $lines[$endIndex] -match $script:AvmModuleListSyncLineRegex) { $endIndex++ }
    $endIndex--

    $indent = $Matches['indent']
    $byCategory = @{}
    foreach ($category in $script:AvmModuleListSyncCategoryOrder) {
        $byCategory[$category] = @{ Active = [System.Collections.Generic.List[string]]::new(); Comments = [System.Collections.Generic.List[string]]::new() }
    }
    for ($i = $startIndex; $i -le $endIndex; $i++) {
        if ($lines[$i] -notmatch $script:AvmModuleListSyncLineRegex) { continue }
        $category = ($Matches['path'] -split '/')[1]
        if ($Matches['comment']) {
            $byCategory[$category].Comments.Add($lines[$i])
        } else {
            $byCategory[$category].Active.Add($Matches['path'])
        }
    }

    $added = [System.Collections.Generic.List[string]]::new()
    $removed = [System.Collections.Generic.List[string]]::new()
    $newBlock = [System.Collections.Generic.List[string]]::new()
    foreach ($category in $script:AvmModuleListSyncCategoryOrder) {
        $existing = @($byCategory[$category].Active)
        $desired = @($DesiredModulePaths[$category])
        foreach ($path in $desired) { if ($existing -notcontains $path) { $added.Add($path) } }
        foreach ($path in $existing) { if ($desired -notcontains $path) { $removed.Add($path) } }
        foreach ($path in $desired) { $newBlock.Add("$indent- `"$path`"") }
        foreach ($comment in $byCategory[$category].Comments) { $newBlock.Add($comment) }
    }

    $newLines = [System.Collections.Generic.List[string]]::new()
    if ($startIndex -gt 0) { $newLines.AddRange([string[]]$lines[0..($startIndex - 1)]) }
    $newLines.AddRange([string[]]$newBlock)
    if ($endIndex -lt $lines.Length - 1) { $newLines.AddRange([string[]]$lines[($endIndex + 1)..($lines.Length - 1)]) }
    $newContent = [string]::Join("`n", $newLines)

    return @{
        Changed = $newContent -cne $normalized
        Content = $newContent
        Added   = @($added)
        Removed = @($removed)
    }
}

function New-AvmModuleListSyncPullRequestBody {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Added,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Removed
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Keeps the "Module Name" dropdown in `avm_module_issue.yml` in sync with the [published AVM module catalog](https://github.com/Azure/Azure-Verified-Modules/blob/main/docs/static/module-indexes/v1/modules.json).')
    $lines.Add('')
    if ($Added.Count -gt 0) {
        $lines.Add('**Added:**')
        foreach ($path in $Added) { $lines.Add("- ``$path``") }
        $lines.Add('')
    }
    if ($Removed.Count -gt 0) {
        $lines.Add('**Removed:**')
        foreach ($path in $Removed) { $lines.Add("- ``$path``") }
        $lines.Add('')
    }
    $lines.Add('This PR is opened and merged by the AVM bot from [azure-verified-modules-tools](https://github.com/Azure/azure-verified-modules-tools).')
    return [string]::Join("`n", $lines)
}

function Invoke-AvmModuleListSync {
    <#
    .SYNOPSIS
    Entry point: compares the published catalog against
    avm_module_issue.yml's module dropdown and opens or updates an
    auto-merged pull request when they have drifted.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [string] $DefaultBranch = 'main',
        [string] $IssueTemplatePath = '.github/ISSUE_TEMPLATE/avm_module_issue.yml'
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    # Printed unconditionally, before any network call, so a run that dies without an
    # exception (e.g. a process kill) still leaves an unambiguous last-seen item in the log.
    Write-Verbose "[1/1] Syncing module dropdown for [$Repository]." -Verbose

    try {
        $desired = Get-AvmModuleListSyncCatalogModulePaths -Repository $Repository
        $file = Get-AvmRepositoryFileAtRef -Repository $Repository -Path $IssueTemplatePath -Ref $DefaultBranch
        $plan = Resolve-AvmModuleDropdownSync -Content $file.Content -DesiredModulePaths $desired
    }
    catch {
        # A setup failure is fatal (there is nothing left to sync), but a bare rethrow can be
        # rendered without detail by the host. Guarantee the full exception always reaches the
        # log before propagating it unchanged.
        Write-Host "FATAL: Failed to prepare the module dropdown sync for [$Repository]."
        Write-Host "FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
        Write-Host $_.ScriptStackTrace
        throw
    }

    if (-not $plan.Changed) {
        Write-Host "$Repository module dropdown already matches the published catalog." -ForegroundColor DarkGray
        Write-AvmRunSummary -Title 'Module dropdown sync' -DryRun:$WhatIfPreference `
            -Overview "The [$Repository] module dropdown already matches the published catalog."
        return @{ HasChanges = $false; Status = 'NoChange'; PullRequestUrl = $null }
    }

    Write-Host "$Repository module dropdown is out of sync: $($plan.Added.Count) added, $($plan.Removed.Count) removed." -ForegroundColor Yellow
    if ($plan.Added.Count -eq 0 -and $plan.Removed.Count -eq 0) {
        Write-Host '  Only the order of the entries changes.'
    }
    else {
        Write-Host "  Added: $(Format-AvmRunSummaryList -Values $plan.Added)"
        Write-Host "  Removed: $(Format-AvmRunSummaryList -Values $plan.Removed)"
    }
    $expectedActor = Get-RepositorySyncConfiguredBotActor
    $result = Invoke-RepositoryFileSync -Repository $Repository -DefaultBranch $DefaultBranch `
        -VerifyCandidate -ExpectedActor $expectedActor -PlanHasChanges:$plan.Changed `
        -StableBranch 'avm-bot/sync-module-dropdown' `
        -AllowedPaths @($IssueTemplatePath) `
        -GeneratedFiles @{ $IssueTemplatePath = $plan.Content } `
        -Title 'chore(module-list): sync AVM module dropdown [skip ci]' `
        -Body (New-AvmModuleListSyncPullRequestBody -Added $plan.Added -Removed $plan.Removed) `
        -WhatIf:$WhatIfPreference

    if ($result.PullRequestUrl) {
        Write-Host "Module dropdown pull request [$($result.PullRequestUrl)] is $($result.Status)." -ForegroundColor Green
    }
    $pullRequest = if ($result.PullRequestUrl) { $result.PullRequestUrl } else { 'none' }
    Write-AvmRunSummary -Title 'Module dropdown sync' -DryRun:$WhatIfPreference `
        -Overview "The [$Repository] module dropdown is out of sync: $($plan.Added.Count) added, $($plan.Removed.Count) removed. Pull request: $pullRequest (status: $($result.Status))." `
        -TableHeaders @('Change', 'Modules') -TableRows @(
            [string[]]@('Added', (Format-AvmRunSummaryList -Values $plan.Added -AsCode)),
            [string[]]@('Removed', (Format-AvmRunSummaryList -Values $plan.Removed -AsCode))
        )
    return $result
}
