function Get-AvmReleasePendingSummary {
    <#
    .SYNOPSIS
        Summarise the pending release in a release state.

    .DESCRIPTION
        Calculates everything the release issue shows and the decision engine needs for the pending release:

        - The base version. This is the version being published when a publication is in progress, otherwise the latest published version.
        - The proposed version from the release-triggering pull requests.
        - The timers from each pull request's trigger time.
        - The release-notes preview, including late breaking pull requests appended below an override.
        - The issues that block publication. These are version-label problems and incomplete breaking-change details that no override covers.
        - The flags to show on individual pull requests. These are the blocking issues, late breaking changes, and repo-sync pull requests that changed module code beyond formatting.

        It does not change the state.

    .PARAMETER State
        A valid release state.

    .PARAMETER LatestVersion
        The latest published version without a 'v' prefix, or null when none is known.

    .EXAMPLE
        Get-AvmReleasePendingSummary -State $state -LatestVersion '0.8.2'

        Returns the proposed version, timers, notes, blocking issues, and flags.

    .OUTPUTS
        Ordered dictionary.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $LatestVersion
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $pending = $State['pending']
    $publication = $State['publication']
    $pullRequests = @($pending['pullRequests'] | Sort-Object -Property { [long]$_['number'] })
    $triggering = @($pullRequests | Where-Object { $_['triggersRelease'] })

    $baseVersion = $LatestVersion
    if ($null -ne $publication) {
        $baseVersion = $publication['version']
    }
    if ([string]::IsNullOrWhiteSpace($baseVersion)) {
        $baseVersion = $null
    }

    $issues = [System.Collections.Generic.List[object]]::new()
    $plan = $null
    $deadline = $null
    if ($triggering.Count -gt 0) {
        $planInput = @($triggering | ForEach-Object {
                [ordered]@{
                    Number = $_['number']
                    Labels = @($_['versionLabels'])
                }
            })
        $plan = Get-AvmReleaseVersionPlan -CurrentVersion $baseVersion -PullRequests $planInput
        foreach ($issue in @($plan.Issues)) {
            $issues.Add([ordered]@{
                    Code        = $issue.Code
                    PullRequest = $issue.PullRequest
                    Message     = $issue.Message
                })
        }
        $deadline = Get-AvmReleaseDeadline -TriggerTimes @($triggering | ForEach-Object { $_['triggeredAt'] })
    }

    $override = $pending['notes']['breakingOverride']
    $covered = @()
    $overrideInput = $null
    if ($null -ne $override) {
        $covered = @($override['coveredPullRequests'] | ForEach-Object { [long]$_ })
        $overrideInput = [ordered]@{
            Text                = $override['text']
            CoveredPullRequests = $covered
        }
    }

    $declared = @($pullRequests | Where-Object { $_['breaking']['declared'] })
    foreach ($pullRequest in $declared) {
        $codes = @($pullRequest['breaking']['issues'])
        if ($codes.Count -gt 0 -and $covered -notcontains [long]$pullRequest['number']) {
            $issues.Add([ordered]@{
                    Code        = 'breaking-details-invalid'
                    PullRequest = $pullRequest['number']
                    Message     = "Pull request #$($pullRequest['number']) declares a breaking change, but its details are incomplete ($($codes -join ', ')). Post a #ReleaseNotes comment whose 'Breaking changes' section covers #$($pullRequest['number'])."
                })
        }
    }

    $commentary = $null
    if ($null -ne $pending['notes']['commentary']) {
        $commentary = $pending['notes']['commentary']['text']
    }
    $version = $null
    $increment = $null
    if ($null -ne $plan) {
        $version = $plan.Version
        $increment = $plan.Increment
    }
    $breakingEntries = @($declared | ForEach-Object {
            [ordered]@{
                Number          = $_['number']
                WhatChanges     = $_['breaking']['whatChanges']
                RequiredUpgrade = $_['breaking']['requiredUpgrade']
            }
        })
    $changes = @($triggering | ForEach-Object {
            [ordered]@{
                Number = $_['number']
                Title  = $_['title']
            }
        })
    $notes = Format-AvmReleaseNotes -BreakingEntries $breakingEntries -BreakingOverride $overrideInput -Commentary $commentary -Changes $changes -Repository $State['repository'] -PreviousVersion $baseVersion -Version $version
    $late = @($notes.LateBreakingPullRequests | ForEach-Object { [long]$_ })

    $flags = [System.Collections.Generic.List[object]]::new()
    foreach ($pullRequest in $pullRequests) {
        $number = [long]$pullRequest['number']
        foreach ($issue in $issues) {
            if ($null -ne $issue.PullRequest -and [long]$issue.PullRequest -eq $number) {
                $flags.Add([ordered]@{
                        PullRequest = $number
                        Code        = $issue.Code
                        Blocking    = $true
                        Message     = $issue.Message
                    })
            }
        }
        if ($pullRequest['kind'] -eq 'Automation' -and -not $pullRequest['triggersRelease'] -and $pullRequest['moduleCodeChanged'] -and -not $pullRequest['formattingOnly']) {
            $flags.Add([ordered]@{
                    PullRequest = $number
                    Code        = 'automation-module-code'
                    Blocking    = $false
                    Message     = "Repo-sync pull request #$number changed module code beyond formatting. It does not trigger a release and ships with the next one. A module owner can opt it in with a version label."
                })
        }
        if ($late -contains $number) {
            $flags.Add([ordered]@{
                    PullRequest = $number
                    Code        = 'late-breaking-change'
                    Blocking    = $false
                    Message     = "Pull request #$number declared a breaking change after the 'Breaking changes' text was overridden. Its entry is listed below the override."
                })
        }
    }

    $field = {
        param([string] $Name)
        if ($null -eq $deadline) {
            return $null
        }
        return $deadline[$Name]
    }

    return [ordered]@{
        BaseVersion                  = $baseVersion
        Version                      = $version
        Increment                    = $increment
        PendingPullRequests          = [long[]]@($pullRequests | ForEach-Object { $_['number'] })
        TriggeringPullRequests       = [long[]]@($triggering | ForEach-Object { $_['number'] })
        FirstTriggerAt               = & $field -Name 'FirstTriggerAt'
        LastTriggerAt                = & $field -Name 'LastTriggerAt'
        RestartDeadline              = & $field -Name 'RestartDeadline'
        CapDeadline                  = & $field -Name 'CapDeadline'
        DueAt                        = & $field -Name 'DueAt'
        DueBy                        = & $field -Name 'DueBy'
        DeclaredBreakingPullRequests = [long[]]@($declared | ForEach-Object { $_['number'] })
        BreakingText                 = $notes.BreakingText
        Notes                        = $notes.Markdown
        LateBreakingPullRequests     = [long[]]$late
        BlockingIssues               = $issues.ToArray()
        Flags                        = $flags.ToArray()
    }
}
