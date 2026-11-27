function ConvertTo-AvmReleasePullRequestRecord {
    <#
    .SYNOPSIS
        Turn a newly merged pull request into a pending-release record.

    .DESCRIPTION
        Classifies the pull request, reads its breaking-change details, and decides whether its merge triggers a release.

        - Human-authored: triggers at merge. The version labels present at merge are kept as-is, because the release-metadata check enforces them before merge.
        - Routine bot or repo-sync with an authorised version label at merge: an opt-in. It triggers at merge and records who added the label and when. A label added by a bot or by someone who is not authorised is ignored and reported.
        - Routine bot that changes module code beyond formatting without an opt-in: should not merge. If it does, it triggers at merge with no version label, which blocks publication until a maintainer adds one.
        - Repo-sync without an opt-in: never triggers a release. It rides along with the next one. The engine flags it later when it changes module code beyond formatting.
        - Any other routine bot pull request: rides along without triggering.

    .PARAMETER PullRequest
        A normalised merged pull request from ConvertTo-AvmReleaseFacts.

    .PARAMETER Authorization
        The Authorization entry from ConvertTo-AvmReleaseFacts.

    .EXAMPLE
        ConvertTo-AvmReleasePullRequestRecord -PullRequest $facts.MergedPullRequests[0] -Authorization $facts.Authorization

        Returns the state record and any IgnoreLabelChange actions.

    .OUTPUTS
        Ordered dictionary with Record and Actions.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $PullRequest,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Authorization
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $policy = Get-AvmReleasePolicy
    $class = Get-AvmReleasePullRequestClass -Author $PullRequest['Author'] -Title $PullRequest['Title'] -ChangedFiles $PullRequest['ChangedFiles']
    $body = Test-AvmReleasePullRequestBody -Body $PullRequest['Body']
    $mergedAt = $PullRequest['MergedAt']
    $actions = [System.Collections.Generic.List[object]]::new()
    $accepted = [System.Collections.Generic.List[string]]::new()
    $optIn = $null

    $labelsAtMerge = @($PullRequest['Labels'] | Where-Object { $_['IsVersion'] } | Sort-Object -Property { if ($null -eq $_['AddedAt']) { $mergedAt } else { $_['AddedAt'] } })
    if ($class.Kind -eq 'Human') {
        foreach ($label in $labelsAtMerge) {
            $accepted.Add($label['Name'])
        }
    }
    else {
        foreach ($label in $labelsAtMerge) {
            $addedBy = [string]$label['AddedBy']
            $authorization = Test-AvmReleaseActorAuthorized -Actor $addedBy -Owners $Authorization['Owners'] -ActorTeams $Authorization['ActorTeams'][$addedBy] -CoreTeam $Authorization['CoreTeam']
            if (-not $authorization.Authorized) {
                $message = 'Only module owners and the core AVM team can opt in a bot pull request.'
                if ($authorization.Reason -eq 'bot') {
                    $message = 'A version label added by automation is not an opt-in.'
                }
                $actions.Add([ordered]@{
                        Type        = 'IgnoreLabelChange'
                        PullRequest = $PullRequest['Number']
                        Label       = $label['Name']
                        Action      = 'labeled'
                        Actor       = $label['AddedBy']
                        Reason      = $authorization.Reason
                        Message     = $message
                    })
                continue
            }
            $accepted.Add($label['Name'])
            if ($null -eq $optIn) {
                $at = $label['AddedAt']
                if ($null -eq $at) {
                    $at = $mergedAt
                }
                $optIn = [ordered]@{
                    by = $label['AddedBy']
                    at = $at
                }
            }
        }
    }

    $triggersRelease = $false
    $triggeredBy = $null
    if ($class.Kind -eq 'Human') {
        $triggersRelease = $true
        $triggeredBy = 'merge'
    }
    elseif ($null -ne $optIn) {
        $triggersRelease = $true
        $triggeredBy = 'opt-in'
    }
    elseif ($class.RequiresVersionLabel) {
        $triggersRelease = $true
        $triggeredBy = 'merge'
    }

    $triggeredAt = $null
    if ($triggersRelease) {
        $triggeredAt = $mergedAt
    }

    $labels = @($policy.VersionLabels | Where-Object { $accepted -contains $_ })
    $issues = @($body.Issues | ForEach-Object { [string]$_.Code })

    $record = [ordered]@{
        number            = $PullRequest['Number']
        title             = $PullRequest['Title']
        author            = $PullRequest['Author']
        kind              = $class.Kind
        mergedAt          = $mergedAt
        mergeCommit       = $PullRequest['MergeCommit']
        triggersRelease   = $triggersRelease
        triggeredAt       = $triggeredAt
        triggeredBy       = $triggeredBy
        optIn             = $optIn
        versionLabels     = $labels
        labelChanges      = @()
        breaking          = [ordered]@{
            declared        = [bool]$body.BreakingChange
            whatChanges     = $body.WhatChanges
            requiredUpgrade = $body.RequiredUpgrade
            issues          = $issues
        }
        moduleCodeChanged = [bool]$class.ModuleCodeChanged
        formattingOnly    = [bool]$class.FormattingOnly
        flags             = @()
    }

    return [ordered]@{
        Record  = $record
        Actions = $actions.ToArray()
    }
}
