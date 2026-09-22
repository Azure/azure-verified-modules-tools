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

    return @{
        Skip              = $false
        ModuleName        = $reference.ModuleName
        ModuleExists      = $moduleExists
        IsOrphaned        = $isOrphaned
        NewLabels         = $newLabels
        NewComment        = $newComment
        AssigneesToAdd    = $assigneesToAdd
        AssigneesToRemove = $assigneesToRemove
    }
}

function Set-AvmIssueOwnerRoutingForIssue {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object] $Issue,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [hashtable] $CatalogIndex,
        [Parameter(Mandatory)] [string] $DefaultRef
    )

    $timelineEvents = @(Get-AvmIssueOwnerRoutingTimeline -Repository $Repository -Number $Issue.number)
    $routing = Resolve-AvmIssueOwnerRouting -Issue $Issue -Repository $Repository -CatalogIndex $CatalogIndex `
        -DefaultRef $DefaultRef -TimelineEvents $timelineEvents

    if ($routing.Skip) {
        Write-Verbose "Skipping issue [$($Issue.url)]: not a module issue with a recognized module reference."
        return
    }

    # As with PR routing, only write when something actually changes so a reprocessed issue
    # is not touched again and does not keep re-entering the scheduled lookback window.
    if ($routing.NewLabels.Count -eq 0 -and $null -eq $routing.NewComment -and
        $routing.AssigneesToAdd.Count -eq 0 -and $routing.AssigneesToRemove.Count -eq 0) {
        Write-Verbose "Issue [$($Issue.url)] is already routed. Skipping."
        return
    }

    if ($routing.NewLabels.Count -gt 0 -and $PSCmdlet.ShouldProcess("Labels [$($routing.NewLabels -join ', ')] on issue [$($Issue.url)]", 'Add')) {
        $editArguments = @('issue', 'edit', $Issue.url, '--repo', $Repository)
        foreach ($label in $routing.NewLabels) { $editArguments += @('--add-label', $label) }
        $null = Invoke-RepositoryGitHub -Arguments $editArguments
    }
    if ($routing.NewComment -and $PSCmdlet.ShouldProcess("Comment on issue [$($Issue.url)]", 'Add')) {
        $null = Invoke-RepositoryGitHub -Arguments @('issue', 'comment', $Issue.url, '--repo', $Repository, '--body', $routing.NewComment)
    }
    foreach ($assignee in $routing.AssigneesToAdd) {
        if ($PSCmdlet.ShouldProcess("Module owner [$assignee] to issue [$($Issue.url)]", 'Assign')) {
            $null = Invoke-RepositoryGitHub -Arguments @('issue', 'edit', $Issue.url, '--repo', $Repository, '--add-assignee', $assignee)
        }
    }
    foreach ($assignee in $routing.AssigneesToRemove) {
        if ($PSCmdlet.ShouldProcess("Excess assignee [$assignee] from issue [$($Issue.url)]", 'Remove')) {
            $null = Invoke-RepositoryGitHub -Arguments @('issue', 'edit', $Issue.url, '--repo', $Repository, '--remove-assignee', $assignee)
        }
    }
}

function Invoke-AvmIssueOwnerRouting {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [string] $IssueUrl,
        [int] $UpdatedWithinMinutes = 0,
        [string] $DefaultRef = 'main'
    )

    $issues = @(Get-AvmIssueOwnerRoutingCandidates -Repository $Repository -IssueUrl $IssueUrl -UpdatedWithinMinutes $UpdatedWithinMinutes)
    Write-Verbose "Processing [$($issues.Count)] module issue(s) in [$Repository]." -Verbose

    $catalogIndex = Get-AvmReviewerRoutingCatalogIndex -Repository $Repository
    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($issue in $issues) {
        try {
            Set-AvmIssueOwnerRoutingForIssue -Issue $issue -Repository $Repository -CatalogIndex $catalogIndex -DefaultRef $DefaultRef -WhatIf:$WhatIfPreference
        }
        catch {
            # A single unroutable issue must not stop the remaining ones on a scheduled run.
            $failures.Add("[$($issue.url)]: $($_.Exception.Message)")
            Write-Warning "Failed to route issue [$($issue.url)]. $($_.Exception.Message)"
        }
    }

    if ($failures.Count -gt 0) {
        throw [System.AggregateException]::new(($failures -join [System.Environment]::NewLine))
    }
}
