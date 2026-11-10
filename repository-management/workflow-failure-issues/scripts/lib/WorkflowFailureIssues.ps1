#Requires -Version 7.4

# Ports Set-AvmGitHubIssueForWorkflow from the retired bicep-registry-modules
# platform tooling (git history commit 2eb210dbb), adapted to run cross-repo
# and to resolve module owners via lib/ModuleOwners.ps1 (index-first,
# metadata.json fallback) instead of a local metadata.json read.
#
# Scope changes from the original:
#  - Adding the issue to a GitHub Project ("AVM - Issue Triage" /
#    "AVM - Module Issues") is not done here, for the same reason as
#    IssueOwnerRouting.ps1: the existing generic
#    repository-management/repository-sync/scripts/Add-RepositoryItemsToProject.ps1
#    already syncs project membership and will pick up newly created issues
#    on its own schedule.
#
# Design invariants carried over from the other routing libraries: one
# failing workflow/issue must not abort the sweep, and every write is
# conditional (an issue that is already up to date for this run is left
# untouched).

$script:AvmWorkflowFailureIssueTitlePrefix = '[Failed pipeline]'
$script:AvmWorkflowFailureWorkflowFilter = '(?:avm\.(?:res|ptn|utl)\.|^\.Module - Check and Publish(?: \[EXPERIMENTAL\])?$)'
$script:AvmWorkflowFailureIgnoredWorkflowNames = @(
    '.Platform - Check PSRule'
    '.Platform - Semantic PR Check'
    'Semantic PR Check'
)
$script:AvmWorkflowFailureAvmLabel = 'Type: AVM :a: :v: :m:'
$script:AvmWorkflowFailureBugLabel = 'Type: Bug :bug:'
$script:AvmWorkflowFailureDuplicateLabel = 'Type: Duplicate :palms_up_together:'
$script:AvmWorkflowFailurePlatformTaggingComment = @'
> [!IMPORTANT]
> This issue was created for a platform workflow. The maintainer team @Azure/azure-verified-modules-tooling-contributors should investigate and mitigate the reason.
'@

function Get-AvmWorkflowFailureWorkflows {
    <#
    .SYNOPSIS
    Lists the active workflows a failure sweep should evaluate: per-module CI
    workflows plus the shared cross-module check/publish pipeline, excluding
    workflows whose failures are expected/uninteresting noise.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [string[]] $WorkflowName = @()
    )

    # `repos/{repo}/actions/workflows` is an object endpoint (each page is
    # `{total_count, workflows: [...]}`), so `--paginate` alone concatenates
    # whole page objects back-to-back, which is not valid JSON as a whole.
    # `--slurp` wraps the pages into a JSON array of page-objects instead;
    # the `.workflows` projection then has to happen client-side because a
    # streaming `--jq` filter is also incompatible with the single-document
    # parse `-AsJson` performs.
    $pages = @(Invoke-RepositoryGitHub -AsJson -Arguments @(
        'api', '--paginate', '--slurp', "repos/$Repository/actions/workflows?per_page=100", '--hostname', 'github.com'
    ))
    $workflows = @($pages | ForEach-Object { $_.workflows } | Where-Object { $_.state -eq 'active' } | Select-Object id, name)
    if ($WorkflowName.Count -gt 0) {
        $selected = @($workflows | Where-Object { $_.name -cin $WorkflowName })
        $selectedNames = @($selected | ForEach-Object { $_.name })
        $missing = @($WorkflowName | Where-Object { $_ -cnotin $selectedNames })
        if ($missing.Count -gt 0) {
            throw [System.IO.InvalidDataException]::new("Monitored workflows are missing or inactive in ${Repository}: $($missing -join ', ')")
        }
        return $selected
    }
    return @($workflows | Where-Object {
            $_.name -match $script:AvmWorkflowFailureWorkflowFilter -and
            $script:AvmWorkflowFailureIgnoredWorkflowNames -notcontains $_.name
        })
}

function Get-AvmWorkflowFailureLatestRun {
    <#
    .SYNOPSIS
    Fetches a workflow's most recent completed run on the given branch, or
    $null when it has never completed a run yet.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string] $WorkflowId,
        [string] $Branch = 'main'
    )

    $runs = @(Invoke-RepositoryGitHub -AsJson -Arguments @(
        'api', "repos/$Repository/actions/workflows/$WorkflowId/runs?branch=$Branch&status=completed&per_page=1",
        '--hostname', 'github.com', '--jq', '.workflow_runs'
    ))
    if ($runs.Count -eq 0) {
        return $null
    }
    return $runs[0]
}

function Test-AvmWorkflowFailureConclusion {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $Conclusion)

    return $Conclusion -in @('failure', 'timed_out', 'startup_failure', 'action_required')
}

function Get-AvmWorkflowFailureRunHistory {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $WorkflowId,
        [string] $Branch = 'main',
        [ValidateRange(1, 100)][int] $Count = 3
    )

    $history = [System.Collections.Generic.List[object]]::new()
    for ($page = 1; ; $page++) {
        $runs = @(Invoke-RepositoryGitHub -AsJson -Arguments @(
                'api', "repos/$Repository/actions/workflows/$WorkflowId/runs?branch=$Branch&status=completed&per_page=100&page=$page",
                '--hostname', 'github.com', '--jq', '.workflow_runs'
            ))
        foreach ($run in $runs) {
            if ($run.event -in @('pull_request', 'pull_request_target')) { continue }
            if ($run.conclusion -ceq 'success' -or (Test-AvmWorkflowFailureConclusion -Conclusion $run.conclusion)) {
                $history.Add($run)
                if ($run.conclusion -ceq 'success' -or $history.Count -ge $Count) {
                    return $history.ToArray()
                }
            }
        }
        if ($runs.Count -lt 100) { return $history.ToArray() }
    }
}

function Get-AvmWorkflowFailureOpenIssues {
    <#
    .SYNOPSIS
    Fetches every open '[Failed pipeline] ...' issue in one call, so the
    sweep does not issue a `gh issue list` per workflow.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)] [string] $Repository)

    $issues = @(Invoke-RepositoryGitHub -AsJson -Arguments @(
        'api', '--paginate', "repos/$Repository/issues?state=open&per_page=100", '--hostname', 'github.com'
    ))
    return @($issues | Where-Object {
            $null -eq $_.PSObject.Properties['pull_request'] -and
            $_.title -and $_.title.StartsWith($script:AvmWorkflowFailureIssueTitlePrefix)
        } | Select-Object number, title, @{ Name = 'url'; Expression = { $_.html_url } },
            @{ Name = 'createdAt'; Expression = { $_.created_at } }, labels, body)
}

function Get-AvmWorkflowFailureIssueCommentsToday {
    <#
    .SYNOPSIS
    Fetches comment bodies from today (UTC), or all comments for incident-wide
    deduplication when All is set.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [int] $Number,
        [switch] $All
    )

    # This endpoint is a top-level array, so `--paginate` merges pages
    # correctly on its own. `--jq '.[].body'` is dropped because it emits
    # each comment's raw markdown body as a bare text stream (one value per
    # comment), which `-AsJson`'s single-document parse cannot read; the
    # `.body` projection is done client-side instead.
    $since = if ($All) { '' } else { '&since=' + (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddT00:00:00Z') }
    $comments = @(Invoke-RepositoryGitHub -AsJson -Arguments @(
        'api', '--paginate', "repos/$Repository/issues/$Number/comments?per_page=100$since",
        '--hostname', 'github.com'
    ))
    return @($comments | ForEach-Object { [string]$_.body })
}

function Get-AvmWorkflowFailureModuleReference {
    <#
    .SYNOPSIS
    Converts a module workflow's name (dot-separated, e.g. 'avm.res.storage.storage-account')
    into its top-level module path, or $null for a non-module (platform/shared) workflow.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $WorkflowName)

    if ($WorkflowName -notmatch '^avm\.(res|ptn|utl)\.') {
        return $null
    }
    return Get-AvmBicepTopLevelModulePath -Path ($WorkflowName -replace '\.', '/')
}

function Resolve-AvmWorkflowFailureRouting {
    <#
    .SYNOPSIS
    Computes the desired create/comment/close actions for one workflow's
    latest run, without applying them. Kept side-effect free so it can be
    unit tested without mocking `gh issue create/comment/edit/close`.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [object] $WorkflowRun,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $ExistingIssues,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Owners,
        [Parameter(Mandatory)] [bool] $IsModule,
        [AllowEmptyCollection()] [string[]] $ExistingCommentBodiesToday = @(),
        [string] $PlatformTeam,
        [bool] $FailureThresholdMet = $true
    )

    $issueTitle = "$script:AvmWorkflowFailureIssueTitlePrefix $($WorkflowRun.name)"
    $runUrl = [string]$WorkflowRun.html_url

    # Every branch below returns the same fully-keyed shape (defaulting unused keys to $null/@())
    # rather than only including the keys relevant to that branch. Set-AvmWorkflowFailureIssueForRun
    # runs under Set-StrictMode -Version 3, under which dot-notation access to an absent hashtable
    # key throws PropertyNotFoundException rather than returning $null.
    $result = @{
        IsFailure             = Test-AvmWorkflowFailureConclusion -Conclusion $WorkflowRun.conclusion
        BelowThreshold        = $false
        IssuesToClose         = @()
        CloseComment          = $null
        CreateIssueTitle      = $null
        CreateIssueBody       = $null
        CreateIssueLabels     = @()
        TaggingComment        = $null
        AssigneeToAdd         = $null
        NotifiedHandles       = @()
        DuplicateIssuesToClose = @()
        CommentIssueUrl       = $null
        CommentBody           = $null
    }

    if (-not $result.IsFailure) {
        # A successful run closes every open issue that was tracking this workflow's failures.
        if ($WorkflowRun.conclusion -ceq 'success') {
            $result.IssuesToClose = @($ExistingIssues)
            $result.CloseComment = "Successful run: $runUrl"
        }
        return $result
    }

    if ($ExistingIssues.Count -eq 0 -and -not $FailureThresholdMet) {
        $result.BelowThreshold = $true
        return $result
    }

    $failedRunText = "Failed run: $runUrl"
    if (-not $IsModule -and $PlatformTeam) {
        $failedRunText += "`n`n@$PlatformTeam, the ``$($WorkflowRun.name)`` workflow has failed. Please investigate the linked run."
        $result.NotifiedHandles = @($PlatformTeam)
    }

    if ($ExistingIssues.Count -eq 0) {
        $isOrphaned = $IsModule -and $Owners.Count -eq 0
        $ownerLogins = @($Owners | Where-Object { $_.Type -ceq 'user' } | ForEach-Object { $_.Handle })
        $mentions = (@($Owners | ForEach-Object { $_.Handle }) | ForEach-Object { "@$_" }) -join ', '

        if (-not $IsModule) {
            $taggingComment = $script:AvmWorkflowFailurePlatformTaggingComment
        }
        elseif ($isOrphaned) {
            $taggingComment = "> [!IMPORTANT]`n> This module is currently orphaned (has no owner), therefore expect a higher response time.`n> @Azure/azure-verified-modules-tooling-contributors, the workflow for the ``$($WorkflowRun.name)`` module has failed. Please investigate the failed workflow run."
        }
        else {
            $taggingComment = "> [!IMPORTANT]`n> $mentions, the workflow for the ``$($WorkflowRun.name)`` module has failed. Please investigate the failed workflow run. If you are not able to do so, please inform the AVM core team to take over."
        }

        $result.CreateIssueTitle = $issueTitle
        $result.CreateIssueBody = $failedRunText
        if ($IsModule -or -not $PlatformTeam) {
            $result.CreateIssueLabels = @($script:AvmWorkflowFailureAvmLabel, $script:AvmWorkflowFailureBugLabel)
        }
        $result.TaggingComment = if (-not $IsModule -and $PlatformTeam) { $null } else { $taggingComment }
        $result.NotifiedHandles = @(if (-not $IsModule -or $isOrphaned) {
                if (-not $IsModule -and $PlatformTeam) { $PlatformTeam } else { 'Azure/azure-verified-modules-tooling-contributors' }
            }
            else {
                $Owners | ForEach-Object { $_.Handle }
            })
        if ($ownerLogins.Count -gt 0) {
            $result.AssigneeToAdd = $ownerLogins[0]
        }
        return $result
    }

    # One or more open issues already track this workflow. Comment on the newest; any older
    # duplicates (which should not exist under normal operation, but did in the original due to
    # a prior race) are labelled and closed in favour of the newest.
    $sortedIssues = @($ExistingIssues | Sort-Object -Property 'createdAt' -Descending)
    $newestIssue = $sortedIssues[0]
    $duplicateIssues = @(if ($sortedIssues.Count -gt 1) { $sortedIssues[1..($sortedIssues.Count - 1)] })

    $result.DuplicateIssuesToClose = $duplicateIssues
    if ($ExistingCommentBodiesToday -notcontains $failedRunText) {
        $result.CommentIssueUrl = $newestIssue.url
        $result.CommentBody = $failedRunText
    }
    return $result
}

function Set-AvmWorkflowFailureIssueForRun {
    <#
    .SYNOPSIS
    Creates, comments on or closes the failure issue for one workflow's
    latest run, and returns the outcome for the run summary.

    .OUTPUTS
    An ordered dictionary with Workflow, RunUrl, Status (Created, Commented,
    AlreadyReported, Closed or Unchanged), IssueUrl, ClosedIssueUrls,
    DuplicateIssueUrls, Assignee and Notified.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)] [object] $WorkflowRun,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $ExistingIssues,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Owners,
        [Parameter(Mandatory)] [bool] $IsModule,
        [string] $PlatformTeam,
        [bool] $FailureThresholdMet = $true
    )

    $workflowName = [string]$WorkflowRun.name
    $runUrl = [string]$WorkflowRun.html_url
    $outcome = [ordered]@{
        Workflow           = $workflowName
        RunUrl             = $runUrl
        Status             = 'Unchanged'
        IssueUrl           = $null
        ClosedIssueUrls    = @()
        DuplicateIssueUrls = @()
        Assignee           = $null
        Notified           = @()
    }

    $existingCommentBodiesToday = @()
    $newest = $null
    if ($ExistingIssues.Count -gt 0) {
        $newest = @($ExistingIssues | Sort-Object -Property 'createdAt' -Descending)[0]
        $existingCommentBodiesToday = @(Get-AvmWorkflowFailureIssueCommentsToday -Repository $Repository `
            -Number $newest.number -All:([bool]$PlatformTeam))
        if ($null -ne $newest.PSObject.Properties['body']) {
            $existingCommentBodiesToday += [string]$newest.body
        }
    }

    $routing = Resolve-AvmWorkflowFailureRouting -WorkflowRun $WorkflowRun -ExistingIssues $ExistingIssues `
        -Owners $Owners -IsModule $IsModule -ExistingCommentBodiesToday $existingCommentBodiesToday `
        -PlatformTeam $PlatformTeam -FailureThresholdMet $FailureThresholdMet
    if ($routing.BelowThreshold) {
        $outcome.Status = 'BelowThreshold'
        return $outcome
    }

    $issuesToClose = @($routing.IssuesToClose | Where-Object { $null -ne $_ })
    if ($issuesToClose.Count -gt 0) {
        $outcome.Status = 'Closed'
        $outcome.ClosedIssueUrls = @($issuesToClose | ForEach-Object { [string]$_.url })
        Write-Host "Workflow [$workflowName] succeeded in run [$runUrl]. Closing issue(s): $($outcome.ClosedIssueUrls -join ', ')"
    }
    foreach ($issueToClose in $issuesToClose) {
        if ($PSCmdlet.ShouldProcess("Issue [$($issueToClose.url)]", 'Close (run succeeded)')) {
            $null = Invoke-RepositoryGitHub -Arguments @('issue', 'close', $issueToClose.url, '--repo', $Repository, '--comment', $routing.CloseComment)
        }
    }

    $duplicateIssues = @($routing.DuplicateIssuesToClose | Where-Object { $null -ne $_ })
    if ($duplicateIssues.Count -gt 0) {
        $outcome.DuplicateIssueUrls = @($duplicateIssues | ForEach-Object { [string]$_.url })
        Write-Host "Closing duplicate issue(s) for workflow [$workflowName]: $($outcome.DuplicateIssueUrls -join ', ')"
    }
    foreach ($duplicateIssue in $duplicateIssues) {
        if ($PSCmdlet.ShouldProcess("Issue [$($duplicateIssue.url)]", 'Label as duplicate and close')) {
            if (-not $PlatformTeam) {
                $null = Invoke-RepositoryGitHub -Arguments @('issue', 'edit', $duplicateIssue.url, '--repo', $Repository, '--add-label', $script:AvmWorkflowFailureDuplicateLabel)
            }
            $null = Invoke-RepositoryGitHub -Arguments @('issue', 'close', $duplicateIssue.url, '--repo', $Repository, '--reason', 'not planned', '--comment', "This issue is succeeded by a newer issue for the same workflow.")
        }
    }

    if ($routing.CommentIssueUrl) {
        $outcome.Status = 'Commented'
        $outcome.IssueUrl = [string]$routing.CommentIssueUrl
        $outcome.Notified = $routing.NotifiedHandles
        Write-Host "Workflow [$workflowName] failed again in run [$runUrl]. Commenting on issue [$($routing.CommentIssueUrl)]."
        if ($PSCmdlet.ShouldProcess("Comment on issue [$($routing.CommentIssueUrl)]", 'Add')) {
            $null = Invoke-RepositoryGitHub -Arguments @('issue', 'comment', $routing.CommentIssueUrl, '--repo', $Repository, '--body', $routing.CommentBody)
        }
    }
    elseif ($routing.IsFailure -and $null -ne $newest) {
        $outcome.Status = 'AlreadyReported'
        $outcome.IssueUrl = [string]$newest.url
        Write-Host "Workflow [$workflowName] failed in run [$runUrl], which issue [$($newest.url)] already reports today."
    }

    if ($routing.CreateIssueTitle) {
        $outcome.Status = 'Created'
        $outcome.Assignee = $routing.AssigneeToAdd
        $outcome.Notified = $routing.NotifiedHandles
        $assigneeText = if ($routing.AssigneeToAdd) { $routing.AssigneeToAdd } else { 'nobody' }
        Write-Host "Workflow [$workflowName] failed in run [$runUrl]. Creating issue [$($routing.CreateIssueTitle)], assigning $assigneeText and notifying $(Format-AvmRunSummaryList -Values $routing.NotifiedHandles)."
        if ($PSCmdlet.ShouldProcess("Issue [$($routing.CreateIssueTitle)]", 'Create')) {
            $createArguments = @('issue', 'create', '--repo', $Repository, '--title', $routing.CreateIssueTitle, '--body', $routing.CreateIssueBody)
            foreach ($label in $routing.CreateIssueLabels) { $createArguments += @('--label', $label) }
            $issueUrl = (Invoke-RepositoryGitHub -Arguments $createArguments | Select-Object -Last 1)
            $outcome.IssueUrl = [string]$issueUrl
            Write-Host "Created issue [$issueUrl]."

            if ($routing.AssigneeToAdd) {
                $null = Invoke-RepositoryGitHub -Arguments @('issue', 'edit', $issueUrl, '--repo', $Repository, '--add-assignee', $routing.AssigneeToAdd)
            }
            if ($routing.TaggingComment) {
                $null = Invoke-RepositoryGitHub -Arguments @('issue', 'comment', $issueUrl, '--repo', $Repository, '--body', $routing.TaggingComment)
            }
        }
    }
    return $outcome
}

function Write-AvmWorkflowFailureIssuesSummary {
    <#
    .SYNOPSIS
    Summarizes a workflow failure sweep: totals, and the issues created,
    commented on or closed, with who was assigned and notified.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Outcomes,
        [Parameter(Mandatory)] [int] $WithoutRunCount,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Failures,
        [switch] $DryRun
    )

    $count = { param($Status) @($Outcomes | Where-Object { $_.Status -ceq $Status }).Count }
    $thresholdText = if ((& $count 'BelowThreshold') -gt 0) { "$(& $count 'BelowThreshold') below the failure threshold, " } else { '' }
    $overview = "$($Outcomes.Count + $WithoutRunCount + $Failures.Count) workflow(s) checked in [$Repository]: " +
        "$(& $count 'Created') new issue(s), " +
        "$(& $count 'Commented') repeat failure(s) commented, " +
        "$(& $count 'AlreadyReported') already reported today, " +
        "$(& $count 'Closed') fixed (issues closed), " +
        "$WithoutRunCount without a completed run, " + $thresholdText +
        "$($Failures.Count) failed."

    $issueLink = {
        param([string] $Url)
        if ([string]::IsNullOrWhiteSpace($Url)) { return 'new issue' }
        "[#$(($Url -split '/')[-1])]($Url)"
    }
    $verb = if ($DryRun) {
        @{ Create = 'would create'; Assign = 'assign'; Notify = 'notify'; Comment = 'would comment on the repeat failure'; Close = 'would close after a successful run'; Duplicate = 'would close duplicate(s)' }
    }
    else {
        @{ Create = 'created'; Assign = 'assigned'; Notify = 'notified'; Comment = 'commented on the repeat failure'; Close = 'closed after a successful run'; Duplicate = 'closed duplicate(s)' }
    }

    $logLines = [System.Collections.Generic.List[string]]::new()
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($outcome in @($Outcomes | Where-Object { $_.Status -in @('Created', 'Commented', 'Closed', 'BelowThreshold') -or $_.DuplicateIssueUrls.Count -gt 0 })) {
        switch ($outcome.Status) {
            'Created' {
                $logLine = "$($verb.Create) $(if ($outcome.IssueUrl) { $outcome.IssueUrl } else { 'an issue' }), $($verb.Assign) $(Format-AvmRunSummaryList -Values @($outcome.Assignee) -Empty 'nobody') and $($verb.Notify) $(Format-AvmRunSummaryList -Values $outcome.Notified)"
                $action = "$($verb.Create), $($verb.Assign) $(Format-AvmRunSummaryList -Values @($outcome.Assignee) -AsCode -Empty 'nobody') and $($verb.Notify) $(Format-AvmRunSummaryList -Values $outcome.Notified -AsCode)"
                $issues = & $issueLink $outcome.IssueUrl
            }
            'Commented' {
                $logLine = "$($verb.Comment) $($outcome.IssueUrl)"
                $action = $verb.Comment
                $issues = & $issueLink $outcome.IssueUrl
            }
            'Closed' {
                $logLine = "$($verb.Close): $($outcome.ClosedIssueUrls -join ', ')"
                $action = $verb.Close
                $issues = @($outcome.ClosedIssueUrls | ForEach-Object { & $issueLink $_ }) -join ', '
            }
            'BelowThreshold' {
                $logLine = 'no issue created; failure threshold not met'
                $action = $logLine
                $issues = 'none'
            }
            default {
                $logLine = "issue $($outcome.IssueUrl) unchanged"
                $action = 'no change'
                $issues = & $issueLink $outcome.IssueUrl
            }
        }
        if ($outcome.DuplicateIssueUrls.Count -gt 0) {
            $logLine += "; $($verb.Duplicate) $($outcome.DuplicateIssueUrls -join ', ')"
            $action += "; $($verb.Duplicate) $(@($outcome.DuplicateIssueUrls | ForEach-Object { & $issueLink $_ }) -join ', ')"
        }
        $logLines.Add("$($outcome.Workflow): $logLine (run $($outcome.RunUrl))")
        $rows.Add([string[]]@(
                (Format-AvmRunSummaryList -Values @($outcome.Workflow) -AsCode),
                "[run]($($outcome.RunUrl))",
                $issues,
                ($action.Substring(0, 1).ToUpperInvariant() + $action.Substring(1))
            ))
    }

    Write-AvmRunSummary -Title 'Workflow failure issues' -Overview $overview -LogLines $logLines `
        -TableHeaders @('Workflow', 'Latest run', 'Issue', 'Action') -TableRows $rows.ToArray() `
        -Failures $Failures -DryRun:$DryRun
}

function Invoke-AvmWorkflowFailureIssues {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [string] $Branch = 'main',
        [string] $DefaultRef = 'main',
        [string[]] $WorkflowName = @(),
        [string] $PlatformTeam,
        [ValidateRange(1, 100)][int] $FailureThreshold = 1
    )

    try {
        $workflows = @(Get-AvmWorkflowFailureWorkflows -Repository $Repository -WorkflowName $WorkflowName)
        Write-Verbose "Evaluating [$($workflows.Count)] workflow(s) in [$Repository]." -Verbose
        $openIssues = @(Get-AvmWorkflowFailureOpenIssues -Repository $Repository)
        $catalogIndex = @{}
        if (@($workflows | Where-Object { $null -ne (Get-AvmWorkflowFailureModuleReference -WorkflowName $_.name) }).Count -gt 0) {
            $catalogIndex = Get-AvmReviewerRoutingCatalogIndex -Repository $Repository
        }
    }
    catch {
        # A pre-loop setup failure is fatal (there is nothing left to sweep), but a bare
        # rethrow can be rendered without detail by the host. Guarantee the full exception
        # always reaches the log before propagating it unchanged.
        Write-Host "FATAL: Failed to prepare the workflow failure issue sweep for [$Repository]."
        Write-Host "FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
        Write-Host $_.ScriptStackTrace
        throw
    }

    $outcomes = [System.Collections.Generic.List[object]]::new()
    $failures = [System.Collections.Generic.List[string]]::new()
    $withoutRunCount = 0
    $total = $workflows.Count
    $index = 0
    foreach ($workflow in $workflows) {
        $index++
        # Printed unconditionally, before any network call for this workflow, so a run that
        # dies without an exception (e.g. a process kill) still leaves an unambiguous
        # last-seen item in the log, independent of gh's own argument echo.
        Write-Verbose "[$index/$total] Checking workflow [$($workflow.name)]." -Verbose
        try {
            $failureCount = 1
            $latestRun = $null
            if ($FailureThreshold -gt 1) {
                $history = @(Get-AvmWorkflowFailureRunHistory -Repository $Repository -WorkflowId $workflow.id `
                        -Branch $Branch -Count $FailureThreshold)
                if ($history.Count -gt 0) {
                    $latestRun = $history[0]
                    $failureCount = @($history | Where-Object { Test-AvmWorkflowFailureConclusion -Conclusion $_.conclusion }).Count
                    Write-Host "Workflow [$($workflow.name)]: $failureCount/$FailureThreshold consecutive failure(s)."
                }
            }
            else {
                $latestRun = Get-AvmWorkflowFailureLatestRun -Repository $Repository -WorkflowId $workflow.id -Branch $Branch
            }
            if ($null -eq $latestRun) {
                Write-Verbose "Workflow [$($workflow.name)] has no completed run on [$Branch] yet. Skipping."
                $withoutRunCount++
                continue
            }

            $issueTitle = "$script:AvmWorkflowFailureIssueTitlePrefix $($workflow.name)"
            $existingIssues = @($openIssues | Where-Object { $_.title -ceq $issueTitle })

            $topLevelModulePath = Get-AvmWorkflowFailureModuleReference -WorkflowName $workflow.name
            $isModule = $null -ne $topLevelModulePath
            $owners = @()
            if ($isModule) {
                $owners = @(Get-AvmModuleOwners -TopLevelModulePath $topLevelModulePath -CatalogIndex $catalogIndex -Repository $Repository -Ref $DefaultRef)
            }

            $outcome = Set-AvmWorkflowFailureIssueForRun -WorkflowRun $latestRun -Repository $Repository `
                -ExistingIssues $existingIssues -Owners $owners -IsModule $isModule -PlatformTeam $PlatformTeam `
                -FailureThresholdMet:($failureCount -ge $FailureThreshold) -WhatIf:$WhatIfPreference
            $outcomes.Add($outcome)
        }
        catch {
            # A single workflow's issue handling must not stop the remaining ones on a scheduled run.
            $failures.Add("[$($workflow.name)]: $($_.Exception.Message)")
            Write-Warning "Failed to manage the issue for workflow [$($workflow.name)]. $($_.Exception.Message)"
        }
    }

    Write-AvmWorkflowFailureIssuesSummary -Repository $Repository -Outcomes $outcomes.ToArray() `
        -WithoutRunCount $withoutRunCount -Failures $failures.ToArray() -DryRun:$WhatIfPreference

    if ($failures.Count -gt 0) {
        throw [System.AggregateException]::new(($failures -join [System.Environment]::NewLine))
    }
}
