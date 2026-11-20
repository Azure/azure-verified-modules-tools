function Resolve-AvmReleaseLabelEvent {
    <#
    .SYNOPSIS
        Apply one post-merge version-label change to the release state.

    .DESCRIPTION
        Updates the State dictionary in place and writes any resulting actions to the pipeline.

        - A change to a label that is not a version label is ignored silently.
        - A change by a bot or by someone who is not authorised is ignored and reported with IgnoreLabelChange.
        - A change on a pull request that is not pending is ignored and reported. An opt-in for already-published changes never creates another release.
        - A change on a pull request in the release being published is reported with ReportLabelMismatch. It never rewrites the release record.
        - A change at or before the merge is already part of the labels at merge, so it is ignored silently.
        - Otherwise the label change is recorded and the version is recalculated later. The first authorised label added to a bot pull request that does not trigger a release is an opt-in. The opt-in counts as a merge at the time of the label change and is reported with AcceptOptIn.

    .PARAMETER State
        The release state. This function changes it in place.

    .PARAMETER LabelEvent
        A normalised label event from ConvertTo-AvmReleaseFacts.

    .PARAMETER Authorization
        The Authorization entry from ConvertTo-AvmReleaseFacts.

    .EXAMPLE
        Resolve-AvmReleaseLabelEvent -State $state -LabelEvent $facts.LabelEvents[0] -Authorization $facts.Authorization

        Applies the label change and returns its actions.

    .OUTPUTS
        Ordered dictionaries, one for each action.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $LabelEvent,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Authorization
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $policy = Get-AvmReleasePolicy
    $label = $LabelEvent['Label']
    if (@($policy.VersionLabels) -cnotcontains $label) {
        return
    }

    $number = $LabelEvent['PullRequest']
    $record = $null
    foreach ($pullRequest in @($State['pending']['pullRequests'])) {
        if ($pullRequest['number'] -eq $number) {
            $record = $pullRequest
            break
        }
    }
    $published = $null
    if ($null -eq $record -and $null -ne $State['publication']) {
        foreach ($entry in @($State['publication']['pullRequests'])) {
            if ($entry['number'] -eq $number) {
                $published = $entry
                break
            }
        }
    }

    $action = [ordered]@{
        Type        = $null
        PullRequest = $number
        Label       = $label
        Action      = $LabelEvent['Action']
        Actor       = $LabelEvent['Actor']
        Reason      = $null
        Message     = $null
    }

    if ($null -eq $record -and $null -eq $published) {
        $action.Type = 'IgnoreLabelChange'
        $action.Reason = 'not-pending'
        $action.Message = "Pull request #$number is not part of a pending release. A label change cannot release changes that were already published."
        return $action
    }

    $actor = [string]$LabelEvent['Actor']
    $authorization = Test-AvmReleaseActorAuthorized -Actor $actor -Owners $Authorization['Owners'] -ActorTeams $Authorization['ActorTeams'][$actor] -CoreTeam $Authorization['CoreTeam']
    if (-not $authorization.Authorized) {
        $action.Type = 'IgnoreLabelChange'
        $action.Reason = $authorization.Reason
        $action.Message = 'Only module owners and the core AVM team can change version labels after merge.'
        if ($authorization.Reason -eq 'bot') {
            $action.Message = 'A version-label change by automation is ignored.'
        }
        return $action
    }

    if ($null -ne $published) {
        $action.Type = 'ReportLabelMismatch'
        $action.Reason = 'after-cutoff'
        $action.Message = "Pull request #$number is in v$($State['publication']['version']), which was cut off with the '$($published['versionLabel'])' label. Label changes after the cutoff do not change that release."
        $action['Version'] = $State['publication']['version']
        $action['RecordedLabel'] = $published['versionLabel']
        return $action
    }

    if ([string]::CompareOrdinal($LabelEvent['At'], $record['mergedAt']) -le 0) {
        return
    }

    $labels = [System.Collections.Generic.List[string]]::new()
    foreach ($existing in @($record['versionLabels'])) {
        $labels.Add($existing)
    }
    if ($LabelEvent['Action'] -eq 'labeled' -and -not $labels.Contains($label)) {
        $labels.Add($label)
    }
    elseif ($LabelEvent['Action'] -eq 'unlabeled') {
        $null = $labels.Remove($label)
    }
    $record['versionLabels'] = @($policy.VersionLabels | Where-Object { $labels.Contains($_) })
    $record['labelChanges'] = @($record['labelChanges']) + @([ordered]@{
            label  = $label
            action = $LabelEvent['Action']
            actor  = $LabelEvent['Actor']
            at     = $LabelEvent['At']
        })

    if (-not $record['triggersRelease'] -and $LabelEvent['Action'] -eq 'labeled') {
        $record['triggersRelease'] = $true
        $record['triggeredAt'] = $LabelEvent['At']
        $record['triggeredBy'] = 'opt-in'
        $record['optIn'] = [ordered]@{
            by = $LabelEvent['Actor']
            at = $LabelEvent['At']
        }
        $action.Type = 'AcceptOptIn'
        $action.Message = "Pull request #$number joins the pending release. The opt-in counts as a merge at $($LabelEvent['At'])."
        return $action
    }
}
