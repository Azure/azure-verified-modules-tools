#Requires -Version 7.4

# Ports Set-AvmGitHubIssueOwnerConfig from the retired bicep-registry-modules
# platform tooling (git history commit 2eb210dbb), adapted to run cross-repo
# with index-first/metadata.json-fallback owner resolution (see
# lib/ModuleOwners.ps1).
#
# Scope changes from the original:
#  - Adding the issue to the "AVM - Module Issues" GitHub Project is not done
#    here; it is handled by the existing generic
#    repository-management/repository-sync/scripts/Add-RepositoryItemsToProject.ps1
#    (already used for the Terraform module repositories), wired into the
#    workflow as its own step against bicep-registry-modules / project 566.
#  - The original's assignee-distribution / module-distribution console
#    report is dropped; it was informational only and not part of routing.
#
# Design invariants carried over from PrReviewerRouting.ps1 (see that file for
# the reasoning): scheduled only, conditional writes only, idempotent, one
# failing issue must not abort the sweep.

$script:AvmIssueOwnerRoutingModuleIssueTitlePrefix = '[AVM Module Issue]'
# Assignments made by these identities are treated as automated rather than manual, so a
# routing run is still allowed to remove/replace them. Includes the retired team linter app
# so that assignments made before the move to the AVM app still resolve correctly.
$script:AvmIssueOwnerRoutingAutomationBotLogins = @('azure-verified-modules[bot]', 'avm-team-linter[bot]')
$script:AvmIssueOwnerRoutingClassLabels = @{
    res = 'Class: Resource Module :package:'
    ptn = 'Class: Pattern Module :package:'
    utl = 'Class: Utility Module :package:'
}
$script:AvmIssueOwnerRoutingFields = 'number,title,body,url,createdAt,updatedAt,author,assignees,labels,comments'

function Get-AvmIssueOwnerRoutingCandidates {
    <#
    .SYNOPSIS
    Retrieves the issue(s) a routing run should evaluate: either one issue by
    URL, or every open '[AVM Module Issue]' updated within the lookback
    window (0 = every open issue, used by the daily full-sweep backstop).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [string] $IssueUrl,
        [int] $UpdatedWithinMinutes = 0
    )

    if (-not [string]::IsNullOrWhiteSpace($IssueUrl)) {
        $sanitized = $IssueUrl.Replace('api.', '').Replace('repos/', '').Replace('issues/', 'issue/')
        $issue = Invoke-RepositoryGitHub -AsJson -Arguments @(
            'issue', 'view', $sanitized, '--repo', $Repository, '--json', $script:AvmIssueOwnerRoutingFields
        )
        if ($null -eq $issue -or $null -eq $issue.number) {
            throw [System.InvalidOperationException]::new("Unable to retrieve issue '$IssueUrl'.")
        }
        return @($issue)
    }

    $issues = @(Invoke-RepositoryGitHub -AsJson -Arguments @(
        'issue', 'list', '--repo', $Repository, '--state', 'open', '--limit', '500',
        '--json', $script:AvmIssueOwnerRoutingFields
    ))
    if ($UpdatedWithinMinutes -gt 0) {
        $cutoff = (Get-Date).ToUniversalTime().AddMinutes(-$UpdatedWithinMinutes)
        $issues = @($issues | Where-Object { $_.updatedAt -and ([datetime]$_.updatedAt).ToUniversalTime() -ge $cutoff })
    }
    return @($issues | Where-Object { $_.title -and $_.title.StartsWith($script:AvmIssueOwnerRoutingModuleIssueTitlePrefix) })
}

function Get-AvmIssueOwnerRoutingTimeline {
    <#
    .SYNOPSIS
    Fetches an issue's assignment history, used to distinguish a human's
    manual assign/unassign decision from a prior automated routing write.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [int] $Number
    )

    return @(Invoke-RepositoryGitHub -AsJson -Arguments @(
        'api', '--paginate', "repos/$Repository/issues/$Number/timeline?per_page=100", '--hostname', 'github.com'
    ))
}

function Get-AvmIssueOwnerRoutingModuleReference {
    <#
    .SYNOPSIS
    Extracts the module path/type the issue template's module dropdown wrote
    into the issue body, e.g. a line reading 'avm/res/storage/storage-account'.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()] [string] $Body)

    if ([string]::IsNullOrWhiteSpace($Body)) {
        return $null
    }
    $match = [regex]::Match($Body, '(?:\r?\n)(avm/(res|ptn|utl)/\S+)')
    if (-not $match.Success) {
        return $null
    }
    return @{ ModuleName = $match.Groups[1].Value.Trim(); ModuleType = $match.Groups[2].Value }
}

function Resolve-AvmIssueOwnerRouting {
    <#
    .SYNOPSIS
    Computes the desired label/comment/assignees for one module issue,
    without applying them. Kept side-effect free so it can be unit tested
    without mocking `gh issue edit`.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [object] $Issue,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [hashtable] $CatalogIndex,
        [Parameter(Mandatory)] [string] $DefaultRef,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $TimelineEvents
    )

    if (-not ($Issue.title -and $Issue.title.StartsWith($script:AvmIssueOwnerRoutingModuleIssueTitlePrefix))) {
        return @{ Skip = $true }
    }

    $reference = Get-AvmIssueOwnerRoutingModuleReference -Body $Issue.body
    if ($null -eq $reference) {
        return @{ Skip = $true }
    }

    $topLevelModulePath = Get-AvmBicepTopLevelModulePath -Path $reference.ModuleName
    if ($null -eq $topLevelModulePath) {
        return @{ Skip = $true }
    }

    $authorLogin = if ($Issue.PSObject.Properties['author'] -and $Issue.author -and $Issue.author.PSObject.Properties['login']) { $Issue.author.login } else { $null }
    $moduleExists = Test-AvmBicepModuleExists -TopLevelModulePath $topLevelModulePath -CatalogIndex $CatalogIndex -Repository $Repository -Ref $DefaultRef
    $owners = @()
    if ($moduleExists) {
        $owners = @(Get-AvmModuleOwners -TopLevelModulePath $topLevelModulePath -CatalogIndex $CatalogIndex -Repository $Repository -Ref $DefaultRef)
    }
    $isOrphaned = $moduleExists -and $owners.Count -eq 0
    $ownerLogins = @($owners | Where-Object { $_.Type -ceq 'user' } | ForEach-Object { $_.Handle })
    $ownerMentions = @($owners | ForEach-Object { $_.Handle })

    if (-not $moduleExists) {
        $comment = "**@$authorLogin, thanks for submitting this issue for the ``$($reference.ModuleName)`` module!**`n`n> [!IMPORTANT]`n> The module does not exist yet, we look into it. Please file a new module proposal under [AVM Module proposal](https://aka.ms/avm/moduleproposal)."
    }
    elseif ($isOrphaned) {
        $comment = "**@$authorLogin, thanks for submitting this issue for the ``$($reference.ModuleName)`` module!**`n`n> [!IMPORTANT]`n> Please note, that this module is currently orphaned. The @Azure/azure-verified-modules-tooling-contributors team will attempt to find an owner for it. In the meantime, the core team may assist with this issue. Thank you for your patience!"
    }
    else {
        $mentions = ($ownerMentions | ForEach-Object { "@$_" }) -join ', '
        $comment = "**@$authorLogin, thanks for submitting this issue for the ``$($reference.ModuleName)`` module!**`n`n> [!IMPORTANT]`n> The module owners $mentions will review it soon!"
    }

    $existingComments = @($Issue.comments | Where-Object { $_.PSObject.Properties['body'] } | ForEach-Object { $_.body })
    $issueAgeDays = if ($Issue.PSObject.Properties['createdAt'] -and $Issue.createdAt) { ((Get-Date).ToUniversalTime() - ([datetime]$Issue.createdAt).ToUniversalTime()).TotalDays } else { 0 }
    $newComment = if ($existingComments -notcontains $comment -and ($issueAgeDays -le 7 -or $isOrphaned)) { $comment } else { $null }

    $existingLabels = @($Issue.labels | Where-Object { $_.PSObject.Properties['name'] -and $_.name } | ForEach-Object { $_.name })
    $classLabel = if ($moduleExists) { $script:AvmIssueOwnerRoutingClassLabels[$reference.ModuleType] } else { $null }
    $newLabels = @(if ($classLabel -and $existingLabels -notcontains $classLabel) { $classLabel })

    $existingAssignees = @($Issue.assignees | Where-Object { $_.PSObject.Properties['login'] -and $_.login } | ForEach-Object { $_.login })
    $manuallyUnassigned = @($TimelineEvents | Where-Object { $_.event -ceq 'unassigned' -and $_.PSObject.Properties['assignee'] -and $_.assignee -and $_.assignee.PSObject.Properties['login'] } | ForEach-Object { $_.assignee.login })
    $manuallyAssignedByHuman = @($TimelineEvents | Where-Object {
            $_.event -ceq 'assigned' -and $_.PSObject.Properties['actor'] -and $_.actor -and $_.actor.PSObject.Properties['login'] -and
            $script:AvmIssueOwnerRoutingAutomationBotLogins -notcontains $_.actor.login -and $_.PSObject.Properties['assignee'] -and $_.assignee -and $_.assignee.PSObject.Properties['login']
        } | ForEach-Object { $_.assignee.login })

    $assigneesToAdd = @($ownerLogins | Where-Object { $existingAssignees -notcontains $_ -and $manuallyUnassigned -notcontains $_ })
    $assigneesToRemove = @($existingAssignees | Where-Object {
            $moduleExists -and $manuallyAssignedByHuman -notcontains $_ -and ($isOrphaned -or $ownerLogins -notcontains $_)
        })
    $manuallyUnassignedOwners = @($ownerLogins | Where-Object { $existingAssignees -notcontains $_ -and $manuallyUnassigned -contains $_ })

    return @{
        Skip                     = $false
        ModuleName               = $reference.ModuleName
        ModuleExists             = $moduleExists
        IsOrphaned               = $isOrphaned
        Owners                   = $ownerMentions
        NewLabels                = $newLabels
        NewComment               = $newComment
        AssigneesToAdd           = $assigneesToAdd
        AssigneesToRemove        = $assigneesToRemove
        ManuallyUnassignedOwners = $manuallyUnassignedOwners
    }
}

function Write-AvmIssueOwnerRoutingPlan {
    <#
    .SYNOPSIS
    Logs the module an issue is about, its owners, and the assignee, label
    and comment changes about to be made.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Issue,
        [Parameter(Mandatory)] [hashtable] $Routing
    )

    $ownership = if (-not $Routing.ModuleExists) {
        'which does not exist yet'
    }
    elseif ($Routing.IsOrphaned) {
        'which declares no owners (orphaned)'
    }
    else {
        "owned by $(Format-AvmRunSummaryList -Values $Routing.Owners)"
    }
    Write-Host "Issue [$($Issue.url)] is about module [$($Routing.ModuleName)], $ownership."
    if ($Routing.AssigneesToAdd.Count -gt 0) {
        Write-Host "Assigning: $($Routing.AssigneesToAdd -join ', ')"
    }
    if ($Routing.ManuallyUnassignedOwners.Count -gt 0) {
        Write-Host "Not assigning, because they were removed from this issue earlier: $($Routing.ManuallyUnassignedOwners -join ', ')"
    }
    if ($Routing.AssigneesToRemove.Count -gt 0) {
        Write-Host "Unassigning, because they are not module owners: $($Routing.AssigneesToRemove -join ', ')"
    }
    if ($Routing.NewLabels.Count -gt 0) {
        Write-Host "Adding labels: $($Routing.NewLabels -join ', ')"
    }
    if ($Routing.NewComment) {
        Write-Host 'Posting the owner notification comment.'
    }
}

function Set-AvmIssueOwnerRoutingForIssue {
    <#
    .SYNOPSIS
    Routes one module issue and returns its outcome for the run summary.

    .OUTPUTS
    An ordered dictionary with Url, Number, Status (Skipped, AlreadyRouted,
    Updated or WouldUpdate), ModuleName, AssigneesAdded, AssigneesRemoved,
    LabelsAdded and Commented.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)] [object] $Issue,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [hashtable] $CatalogIndex,
        [Parameter(Mandatory)] [string] $DefaultRef
    )

    $outcome = [ordered]@{
        Url              = [string]$Issue.url
        Number           = $Issue.number
        Status           = $null
        ModuleName       = $null
        AssigneesAdded   = @()
        AssigneesRemoved = @()
        LabelsAdded      = @()
        Commented        = $false
    }

    $timelineEvents = @(Get-AvmIssueOwnerRoutingTimeline -Repository $Repository -Number $Issue.number)
    $routing = Resolve-AvmIssueOwnerRouting -Issue $Issue -Repository $Repository -CatalogIndex $CatalogIndex `
        -DefaultRef $DefaultRef -TimelineEvents $timelineEvents

    if ($routing.Skip) {
        Write-Host "Issue [$($Issue.url)] is not a module issue with a recognized module reference. Skipping."
        $outcome.Status = 'Skipped'
        return $outcome
    }
    $outcome.ModuleName = $routing.ModuleName

    # As with PR routing, only write when something actually changes so a reprocessed issue
    # is not touched again and does not keep re-entering the scheduled lookback window.
    if ($routing.NewLabels.Count -eq 0 -and $null -eq $routing.NewComment -and
        $routing.AssigneesToAdd.Count -eq 0 -and $routing.AssigneesToRemove.Count -eq 0) {
        Write-Host "Issue [$($Issue.url)] is already routed. Nothing to change."
        $outcome.Status = 'AlreadyRouted'
        return $outcome
    }

    Write-AvmIssueOwnerRoutingPlan -Issue $Issue -Routing $routing
    $applied = $false

    if ($routing.NewLabels.Count -gt 0 -and $PSCmdlet.ShouldProcess("Labels [$($routing.NewLabels -join ', ')] on issue [$($Issue.url)]", 'Add')) {
        $editArguments = @('issue', 'edit', $Issue.url, '--repo', $Repository)
        foreach ($label in $routing.NewLabels) { $editArguments += @('--add-label', $label) }
        $null = Invoke-RepositoryGitHub -Arguments $editArguments
        $applied = $true
    }
    if ($routing.NewComment -and $PSCmdlet.ShouldProcess("Comment on issue [$($Issue.url)]", 'Add')) {
        $null = Invoke-RepositoryGitHub -Arguments @('issue', 'comment', $Issue.url, '--repo', $Repository, '--body', $routing.NewComment)
        $applied = $true
    }
    foreach ($assignee in $routing.AssigneesToAdd) {
        if ($PSCmdlet.ShouldProcess("Module owner [$assignee] to issue [$($Issue.url)]", 'Assign')) {
            $null = Invoke-RepositoryGitHub -Arguments @('issue', 'edit', $Issue.url, '--repo', $Repository, '--add-assignee', $assignee)
            $applied = $true
        }
    }
    foreach ($assignee in $routing.AssigneesToRemove) {
        if ($PSCmdlet.ShouldProcess("Excess assignee [$assignee] from issue [$($Issue.url)]", 'Remove')) {
            $null = Invoke-RepositoryGitHub -Arguments @('issue', 'edit', $Issue.url, '--repo', $Repository, '--remove-assignee', $assignee)
            $applied = $true
        }
    }

    $outcome.Status = if ($applied) { 'Updated' } else { 'WouldUpdate' }
    $outcome.AssigneesAdded = $routing.AssigneesToAdd
    $outcome.AssigneesRemoved = $routing.AssigneesToRemove
    $outcome.LabelsAdded = $routing.NewLabels
    $outcome.Commented = [bool]$routing.NewComment
    return $outcome
}

function Write-AvmIssueOwnerRoutingSummary {
    <#
    .SYNOPSIS
    Summarizes an issue routing sweep: totals, and the owners assigned to
    each updated issue.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Outcomes,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Failures,
        [switch] $DryRun
    )

    $changed = @($Outcomes | Where-Object { $_.Status -in @('Updated', 'WouldUpdate') })
    $changedLabel = if ($DryRun) { 'would be updated' } else { 'updated' }
    $overview = "$($Outcomes.Count + $Failures.Count) module issue(s) checked in [$Repository]: " +
        "$($changed.Count) $changedLabel, " +
        "$(@($Outcomes | Where-Object { $_.Status -ceq 'AlreadyRouted' }).Count) already routed, " +
        "$(@($Outcomes | Where-Object { $_.Status -ceq 'Skipped' }).Count) without a module reference, " +
        "$($Failures.Count) failed."

    $logLines = [System.Collections.Generic.List[string]]::new()
    $rows = [System.Collections.Generic.List[object]]::new()
    $verb = if ($DryRun) {
        @{ Assign = 'would assign'; Unassign = 'would unassign'; Label = 'would add labels'; Comment = 'would post the owner notification comment' }
    }
    else {
        @{ Assign = 'assigned'; Unassign = 'unassigned'; Label = 'added labels'; Comment = 'posted the owner notification comment' }
    }
    foreach ($outcome in $changed) {
        $changes = [System.Collections.Generic.List[string]]::new()
        $markdownChanges = [System.Collections.Generic.List[string]]::new()
        if ($outcome.AssigneesAdded.Count -gt 0) {
            $changes.Add("$($verb.Assign) $(Format-AvmRunSummaryList -Values $outcome.AssigneesAdded)")
            $markdownChanges.Add("$($verb.Assign) $(Format-AvmRunSummaryList -Values $outcome.AssigneesAdded -AsCode)")
        }
        if ($outcome.AssigneesRemoved.Count -gt 0) {
            $changes.Add("$($verb.Unassign) $(Format-AvmRunSummaryList -Values $outcome.AssigneesRemoved)")
            $markdownChanges.Add("$($verb.Unassign) $(Format-AvmRunSummaryList -Values $outcome.AssigneesRemoved -AsCode)")
        }
        if ($outcome.LabelsAdded.Count -gt 0) {
            $changes.Add("$($verb.Label) $(Format-AvmRunSummaryList -Values $outcome.LabelsAdded)")
            $markdownChanges.Add("$($verb.Label) $(Format-AvmRunSummaryList -Values $outcome.LabelsAdded -AsCode)")
        }
        if ($outcome.Commented) {
            $changes.Add($verb.Comment)
            $markdownChanges.Add($verb.Comment)
        }
        $logLines.Add("$($outcome.Url) ($($outcome.ModuleName)): $($changes -join '; ')")
        $rows.Add([string[]]@(
                "[#$($outcome.Number)]($($outcome.Url))",
                (Format-AvmRunSummaryList -Values @($outcome.ModuleName) -AsCode),
                ($markdownChanges -join '<br>')
            ))
    }

    Write-AvmRunSummary -Title 'Issue owner routing' -Overview $overview -LogLines $logLines `
        -TableHeaders @('Issue', 'Module', 'Changes') -TableRows $rows.ToArray() -Failures $Failures -DryRun:$DryRun
}

function Invoke-AvmIssueOwnerRouting {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [string] $IssueUrl,
        [int] $UpdatedWithinMinutes = 0,
        [string] $DefaultRef = 'main'
    )

    try {
        $issues = @(Get-AvmIssueOwnerRoutingCandidates -Repository $Repository -IssueUrl $IssueUrl -UpdatedWithinMinutes $UpdatedWithinMinutes)
        Write-Verbose "Processing [$($issues.Count)] module issue(s) in [$Repository]." -Verbose
        $catalogIndex = Get-AvmReviewerRoutingCatalogIndex -Repository $Repository
    }
    catch {
        # A pre-loop setup failure is fatal (there is nothing left to sweep), but a bare
        # rethrow can be rendered without detail by the host. Guarantee the full exception
        # always reaches the log before propagating it unchanged.
        Write-Host "FATAL: Failed to prepare the issue owner routing sweep for [$Repository]."
        Write-Host "FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
        Write-Host $_.ScriptStackTrace
        throw
    }

    $outcomes = [System.Collections.Generic.List[object]]::new()
    $failures = [System.Collections.Generic.List[string]]::new()
    $total = $issues.Count
    $index = 0
    foreach ($issue in $issues) {
        $index++
        # Printed unconditionally, before any network call for this issue, so a run that dies
        # without an exception (e.g. a process kill) still leaves an unambiguous last-seen
        # item in the log, independent of gh's own argument echo.
        Write-Verbose "[$index/$total] Routing issue [$($issue.url)]." -Verbose
        try {
            $outcome = Set-AvmIssueOwnerRoutingForIssue -Issue $issue -Repository $Repository -CatalogIndex $catalogIndex -DefaultRef $DefaultRef -WhatIf:$WhatIfPreference
            $outcomes.Add($outcome)
        }
        catch {
            # A single unroutable issue must not stop the remaining ones on a scheduled run.
            $failures.Add("[$($issue.url)]: $($_.Exception.Message)")
            Write-Warning "Failed to route issue [$($issue.url)]. $($_.Exception.Message)"
        }
    }

    Write-AvmIssueOwnerRoutingSummary -Repository $Repository -Outcomes $outcomes.ToArray() -Failures $failures.ToArray() -DryRun:$WhatIfPreference

    if ($failures.Count -gt 0) {
        throw [System.AggregateException]::new(($failures -join [System.Environment]::NewLine))
    }
}
