#Requires -Version 7.4

# Ports Set-AvmGitHubPrLabels / Set-AvmGitHubPrLabelsForPr from the retired
# bicep-registry-modules platform tooling (git history commit 2eb210dbb),
# adapted to run cross-repo against the published module catalog with a
# metadata.json fallback (see lib/ModuleOwners.ps1).
#
# Design invariants carried over from the original implementation -- do not
# regress these without a very good reason:
#  - Scheduled only. Never wired to pull_request/pull_request_target: this
#    reads pull request data with a privileged app token, and that token
#    must never be exposed to a run triggered by untrusted fork content.
#  - The gh pr edit write only happens when the desired labels/reviewers
#    differ from the current ones. Any write bumps updatedAt, which would
#    otherwise keep every routed pull request inside the scheduled lookback
#    window forever (a self-sustaining feedback loop).
#  - Idempotent: skips the author, already-requested reviewers, and authors
#    of existing reviews.
#  - One failing pull request must not abort the sweep.

$script:AvmPrReviewerRoutingFallbackTeam = 'Azure/azure-verified-modules-module-owners'
$script:AvmPrReviewerRoutingNeedsCoreTeamLabel = 'Needs: Core Team :genie:'
$script:AvmPrReviewerRoutingNeedsModuleOwnerLabel = 'Needs: Module Owner :mega:'
$script:AvmPrReviewerRoutingOrphanedLabel = 'Status: Module Orphaned :yellow_circle:'
$script:AvmPrReviewerRoutingFields = 'author,number,url,isDraft,reviewRequests,reviews,headRefOid,labels'

function Get-AvmPrReviewerRoutingCandidates {
    <#
    .SYNOPSIS
    Retrieves the pull request(s) a routing run should evaluate: either one
    pull request by URL, or every open pull request updated within the
    lookback window (0 = every open pull request, used by the daily
    full-sweep backstop).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [string] $PullRequestUrl,
        [int] $UpdatedWithinMinutes = 0
    )

    if (-not [string]::IsNullOrWhiteSpace($PullRequestUrl)) {
        $sanitized = $PullRequestUrl.Replace('api.', '').Replace('repos/', '').Replace('pulls/', 'pull/')
        $pullRequest = Invoke-RepositoryGitHub -AsJson -Arguments @(
            'pr', 'view', $sanitized, '--repo', $Repository, '--json', $script:AvmPrReviewerRoutingFields
        )
        if ($null -eq $pullRequest -or $null -eq $pullRequest.number) {
            throw [System.InvalidOperationException]::new("Unable to retrieve pull request '$PullRequestUrl'.")
        }
        return @($pullRequest)
    }

    $pullRequests = @(Invoke-RepositoryGitHub -AsJson -Arguments @(
        'pr', 'list', '--repo', $Repository, '--state', 'open', '--limit', '500',
        '--json', "$($script:AvmPrReviewerRoutingFields),updatedAt"
    ))
    if ($UpdatedWithinMinutes -gt 0) {
        $cutoff = (Get-Date).ToUniversalTime().AddMinutes(-$UpdatedWithinMinutes)
        $pullRequests = @($pullRequests | Where-Object { $_.updatedAt -and ([datetime]$_.updatedAt).ToUniversalTime() -ge $cutoff })
    }
    return $pullRequests
}

function Get-AvmPrReviewerRoutingChangedFiles {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [int] $Number
    )

    $files = @(Invoke-RepositoryGitHub -AsJson -Arguments @(
        'api', '--paginate', "repos/$Repository/pulls/$Number/files?per_page=100",
        '--hostname', 'github.com'
    ))
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $files) {
        if ($file.PSObject.Properties['filename'] -and $file.filename) { $paths.Add([string]$file.filename) }
        if ($file.PSObject.Properties['previous_filename'] -and $file.previous_filename) { $paths.Add([string]$file.previous_filename) }
    }
    return $paths.ToArray()
}

function Resolve-AvmPrReviewerRouting {
    <#
    .SYNOPSIS
    Computes the desired labels and reviewer handles for one pull request,
    without applying them. Kept side-effect free so it can be unit tested
    without mocking `gh pr edit`.

    .OUTPUTS
    A hashtable with NewLabels and NewReviewers (what to add), plus the
    reasoning for the log: Modules (each changed module with its owners and
    owner source), OrphanedModules, CoreTeamPaths, ReviewerModules (owner
    handle -> the changed modules they own) and SkippedReviewers (owners not
    requested, with the reason).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [object] $PullRequest,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [hashtable] $CatalogIndex,
        [Parameter(Mandatory)] [string[]] $ChangedFilePaths
    )

    $topLevelModulePaths = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    $touchedMetadataModulePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $coreTeamPaths = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($path in $ChangedFilePaths) {
        $topLevelModulePath = Get-AvmBicepTopLevelModulePath -Path $path
        if ($null -eq $topLevelModulePath -or $path -like '*avm.core.team.tests.ps1' -or $path -like '*.e2eignore') {
            $null = $coreTeamPaths.Add($path)
        }
        if ($null -eq $topLevelModulePath) {
            continue
        }
        $null = $topLevelModulePaths.Add($topLevelModulePath)
        if ($path -ceq "$topLevelModulePath/metadata.json") {
            $null = $touchedMetadataModulePaths.Add($topLevelModulePath)
        }
    }

    # Modules added or edited by this pull request are not yet in the (up to
    # ~4h stale) published catalog, so metadata.json at the pull request head
    # is authoritative whenever the module isn't indexed yet or the pull
    # request itself edits that module's metadata.json.
    $headRef = [string]$PullRequest.headRefOid
    # Keyed by Handle so the same owner declared on multiple modules is only
    # requested once; the value keeps its {Handle, Type} record so team-vs-
    # user is decided purely by Type below, never by inferring from '/'.
    $owningHandles = [System.Collections.Generic.SortedDictionary[string, object]]::new([System.StringComparer]::Ordinal)
    $reviewerModules = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    $modules = [System.Collections.Generic.List[object]]::new()
    foreach ($topLevelModulePath in $topLevelModulePaths) {
        $forceMetadataLookup = $touchedMetadataModulePaths.Contains($topLevelModulePath)
        $source = if ($forceMetadataLookup -or -not $CatalogIndex.Contains($topLevelModulePath)) { 'metadata.json' } else { 'catalog' }
        $owners = @(Get-AvmModuleOwners -TopLevelModulePath $topLevelModulePath -CatalogIndex $CatalogIndex `
                -Repository $Repository -Ref $headRef -ForceMetadataLookup:$forceMetadataLookup)
        $modules.Add([ordered]@{
                ModulePath = $topLevelModulePath
                Owners     = @($owners | ForEach-Object { $_.Handle })
                Source     = $source
            })
        if ($owners.Count -eq 0) {
            $owners = @([ordered]@{ Handle = $script:AvmPrReviewerRoutingFallbackTeam; Type = 'team' })
        }
        foreach ($owner in $owners) {
            $owningHandles[$owner.Handle] = $owner
            if (-not $reviewerModules.ContainsKey($owner.Handle)) {
                $reviewerModules[$owner.Handle] = [System.Collections.Generic.List[string]]::new()
            }
            $reviewerModules[$owner.Handle].Add($topLevelModulePath)
        }
    }
    $orphanedModules = @($modules | Where-Object { $_.Owners.Count -eq 0 } | ForEach-Object { $_.ModulePath })

    $requestedLogins = @($PullRequest.reviewRequests | Where-Object { $_.PSObject.Properties['login'] -and $_.login } | ForEach-Object { $_.login })
    $requestedTeamSlugs = @($PullRequest.reviewRequests | Where-Object { -not ($_.PSObject.Properties['login'] -and $_.login) } |
            ForEach-Object { if ($_.PSObject.Properties['slug'] -and $_.slug) { $_.slug } elseif ($_.PSObject.Properties['name']) { $_.name } })
    $reviewedLogins = @($PullRequest.reviews | Where-Object { $_.PSObject.Properties['author'] -and $_.author -and $_.author.PSObject.Properties['login'] } |
            ForEach-Object { $_.author.login })
    $authorLogin = if ($PullRequest.PSObject.Properties['author'] -and $PullRequest.author -and $PullRequest.author.PSObject.Properties['login']) {
        $PullRequest.author.login
    } else {
        $null
    }

    $newReviewers = [System.Collections.Generic.List[string]]::new()
    $skippedReviewers = [System.Collections.Generic.List[object]]::new()
    foreach ($owner in $owningHandles.Values) {
        $reason = $null
        if ($owner.Type -ceq 'team') {
            if ($requestedTeamSlugs -contains ($owner.Handle -split '/')[-1]) { $reason = 'review already requested' }
        }
        elseif ($owner.Handle -eq $authorLogin) { $reason = 'pull request author' }
        elseif ($requestedLogins -contains $owner.Handle) { $reason = 'review already requested' }
        elseif ($reviewedLogins -contains $owner.Handle) { $reason = 'already reviewed' }

        if ($null -eq $reason) {
            $newReviewers.Add($owner.Handle)
        }
        else {
            $skippedReviewers.Add([ordered]@{ Handle = $owner.Handle; Reason = $reason })
        }
    }

    $hasOrphanedModule = $orphanedModules.Count -gt 0
    $desiredLabels = @(if ($coreTeamPaths.Count -gt 0 -or $hasOrphanedModule) { $script:AvmPrReviewerRoutingNeedsCoreTeamLabel } else { $script:AvmPrReviewerRoutingNeedsModuleOwnerLabel })
    if ($hasOrphanedModule) {
        $desiredLabels += $script:AvmPrReviewerRoutingOrphanedLabel
    }
    $existingLabels = @($PullRequest.labels | Where-Object { $_.PSObject.Properties['name'] -and $_.name } | ForEach-Object { $_.name })
    $newLabels = @($desiredLabels | Where-Object { $existingLabels -notcontains $_ })

    foreach ($handle in @($reviewerModules.Keys)) {
        $reviewerModules[$handle] = @($reviewerModules[$handle])
    }

    return @{
        NewLabels        = $newLabels
        NewReviewers     = @($newReviewers)
        Modules          = @($modules)
        OrphanedModules  = $orphanedModules
        CoreTeamPaths    = @($coreTeamPaths)
        ReviewerModules  = $reviewerModules
        SkippedReviewers = @($skippedReviewers)
    }
}

function Write-AvmPrReviewerRoutingPlan {
    <#
    .SYNOPSIS
    Logs which modules a pull request changes, who owns them, and the
    reviewers and labels about to be added.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $PullRequest,
        [Parameter(Mandatory)] [hashtable] $Routing
    )

    if ($Routing.Modules.Count -eq 0) {
        Write-Host "Pull request [$($PullRequest.url)] does not change any module."
    }
    else {
        Write-Host "Pull request [$($PullRequest.url)] changes $($Routing.Modules.Count) module(s):"
        foreach ($module in $Routing.Modules) {
            $owners = Format-AvmRunSummaryList -Values $module.Owners -Empty 'no owners declared'
            $source = if ($module.Source -ceq 'metadata.json') { ' (from metadata.json at the pull request head)' } else { '' }
            Write-Host "  $($module.ModulePath): $owners$source"
        }
    }
    if ($Routing.OrphanedModules.Count -gt 0) {
        Write-Warning "$($Routing.OrphanedModules.Count) module(s) declare no owners, so [$script:AvmPrReviewerRoutingFallbackTeam] reviews them instead."
    }
    if ($Routing.CoreTeamPaths.Count -gt 0) {
        Write-Host "Core team review is needed for $($Routing.CoreTeamPaths.Count) changed file(s): $(Format-AvmRunSummaryList -Values $Routing.CoreTeamPaths -Limit 10)"
    }
    if ($Routing.NewReviewers.Count -gt 0) {
        Write-Host 'Requesting reviews from:'
        foreach ($reviewer in $Routing.NewReviewers) {
            Write-Host "  $reviewer for $(Format-AvmRunSummaryList -Values $Routing.ReviewerModules[$reviewer] -Limit 10)"
        }
    }
    if ($Routing.SkippedReviewers.Count -gt 0) {
        $skipped = @($Routing.SkippedReviewers | ForEach-Object { "$($_.Handle) ($($_.Reason))" })
        Write-Host "Not requesting: $($skipped -join ', ')"
    }
    if ($Routing.NewLabels.Count -gt 0) {
        Write-Host "Adding labels: $($Routing.NewLabels -join ', ')"
    }
}

function Set-AvmPrReviewerRoutingForPullRequest {
    <#
    .SYNOPSIS
    Routes one pull request and returns its outcome for the run summary.

    .OUTPUTS
    An ordered dictionary with Url, Number, Status (Draft, AlreadyRouted,
    Updated or WouldUpdate), NewReviewers, NewLabels and ReviewerModules.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)] [object] $PullRequest,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [hashtable] $CatalogIndex
    )

    $pr = $PullRequest
    $outcome = [ordered]@{
        Url             = [string]$pr.url
        Number          = $pr.number
        Status          = $null
        NewReviewers    = @()
        NewLabels       = @()
        ReviewerModules = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    }
    if ($pr.isDraft) {
        Write-Host "Pull request [$($pr.url)] is a draft. Skipping."
        $outcome.Status = 'Draft'
        return $outcome
    }

    $changedFilePaths = @(Get-AvmPrReviewerRoutingChangedFiles -Repository $Repository -Number $pr.number)
    $routing = Resolve-AvmPrReviewerRouting -PullRequest $pr -Repository $Repository -CatalogIndex $CatalogIndex -ChangedFilePaths $changedFilePaths

    # Only write when something actually changes, so a reprocessed pull
    # request is not touched again. An unnecessary write would bump its
    # updatedAt and keep it permanently inside the scheduled lookback window.
    if ($routing.NewLabels.Count -eq 0 -and $routing.NewReviewers.Count -eq 0) {
        Write-Host "Pull request [$($pr.url)] is already routed. Nothing to change."
        $outcome.Status = 'AlreadyRouted'
        return $outcome
    }

    Write-AvmPrReviewerRoutingPlan -PullRequest $pr -Routing $routing

    $editArguments = @('pr', 'edit', $pr.url, '--repo', $Repository)
    foreach ($newLabel in $routing.NewLabels) {
        $editArguments += @('--add-label', $newLabel)
    }
    if ($routing.NewReviewers.Count -gt 0) {
        $editArguments += @('--add-reviewer', ($routing.NewReviewers -join ','))
    }
    $outcome.Status = 'WouldUpdate'
    if ($PSCmdlet.ShouldProcess("Labels [$($routing.NewLabels -join ', ')] and reviewers [$($routing.NewReviewers -join ', ')] on pull request [$($pr.url)]", 'Add')) {
        $null = Invoke-RepositoryGitHub -Arguments $editArguments
        $outcome.Status = 'Updated'
    }

    $outcome.NewReviewers = $routing.NewReviewers
    $outcome.NewLabels = $routing.NewLabels
    foreach ($reviewer in $routing.NewReviewers) {
        $outcome.ReviewerModules[$reviewer] = $routing.ReviewerModules[$reviewer]
    }
    return $outcome
}

function Write-AvmPrReviewerRoutingSummary {
    <#
    .SYNOPSIS
    Summarizes a routing sweep: totals, and who was requested for which
    modules on each updated pull request.
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
    $overview = "$($Outcomes.Count + $Failures.Count) pull request(s) checked in [$Repository]: " +
        "$($changed.Count) $changedLabel, " +
        "$(@($Outcomes | Where-Object { $_.Status -ceq 'AlreadyRouted' }).Count) already routed, " +
        "$(@($Outcomes | Where-Object { $_.Status -ceq 'Draft' }).Count) draft(s) skipped, " +
        "$($Failures.Count) failed."

    $logLines = [System.Collections.Generic.List[string]]::new()
    $rows = [System.Collections.Generic.List[object]]::new()
    $reviewersLabel = if ($DryRun) { 'Reviewers to request' } else { 'Reviewers requested' }
    $labelsLabel = if ($DryRun) { 'Labels to add' } else { 'Labels added' }
    foreach ($outcome in $changed) {
        $reviewers = @($outcome.NewReviewers | ForEach-Object { "$_ for $(Format-AvmRunSummaryList -Values $outcome.ReviewerModules[$_] -Limit 10)" })
        $logLines.Add($outcome.Url)
        $logLines.Add("  $($reviewersLabel): $(if ($reviewers.Count -gt 0) { $reviewers -join '; ' } else { 'none' })")
        $logLines.Add("  $($labelsLabel): $(Format-AvmRunSummaryList -Values $outcome.NewLabels)")
        $reviewerCells = @($outcome.NewReviewers | ForEach-Object {
                "$(Format-AvmRunSummaryList -Values @($_) -AsCode) for $(Format-AvmRunSummaryList -Values $outcome.ReviewerModules[$_] -Limit 10 -AsCode)"
            })
        $rows.Add([string[]]@(
                "[#$($outcome.Number)]($($outcome.Url))",
                $(if ($reviewerCells.Count -gt 0) { $reviewerCells -join '<br>' } else { 'none' }),
                (Format-AvmRunSummaryList -Values $outcome.NewLabels -AsCode)
            ))
    }

    Write-AvmRunSummary -Title 'Pull request reviewer routing' -Overview $overview -LogLines $logLines `
        -TableHeaders @('Pull request', $reviewersLabel, $labelsLabel) -TableRows $rows.ToArray() `
        -Failures $Failures -DryRun:$DryRun
}

function Invoke-AvmPrReviewerRouting {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [string] $PullRequestUrl,
        [int] $UpdatedWithinMinutes = 0
    )

    try {
        $pullRequests = @(Get-AvmPrReviewerRoutingCandidates -Repository $Repository -PullRequestUrl $PullRequestUrl -UpdatedWithinMinutes $UpdatedWithinMinutes)
        Write-Verbose "Processing [$($pullRequests.Count)] pull request(s) in [$Repository]." -Verbose
        $catalogIndex = Get-AvmReviewerRoutingCatalogIndex -Repository $Repository
    }
    catch {
        # A pre-loop setup failure is fatal (there is nothing left to sweep), but a bare
        # rethrow can be rendered without detail by the host. Guarantee the full exception
        # always reaches the log before propagating it unchanged.
        Write-Host "FATAL: Failed to prepare the pull request reviewer routing sweep for [$Repository]."
        Write-Host "FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
        Write-Host $_.ScriptStackTrace
        throw
    }

    $outcomes = [System.Collections.Generic.List[object]]::new()
    $failures = [System.Collections.Generic.List[string]]::new()
    $total = $pullRequests.Count
    $index = 0
    foreach ($pr in $pullRequests) {
        $index++
        # Printed unconditionally, before any network call for this pull request, so a run
        # that dies without an exception (e.g. a process kill) still leaves an unambiguous
        # last-seen item in the log, independent of gh's own argument echo.
        Write-Verbose "[$index/$total] Routing pull request [$($pr.url)]." -Verbose
        try {
            $outcome = Set-AvmPrReviewerRoutingForPullRequest -PullRequest $pr -Repository $Repository -CatalogIndex $catalogIndex -WhatIf:$WhatIfPreference
            $outcomes.Add($outcome)
        }
        catch {
            # A single unroutable pull request must not stop the remaining ones on a scheduled run.
            $failures.Add("[$($pr.url)]: $($_.Exception.Message)")
            Write-Warning "Failed to route pull request [$($pr.url)]. $($_.Exception.Message)"
        }
    }

    Write-AvmPrReviewerRoutingSummary -Repository $Repository -Outcomes $outcomes.ToArray() -Failures $failures.ToArray() -DryRun:$WhatIfPreference

    if ($failures.Count -gt 0) {
        throw [System.AggregateException]::new(($failures -join [System.Environment]::NewLine))
    }
}
