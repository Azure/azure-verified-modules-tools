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
#  - The gh pr edit write only happens when the desired reviewers
#    differ from the current ones. Any write bumps updatedAt, which would
#    otherwise keep every routed pull request inside the scheduled lookback
#    window forever (a self-sustaining feedback loop).
#  - Idempotent: skips the author, already-requested reviewers, and authors
#    of existing reviews.
#  - One failing pull request must not abort the sweep.

$script:AvmPrReviewerRoutingFallbackTeam = 'Azure/azure-verified-modules-module-owners'
$script:AvmPrReviewerRoutingFields = 'author,number,url,isDraft,isCrossRepository,reviewRequests,reviews,headRefOid,state'

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
        [ValidateRange(0, [int]::MaxValue)] [int] $UpdatedWithinMinutes = 0,
        [switch] $IncludeDraft
    )

    if (-not [string]::IsNullOrWhiteSpace($PullRequestUrl)) {
        $sanitized = $PullRequestUrl -replace '^https://api\.github\.com/repos/([^/]+/[^/]+)/pulls/', 'https://github.com/$1/pull/'
        $pullRequest = Invoke-RepositoryGitHub -AsJson -Arguments @(
            'pr', 'view', $sanitized, '--repo', $Repository, '--json', $script:AvmPrReviewerRoutingFields
        )
        if ($null -eq $pullRequest -or $null -eq $pullRequest.number) {
            throw [System.InvalidOperationException]::new("Unable to retrieve pull request '$PullRequestUrl'.")
        }
        return @($pullRequest)
    }

    $pullRequests = @(Invoke-RepositoryGitHub -AsJson -Arguments @(
        'pr', 'list', '--repo', $Repository, '--state', 'open', '--limit', ([int]::MaxValue.ToString([cultureinfo]::InvariantCulture)),
        '--json', "$($script:AvmPrReviewerRoutingFields),updatedAt"
    ))
    if (-not $IncludeDraft) {
        $pullRequests = @($pullRequests | Where-Object { -not $_.isDraft })
    }
    if ($UpdatedWithinMinutes -gt 0) {
        $cutoff = (Get-Date).ToUniversalTime().AddMinutes(-$UpdatedWithinMinutes)
        $pullRequests = @($pullRequests | Where-Object { $_.updatedAt -and ([datetime]$_.updatedAt).ToUniversalTime() -ge $cutoff })
    }
    return $pullRequests
}

function Set-AvmForkE2eGuidance {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object] $PullRequest,
        [Parameter(Mandatory)] [string] $Repository,
        [ValidateSet('bicep', 'terraform')] [string] $Ecosystem
    )

    if (-not $PullRequest.PSObject.Properties['isCrossRepository'] -or
        $null -eq $PullRequest.isCrossRepository -or -not $PullRequest.PSObject.Properties['state']) {
        throw [System.IO.InvalidDataException]::new("Missing fork or state information for '$($PullRequest.url)'.")
    }
    if (-not $PullRequest.isCrossRepository -or $PullRequest.state -ine 'open') {
        return
    }

    $marker = '<!-- avm-fork-e2e-guidance:v1 -->'
    $page = 1
    do {
        $comments = @(Invoke-RepositoryGitHub -AsJson -ReadOnly -Arguments @(
            'api', "repos/$Repository/issues/$($PullRequest.number)/comments?per_page=100&page=$page",
            '--hostname', 'github.com'
        ))
        foreach ($comment in $comments) {
            if ($null -ne $comment.user -and $comment.user.login -eq 'azure-verified-modules[bot]' -and
                $comment.body -and $comment.body.Contains($marker)) {
                return
            }
        }
        $page++
    } while ($comments.Count -eq 100)

    $guide = "https://azure.github.io/Azure-Verified-Modules/contributing/$Ecosystem/contribution-flow/"
    $body = @"
$marker
E2E tests cannot run from a fork pull request because it cannot access upstream credentials. When this contribution is ready for E2E testing, an authorized Microsoft FTE must review the current PR head and follow the [release-branch handoff process]($guide#running-e2e-for-external-contributions). A same-repository follow-up PR can then run the credentialed tests.
"@
    if ($PSCmdlet.ShouldProcess($PullRequest.url, 'Post fork E2E guidance')) {
        $null = Invoke-RepositoryGitHub -Arguments @(
            'api', '--hostname', 'github.com', '--method', 'POST',
            "repos/$Repository/issues/$($PullRequest.number)/comments", '-f', "body=$body"
        ) -MaxRetries 0
    }
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
    Computes the desired reviewer handles for one pull request,
    without applying them. Kept side-effect free so it can be unit tested
    without mocking `gh pr edit`.

    .OUTPUTS
    A hashtable with NewReviewers (what to add), plus the reasoning for the
    log: Modules (each changed module with its owners and owner source),
    OrphanedModules, CoreTeamPaths, ReviewerModules (owner handle -> the
    changed modules they own) and SkippedReviewers (owners not requested,
    with the reason).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [object] $PullRequest,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [hashtable] $CatalogIndex,
        [Parameter(Mandatory)] [string[]] $ChangedFilePaths,
        [ValidateSet('bicep', 'terraform')] [string] $Ecosystem = 'bicep',
        [hashtable] $EligibilityCache = @{}
    )

    $topLevelModulePaths = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    $touchedMetadataModulePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $coreTeamPaths = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($path in $ChangedFilePaths) {
        $topLevelModulePath = if ($Ecosystem -ceq 'terraform') { '.' } else { Get-AvmBicepTopLevelModulePath -Path $path }
        if ($null -eq $topLevelModulePath -or $path -like '*avm.core.team.tests.ps1' -or $path -like '*.e2eignore') {
            $null = $coreTeamPaths.Add($path)
        }
        if ($null -eq $topLevelModulePath) {
            continue
        }
        $null = $topLevelModulePaths.Add($topLevelModulePath)
        $metadataPath = if ($topLevelModulePath -ceq '.') { 'metadata.json' } else { "$topLevelModulePath/metadata.json" }
        if ($path -ceq $metadataPath) {
            $null = $touchedMetadataModulePaths.Add($topLevelModulePath)
        }
    }

    # Modules added or edited by this pull request are not yet in the (up to
    # ~4h stale) published catalog, so metadata.json at the pull request head
    # is authoritative whenever the module isn't indexed yet or the pull
    # request itself edits that module's metadata.json.
    $headRef = [string]$PullRequest.headRefOid
    $reviewState = Get-AvmPrReviewerRoutingReviewState -PullRequest $PullRequest
    # Keyed by Handle so the same owner declared on multiple modules is only
    # requested once; the value keeps its {Handle, Type} record so team-vs-
    # user is decided purely by Type below, never by inferring from '/'.
    $owningHandles = [System.Collections.Generic.SortedDictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $reviewerModules = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $reviewerTypes = @{}
    $fallbackModules = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    $eligibleOwners = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $ineligibleOwners = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $authorOwnedModules = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
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
        elseif ($owners.Count -eq 1 -and $owners[0].Type -ceq 'user' -and $owners[0].Handle -ieq $reviewState.Author) {
            $authorOwnedModules.Add($topLevelModulePath)
        }
        foreach ($owner in $owners) {
            $owningHandles[$owner.Handle] = $owner
            $reviewerTypes[$owner.Handle] = $owner.Type
            if (-not $reviewerModules.ContainsKey($owner.Handle)) {
                $reviewerModules[$owner.Handle] = [System.Collections.Generic.List[string]]::new()
            }
            $reviewerModules[$owner.Handle].Add($topLevelModulePath)
        }
    }
    $orphanedModules = @($modules | Where-Object { $_.Owners.Count -eq 0 } | ForEach-Object { $_.ModulePath })

    $newReviewers = [System.Collections.Generic.List[string]]::new()
    $skippedReviewers = [System.Collections.Generic.List[object]]::new()
    foreach ($owner in $owningHandles.Values) {
        $reason = $null
        if ($owner.Type -ceq 'team') {
            if ($reviewState.RequestedTeams.Contains(($owner.Handle -split '/')[-1])) { $reason = 'review already requested' }
        }
        elseif ($owner.Handle -ieq $reviewState.Author) { $reason = 'pull request author' }
        elseif ($reviewState.RequestedUsers.Contains($owner.Handle)) { $reason = 'review already requested' }
        elseif ($reviewState.ReviewedUsers.Contains($owner.Handle)) { $reason = 'already reviewed' }

        $eligibility = Get-AvmPrReviewerRoutingEligibility -Repository $Repository -Handle $owner.Handle -Type $owner.Type -Cache $EligibilityCache
        if ($eligibility.Eligible) {
            $null = $eligibleOwners.Add($owner.Handle)
        }
        else {
            if ($owner.Handle -ieq $script:AvmPrReviewerRoutingFallbackTeam) {
                throw [System.InvalidOperationException]::new("Fallback owners group [$($owner.Handle)] cannot review [$Repository]: $($eligibility.Reason).")
            }
            $ineligibleOwners[$owner.Handle] = $eligibility.Reason
            if ($null -eq $reason -or $reason -ceq 'review already requested') {
                $reason = "ineligible: $($eligibility.Reason)"
            }
        }

        if ($null -eq $reason) {
            $newReviewers.Add($owner.Handle)
        }
        else {
            $skippedReviewers.Add([ordered]@{ Handle = $owner.Handle; Reason = $reason })
        }
    }
    foreach ($module in $modules) {
        if ($module.Owners.Count -eq 0) {
            continue
        }
        $hasEligibleOwner = $false
        foreach ($ownerHandle in $module.Owners) {
            if ($eligibleOwners.Contains($ownerHandle)) {
                $hasEligibleOwner = $true
                break
            }
        }
        if (-not $hasEligibleOwner) {
            $null = $fallbackModules.Add($module.ModulePath)
        }
    }
    foreach ($owner in $owningHandles.Values) {
        if (-not $ineligibleOwners.ContainsKey($owner.Handle) -or
            -not @($reviewerModules[$owner.Handle] | Where-Object { $fallbackModules.Contains($_) }).Count) {
            continue
        }
        $warning = "Owner [$($owner.Handle)] is ineligible to review pull request [$($PullRequest.url)] in [$Repository]: " +
            "$($ineligibleOwners[$owner.Handle]). No module owner has repository write access. " +
            "Using owners group [$script:AvmPrReviewerRoutingFallbackTeam] instead."
        $warnings.Add($warning)
        Write-AvmPrReviewerRoutingWarning -Message $warning
    }
    if ($fallbackModules.Count -gt 0) {
        $fallback = $script:AvmPrReviewerRoutingFallbackTeam
        $reviewerTypes[$fallback] = 'team'
        if (-not $reviewerModules.ContainsKey($fallback)) {
            $reviewerModules[$fallback] = [System.Collections.Generic.List[string]]::new()
        }
        foreach ($modulePath in $fallbackModules) {
            if (-not $reviewerModules[$fallback].Contains($modulePath)) {
                $reviewerModules[$fallback].Add($modulePath)
            }
        }
        if (-not $newReviewers.Contains($fallback)) {
            $eligibility = Get-AvmPrReviewerRoutingEligibility -Repository $Repository -Handle $fallback -Type team -Cache $EligibilityCache
            if (-not $eligibility.Eligible) {
                throw [System.InvalidOperationException]::new("Fallback owners group [$fallback] cannot review [$Repository]: $($eligibility.Reason).")
            }
            if ($reviewState.RequestedTeams.Contains(($fallback -split '/')[-1])) {
                if (-not @($skippedReviewers | Where-Object { $_.Handle -ieq $fallback }).Count) {
                    $skippedReviewers.Add([ordered]@{ Handle = $fallback; Reason = 'review already requested' })
                }
            }
            else {
                $newReviewers.Add($fallback)
            }
        }
    }
    $newReviewers.Sort([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($handle in @($reviewerModules.Keys)) {
        $reviewerModules[$handle].Sort([System.StringComparer]::Ordinal)
        $reviewerModules[$handle] = @($reviewerModules[$handle])
    }

    return @{
        NewReviewers     = @($newReviewers)
        Modules          = @($modules)
        OrphanedModules  = $orphanedModules
        CoreTeamPaths    = @($coreTeamPaths)
        ReviewerModules  = $reviewerModules
        ReviewerTypes    = $reviewerTypes
        SkippedReviewers = @($skippedReviewers)
        AuthorOwnedModules = @($authorOwnedModules)
        Warnings         = $warnings.ToArray()
    }
}

function Write-AvmPrReviewerRoutingPlan {
    <#
    .SYNOPSIS
    Logs which modules a pull request changes, who owns them, and the
    reviewers about to be requested.
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
    if ($Routing.AuthorOwnedModules.Count -gt 0) {
        Write-Host "The author is the sole owner of $(Format-AvmRunSummaryList -Values $Routing.AuthorOwnedModules) and cannot review their own pull request."
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
}

function Set-AvmPrReviewerRoutingForPullRequest {
    <#
    .SYNOPSIS
    Routes one pull request and returns its outcome for the run summary.

    .OUTPUTS
    An ordered dictionary with Url, Number, Status (Draft, Closed,
    AlreadyRouted, Updated or WouldUpdate), NewReviewers, ReviewerModules
    and Warnings.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)] [object] $PullRequest,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [hashtable] $CatalogIndex,
        [ValidateSet('bicep', 'terraform')] [string] $Ecosystem = 'bicep',
        [hashtable] $EligibilityCache = @{}
    )

    $pr = $PullRequest
    $outcome = [ordered]@{
        Url             = [string]$pr.url
        Number          = $pr.number
        Status          = $null
        NewReviewers    = @()
        ReviewerModules = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
        Warnings        = @()
    }
    if ($pr.isDraft) {
        Write-Host "Pull request [$($pr.url)] is a draft. Skipping."
        $outcome.Status = 'Draft'
        return $outcome
    }
    if ($pr.PSObject.Properties['state'] -and $pr.state -ine 'open') {
        Write-Host "Pull request [$($pr.url)] is no longer open. Skipping."
        $outcome.Status = 'Closed'
        return $outcome
    }

    $changedFilePaths = @(Get-AvmPrReviewerRoutingChangedFiles -Repository $Repository -Number $pr.number)
    $routing = Resolve-AvmPrReviewerRouting -PullRequest $pr -Repository $Repository -CatalogIndex $CatalogIndex `
        -ChangedFilePaths $changedFilePaths -Ecosystem $Ecosystem -EligibilityCache $EligibilityCache
    $outcome.Warnings = $routing.Warnings

    # Only write when something actually changes, so a reprocessed pull
    # request is not touched again. An unnecessary write would bump its
    # updatedAt and keep it permanently inside the scheduled lookback window.
    if ($routing.NewReviewers.Count -eq 0) {
        Write-Host "Pull request [$($pr.url)] is already routed. Nothing to change."
        $outcome.Status = 'AlreadyRouted'
        return $outcome
    }

    Write-AvmPrReviewerRoutingPlan -PullRequest $pr -Routing $routing

    $editArguments = @('pr', 'edit', $pr.url, '--repo', $Repository)
    if ($routing.NewReviewers.Count -gt 0) {
        $editArguments += @('--add-reviewer', ($routing.NewReviewers -join ','))
    }
    $outcome.Status = 'WouldUpdate'
    if ($PSCmdlet.ShouldProcess("Reviewers [$($routing.NewReviewers -join ', ')] on pull request [$($pr.url)]", 'Add')) {
        $null = Invoke-RepositoryGitHub -Arguments $editArguments
        Assert-AvmPrReviewerRoutingApplied -PullRequest $pr -Repository $Repository -Routing $routing
        $outcome.Status = 'Updated'
    }

    $outcome.NewReviewers = $routing.NewReviewers
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
    $closedCount = @($Outcomes | Where-Object { $_.Status -ceq 'Closed' }).Count
    if ($closedCount -gt 0) {
        $overview += " $closedCount no longer open."
    }
    $warnings = @($Outcomes | ForEach-Object { $_.Warnings })
    if ($warnings.Count -gt 0) {
        $overview += " $($warnings.Count) warning(s)."
    }

    $logLines = [System.Collections.Generic.List[string]]::new()
    $rows = [System.Collections.Generic.List[object]]::new()
    $reviewersLabel = if ($DryRun) { 'Reviewers to request' } else { 'Reviewers requested' }
    foreach ($outcome in $changed) {
        $reviewers = @($outcome.NewReviewers | ForEach-Object { "$_ for $(Format-AvmRunSummaryList -Values $outcome.ReviewerModules[$_] -Limit 10)" })
        $logLines.Add($outcome.Url)
        $logLines.Add("  $($reviewersLabel): $(if ($reviewers.Count -gt 0) { $reviewers -join '; ' } else { 'none' })")
        $reviewerCells = @($outcome.NewReviewers | ForEach-Object {
                "$(Format-AvmRunSummaryList -Values @($_) -AsCode) for $(Format-AvmRunSummaryList -Values $outcome.ReviewerModules[$_] -Limit 10 -AsCode)"
            })
        $rows.Add([string[]]@(
                "[#$($outcome.Number)]($($outcome.Url))",
                $(if ($reviewerCells.Count -gt 0) { $reviewerCells -join '<br>' } else { 'none' })
            ))
    }

    Write-AvmRunSummary -Title 'Pull request reviewer routing' -Overview $overview -LogLines $logLines `
        -TableHeaders @('Pull request', $reviewersLabel) -TableRows $rows.ToArray() `
        -Failures $Failures -Warnings $warnings -DryRun:$DryRun
}

function Invoke-AvmPrReviewerRouting {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [string] $PullRequestUrl,
        [ValidateRange(0, [int]::MaxValue)] [int] $UpdatedWithinMinutes = 0,
        [ValidateSet('bicep', 'terraform')] [string] $Ecosystem = 'bicep',
        [hashtable] $CatalogIndex,
        [AllowEmptyCollection()] [object[]] $PullRequests
    )

    try {
        if (-not $PSBoundParameters.ContainsKey('PullRequests')) {
            $PullRequests = @(Get-AvmPrReviewerRoutingCandidates -Repository $Repository -PullRequestUrl $PullRequestUrl -UpdatedWithinMinutes $UpdatedWithinMinutes -IncludeDraft)
        }
        Write-Verbose "Processing [$($PullRequests.Count)] pull request(s) in [$Repository]." -Verbose
        if (-not $PSBoundParameters.ContainsKey('CatalogIndex')) {
            $CatalogIndex = Get-AvmReviewerRoutingCatalogIndex -Repository $Repository -Ecosystem $Ecosystem
        }
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
    $eligibilityCache = @{}
    $total = $PullRequests.Count
    $index = 0
    foreach ($pr in $PullRequests) {
        $index++
        # Printed unconditionally, before any network call for this pull request, so a run
        # that dies without an exception (e.g. a process kill) still leaves an unambiguous
        # last-seen item in the log, independent of gh's own argument echo.
        Write-Verbose "[$index/$total] Routing pull request [$($pr.url)]." -Verbose
        try {
            if (-not $pr.PSObject.Properties['headRefOid']) {
                $details = @(Get-AvmPrReviewerRoutingCandidates -Repository $Repository -PullRequestUrl $pr.url)
                if ($details.Count -ne 1) {
                    throw [System.InvalidOperationException]::new("Unable to retrieve one pull request for '$($pr.url)'.")
                }
                $pr = $details[0]
            }
            $commentError = $null
            try {
                Set-AvmForkE2eGuidance -PullRequest $pr -Repository $Repository -Ecosystem $Ecosystem -WhatIf:$WhatIfPreference
            }
            catch {
                $commentError = $_.Exception.Message
            }
            try {
                $outcome = Set-AvmPrReviewerRoutingForPullRequest -PullRequest $pr -Repository $Repository `
                    -CatalogIndex $CatalogIndex -Ecosystem $Ecosystem -EligibilityCache $eligibilityCache -WhatIf:$WhatIfPreference
                if ($commentError) { throw [System.InvalidOperationException]::new("Fork guidance: $commentError") }
                $outcomes.Add($outcome)
            }
            catch {
                if ($commentError -and $_.Exception.Message -notlike 'Fork guidance:*') {
                    throw [System.InvalidOperationException]::new("Fork guidance: $commentError; reviewer routing: $($_.Exception.Message)")
                }
                throw
            }
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
