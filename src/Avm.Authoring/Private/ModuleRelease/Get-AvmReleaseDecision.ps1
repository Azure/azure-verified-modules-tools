function Get-AvmReleaseDecision {
    <#
    .SYNOPSIS
        Decide the next release state and actions for a Terraform module repository.

    .DESCRIPTION
        The release decision engine. It is a pure function: it reads the current state and the facts the I/O layer gathered, and returns the new state and the actions to take. It never calls GitHub, Git, or the network.

        Steps:

        1. Validate the facts. Malformed facts throw an ArgumentException.
        2. Parse and validate the state. Damaged or missing state stops here with status 'damaged' and a ReportDamagedState action. The state is never repaired silently.
        3. Build one timeline from new merges, label changes after the label cursor, and comments after the comment cursor. Apply the events in time order. At equal times, merges come first, then label changes, then comments. Each event applies once, and the cursors advance past it.
        4. Summarise the pending release. Flag pull requests that need attention, once for each new flag.
        5. Decide whether to cut off a release, in this order: nothing pending, hold, blocking issues, not yet due, freeze, earlier publication still running, unknown main head. Otherwise cut off the release at the head of main and write its release record.

        Facts:

        - Repository: 'owner/name'.
        - Now: the current UTC time.
        - LatestVersion: the latest published version without a 'v' prefix, or null.
        - MainHead: the commit SHA at the head of main.
        - Freeze: 'none', 'active', or 'unknown'. Missing means unknown. Anything other than 'none' pauses publication.
        - Authorization: Owners (metadata.json owners, or null when unknown), CoreTeam ('org/team', defaults to the core AVM team), and ActorTeams (a map from login to 'org/team' slugs).
        - MergedPullRequests: pull requests merged into main since the latest release. Each has Number, Title, Author, MergedAt, MergeCommit, Body, Labels (the labels present at merge, each with Name, AddedBy, and AddedAt), and ChangedFiles (Path, Status, PreviousPath, and FormatEquivalent for each file, or null when unknown).
        - LabelEvents: label changes on merged pull requests. Each has Id, PullRequest, Label, Action ('labeled' or 'unlabeled'), Actor, and At.
        - Comments: comments on the release issue. Each has Id, CreatedAt, Author, and Body.

        Actions: IgnoreLabelChange, AcceptOptIn, ReportLabelMismatch, AcknowledgeCommand, FlagPullRequest, BlockPublication, StartPublication, and ReportDamagedState.

        Statuses: idle, waiting, held, blocked, frozen, queued, publishing, and damaged.

    .PARAMETER StateJson
        The current state.json text, or null when no state exists.

    .PARAMETER Facts
        The facts described above.

    .PARAMETER Initialize
        Start from an empty state because the repository has no release state yet. Without this switch, missing state is reported as damaged, so a failed read never resets holds or pending work.

    .EXAMPLE
        Get-AvmReleaseDecision -StateJson $stateJson -Facts $facts

        Returns Status, Changed, State, StateJson, Actions, and Summary.

    .OUTPUTS
        Ordered dictionary with Status, Changed, State, StateJson, Actions, and Summary.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $StateJson,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Facts,

        [switch] $Initialize
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $normalized = ConvertTo-AvmReleaseFacts -Facts $Facts
    $actions = [System.Collections.Generic.List[object]]::new()

    $damaged = {
        param([string[]] $Issues, [object] $Document)
        return [ordered]@{
            Status    = 'damaged'
            Changed   = $false
            State     = $Document
            StateJson = $StateJson
            Actions   = @([ordered]@{
                    Type    = 'ReportDamagedState'
                    Issues  = $Issues
                    Message = 'The release state is damaged, so publication stopped. A maintainer must recover it.'
                })
            Summary   = $null
        }
    }

    $originalJson = $null
    if ([string]::IsNullOrWhiteSpace($StateJson)) {
        if (-not $Initialize) {
            return & $damaged -Issues @('$: the release state is missing.') -Document $null
        }
        $state = New-AvmReleaseState -Repository $normalized.Repository
    }
    else {
        if ($Initialize) {
            throw [System.ArgumentException]::new('Initialize applies only when no release state exists.')
        }
        $parsed = ConvertFrom-AvmReleaseJson -Json $StateJson -Kind State -Repository $normalized.Repository
        if (-not $parsed.IsValid) {
            return & $damaged -Issues $parsed.Issues -Document $parsed.Document
        }
        $state = $parsed.Document
        $originalJson = ConvertTo-AvmReleaseJson -InputObject $state -Kind State
    }

    $ticks = {
        param([string] $Timestamp)
        return (ConvertTo-AvmReleaseTimestamp -Value $Timestamp).UtcTicks
    }
    $isAfter = {
        param([string] $At, [long] $Id, [object] $Cursor, [string] $CursorTime)
        if ($null -eq $Cursor) {
            return $true
        }
        $order = [string]::CompareOrdinal($At, $Cursor[$CursorTime])
        return $order -gt 0 -or ($order -eq 0 -and $Id -gt [long]$Cursor['id'])
    }

    $known = [System.Collections.Generic.HashSet[long]]::new()
    $mergedAt = @{}
    foreach ($pullRequest in @($state['pending']['pullRequests'])) {
        $null = $known.Add([long]$pullRequest['number'])
        $mergedAt[[long]$pullRequest['number']] = $pullRequest['mergedAt']
    }
    if ($null -ne $state['publication']) {
        foreach ($entry in @($state['publication']['pullRequests'])) {
            $null = $known.Add([long]$entry['number'])
        }
    }

    $events = [System.Collections.Generic.List[object]]::new()
    foreach ($pullRequest in $normalized.MergedPullRequests) {
        if ($known.Contains($pullRequest.Number)) {
            continue
        }
        $mergedAt[$pullRequest.Number] = $pullRequest.MergedAt
        $events.Add([ordered]@{
                Kind  = 'merge'
                Order = 0
                Ticks = & $ticks -Timestamp $pullRequest.MergedAt
                Id    = $pullRequest.Number
                Item  = $pullRequest
            })
    }
    foreach ($labelEvent in $normalized.LabelEvents) {
        if (& $isAfter -At $labelEvent.At -Id $labelEvent.Id -Cursor $state['labelCursor'] -CursorTime 'at') {
            $events.Add([ordered]@{
                    Kind  = 'label'
                    Order = 1
                    Ticks = & $ticks -Timestamp $labelEvent.At
                    Id    = $labelEvent.Id
                    Item  = $labelEvent
                })
        }
    }
    foreach ($comment in $normalized.Comments) {
        if (& $isAfter -At $comment.CreatedAt -Id $comment.Id -Cursor $state['commentCursor'] -CursorTime 'createdAt') {
            $events.Add([ordered]@{
                    Kind  = 'comment'
                    Order = 2
                    Ticks = & $ticks -Timestamp $comment.CreatedAt
                    Id    = $comment.Id
                    Item  = $comment
                })
        }
    }

    $timeline = @($events | Sort-Object -Property { $_.Ticks }, { $_.Order }, { $_.Id })
    foreach ($timelineEvent in $timeline) {
        $item = $timelineEvent.Item
        switch ($timelineEvent.Kind) {
            'merge' {
                $ingested = ConvertTo-AvmReleasePullRequestRecord -PullRequest $item -Authorization $normalized.Authorization
                $state['pending']['pullRequests'] = @($state['pending']['pullRequests']) + @($ingested.Record)
                $null = $known.Add($item.Number)
                foreach ($action in $ingested.Actions) {
                    $actions.Add($action)
                }
            }
            'label' {
                $merged = $mergedAt[$item.PullRequest]
                if ($null -eq $merged -or [string]::CompareOrdinal($item.At, $merged) -gt 0) {
                    foreach ($action in @(Resolve-AvmReleaseLabelEvent -State $state -LabelEvent $item -Authorization $normalized.Authorization)) {
                        $actions.Add($action)
                    }
                }
                $state['labelCursor'] = [ordered]@{
                    at = $item.At
                    id = $item.Id
                }
            }
            'comment' {
                foreach ($action in @(Resolve-AvmReleaseCommand -State $state -Comment $item -Facts $normalized)) {
                    $actions.Add($action)
                }
                $state['commentCursor'] = [ordered]@{
                    createdAt = $item.CreatedAt
                    id        = $item.Id
                }
            }
        }
    }

    $summary = Get-AvmReleasePendingSummary -State $state -LatestVersion $normalized.LatestVersion

    foreach ($pullRequest in @($state['pending']['pullRequests'] | Sort-Object -Property { [long]$_['number'] })) {
        $number = [long]$pullRequest['number']
        $current = @($summary.Flags | Where-Object { $_.PullRequest -eq $number })
        $previous = @($pullRequest['flags'])
        foreach ($flag in $current) {
            if ($previous -cnotcontains $flag.Code) {
                $actions.Add([ordered]@{
                        Type        = 'FlagPullRequest'
                        PullRequest = $number
                        Flag        = $flag.Code
                        Blocking    = $flag.Blocking
                        Message     = $flag.Message
                    })
            }
        }
        $pullRequest['flags'] = @($current | ForEach-Object { $_.Code } | Sort-Object -Unique)
    }

    $status = $null
    $pending = $state['pending']
    $publication = $state['publication']
    $requested = $null -ne $pending['releaseRequest']
    $trigger = $summary.DueBy
    if ($requested) {
        $trigger = 'release-command'
    }
    $due = $null -ne $summary.DueAt -and [string]::CompareOrdinal($normalized.Now, $summary.DueAt) -ge 0

    $blockPublication = {
        param([object[]] $Issues)
        return [ordered]@{
            Type    = 'BlockPublication'
            Trigger = $trigger
            Issues  = $Issues
            Message = 'The release is due, but publication is blocked until these issues are fixed.'
        }
    }

    if ($summary.TriggeringPullRequests.Count -eq 0) {
        $status = 'idle'
        if ($null -ne $publication) {
            $status = 'publishing'
        }
        elseif ($null -ne $state['hold']) {
            $status = 'held'
        }
    }
    elseif ($null -ne $state['hold']) {
        $status = 'held'
    }
    elseif ($summary.BlockingIssues.Count -gt 0) {
        $status = 'blocked'
        if ($due -or $requested) {
            $actions.Add((& $blockPublication -Issues $summary.BlockingIssues))
        }
    }
    elseif (-not $due -and -not $requested) {
        $status = 'waiting'
    }
    elseif ($normalized.Freeze -ne 'none') {
        $status = 'frozen'
    }
    elseif ($null -ne $publication) {
        $status = 'queued'
    }
    elseif ($null -eq $normalized.MainHead -or $normalized.MainHead -cnotmatch '^[0-9a-f]{40}$') {
        $status = 'blocked'
        $actions.Add((& $blockPublication -Issues @([ordered]@{
                        Code        = 'missing-main-head'
                        PullRequest = $null
                        Message     = 'The head commit of main is unknown, so the release cannot be cut off.'
                    })))
    }
    else {
        $pullRequests = @($pending['pullRequests'] | Sort-Object -Property { [long]$_['number'] })
        $requestedBy = $null
        if ($requested) {
            $requestedBy = $pending['releaseRequest']['requestedBy']
        }
        $recordEntries = @($pullRequests | ForEach-Object {
                $label = $null
                if ($_['triggersRelease']) {
                    $label = @($_['versionLabels'])[0]
                }
                [ordered]@{
                    number          = $_['number']
                    title           = $_['title']
                    author          = $_['author']
                    kind            = $_['kind']
                    mergedAt        = $_['mergedAt']
                    mergeCommit     = $_['mergeCommit']
                    triggersRelease = $_['triggersRelease']
                    versionLabel    = $label
                    breaking        = $_['breaking']['declared']
                }
            })
        $record = [ordered]@{
            schemaVersion   = (Get-AvmReleasePolicy).SchemaVersion
            repository      = $state['repository']
            version         = $summary.Version
            previousVersion = $summary.BaseVersion
            increment       = $summary.Increment
            commit          = $normalized.MainHead
            cutoffAt        = $normalized.Now
            trigger         = $trigger
            requestedBy     = $requestedBy
            notes           = $summary.Notes
            pullRequests    = $recordEntries
        }
        $recordJson = ConvertTo-AvmReleaseJson -InputObject $record -Kind Record

        $state['publication'] = [ordered]@{
            version         = $summary.Version
            previousVersion = $summary.BaseVersion
            commit          = $normalized.MainHead
            cutoffAt        = $normalized.Now
            trigger         = $trigger
            stage           = 'cutoff'
            pullRequests    = @($recordEntries | ForEach-Object {
                    [ordered]@{
                        number       = $_['number']
                        versionLabel = $_['versionLabel']
                    }
                })
        }
        $state['pending'] = New-AvmReleasePendingState

        $actions.Add([ordered]@{
                Type            = 'StartPublication'
                Version         = $summary.Version
                PreviousVersion = $summary.BaseVersion
                Commit          = $normalized.MainHead
                Trigger         = $trigger
                RecordPath      = "releases/v$($summary.Version).json"
                Record          = $record
                RecordJson      = $recordJson
            })
        $status = 'publishing'
        $summary = Get-AvmReleasePendingSummary -State $state -LatestVersion $normalized.LatestVersion
    }

    $newJson = ConvertTo-AvmReleaseJson -InputObject $state -Kind State
    $finalState = (ConvertFrom-AvmReleaseJson -Json $newJson -Kind State -Repository $normalized.Repository).Document

    return [ordered]@{
        Status    = $status
        Changed   = $newJson -cne $originalJson
        State     = $finalState
        StateJson = $newJson
        Actions   = $actions.ToArray()
        Summary   = $summary
    }
}
