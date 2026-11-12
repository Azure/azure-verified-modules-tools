function Resolve-AvmReleaseCommand {
    <#
    .SYNOPSIS
        Apply one release-issue comment to the release state.

    .DESCRIPTION
        Updates the State dictionary in place and writes an AcknowledgeCommand action to the pipeline for every command found. Comments by bots and comments without a command produce nothing.

        - Only module owners, members of an owner team, and the core AVM team can use commands.
        - #Release requests publication now and clears any hold. With nothing pending, it only clears a hold. A request during a central freeze, or while an earlier version is still publishing, is recorded and waits.
        - #DoNotRelease places or updates a hold and cancels any release request. A hold keeps the time it was first placed. After the cutoff, it cannot stop the version already being published. It applies to changes that are still pending.
        - #ReleaseNotes replaces the maintainer commentary or the 'Breaking changes' text of the pending release. It is rejected after the cutoff, because the notes are frozen at publication.

    .PARAMETER State
        The release state. This function changes it in place.

    .PARAMETER Comment
        A normalised comment from ConvertTo-AvmReleaseFacts.

    .PARAMETER Facts
        The normalised facts from ConvertTo-AvmReleaseFacts.

    .EXAMPLE
        Resolve-AvmReleaseCommand -State $state -Comment $facts.Comments[0] -Facts $facts

        Applies the command and returns its acknowledgement.

    .OUTPUTS
        Ordered dictionaries, one for each action.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Comment,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Facts
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $author = $Comment['Author']
    if ($author -match '\[bot\]$') {
        return
    }
    $command = ConvertFrom-AvmReleaseCommand -Body $Comment['Body']
    if ($null -eq $command) {
        return
    }

    $acknowledge = {
        param([bool] $Accepted, [string] $Reason, [string] $Message, [string] $Detail)
        $nullable = {
            param([string] $Value)
            if ([string]::IsNullOrEmpty($Value)) {
                return $null
            }
            return $Value
        }
        return [ordered]@{
            Type      = 'AcknowledgeCommand'
            CommentId = $Comment['Id']
            Command   = $command.Name
            Actor     = $author
            Accepted  = $Accepted
            Reason    = & $nullable -Value $Reason
            Detail    = & $nullable -Value $Detail
            Message   = $Message
        }
    }

    $access = $Facts['Authorization']
    $authorization = Test-AvmReleaseActorAuthorized -Actor $author -Owners $access['Owners'] -ActorTeams $access['ActorTeams'][[string]$author] -CoreTeam $access['CoreTeam']
    if (-not $authorization.Authorized) {
        return & $acknowledge -Accepted $false -Reason 'not-authorized' -Message "Only module owners and the core AVM team can use #$($command.Name)."
    }
    if ($null -ne $command.Error) {
        return & $acknowledge -Accepted $false -Reason $command.Error -Message 'Add a reason after #DoNotRelease, for example: #DoNotRelease waiting for the provider fix.'
    }

    $pending = $State['pending']
    $publication = $State['publication']
    $triggering = @($pending['pullRequests'] | Where-Object { $_['triggersRelease'] })
    $postedAt = $Comment['CreatedAt']

    switch ($command.Name) {
        'Release' {
            $hadHold = $null -ne $State['hold']
            $State['hold'] = $null
            if ($triggering.Count -eq 0) {
                if ($hadHold) {
                    return & $acknowledge -Accepted $true -Message 'The hold is cleared. No changes are waiting to be released.'
                }
                return & $acknowledge -Accepted $false -Reason 'nothing-to-release' -Message 'No changes are waiting to be released.'
            }

            $parts = [System.Collections.Generic.List[string]]::new()
            if ($hadHold) {
                $parts.Add('The hold is cleared.')
            }
            if ($null -ne $pending['releaseRequest']) {
                $parts.Add('A release was already requested.')
            }
            else {
                $pending['releaseRequest'] = [ordered]@{
                    requestedBy = $author
                    requestedAt = $postedAt
                    commentId   = $Comment['Id']
                }
                $parts.Add('Release requested.')
            }
            if ($Facts['Freeze'] -eq 'active') {
                $parts.Add('A central release freeze is in effect, so publication waits until it ends.')
            }
            elseif ($Facts['Freeze'] -ne 'none') {
                $parts.Add('The central release freeze could not be checked, so publication waits until it can.')
            }
            elseif ($null -ne $publication) {
                $parts.Add("Publication starts after v$($publication['version']) finishes publishing.")
            }
            else {
                $parts.Add('Publication starts now.')
            }
            return & $acknowledge -Accepted $true -Message ($parts -join ' ')
        }
        'DoNotRelease' {
            if ($null -eq $State['hold']) {
                $State['hold'] = [ordered]@{
                    reason    = $command.Reason
                    placedBy  = $author
                    placedAt  = $postedAt
                    since     = $postedAt
                    commentId = $Comment['Id']
                }
            }
            else {
                $State['hold']['reason'] = $command.Reason
                $State['hold']['placedBy'] = $author
                $State['hold']['placedAt'] = $postedAt
                $State['hold']['commentId'] = $Comment['Id']
            }
            $pending['releaseRequest'] = $null
            $message = 'Hold placed. Nothing publishes automatically until someone posts #Release.'
            if ($null -ne $publication) {
                $message = "v$($publication['version']) was cut off before this hold, so it still publishes. The hold applies to changes that are still pending."
            }
            return & $acknowledge -Accepted $true -Message $message
        }
        'ReleaseNotes' {
            if ($null -ne $publication) {
                return & $acknowledge -Accepted $false -Reason 'notes-frozen' -Message "The notes for v$($publication['version']) were frozen at the publication cutoff. Post notes for later changes on the next release issue."
            }
            if ($triggering.Count -eq 0) {
                return & $acknowledge -Accepted $false -Reason 'no-pending-release' -Message 'No release is pending, so there are no release notes to edit.'
            }

            $summary = Get-AvmReleasePendingSummary -State $State -LatestVersion $Facts['LatestVersion']
            $currentCommentary = $null
            if ($null -ne $pending['notes']['commentary']) {
                $currentCommentary = $pending['notes']['commentary']['text']
            }
            $edit = Get-AvmReleaseNotesEdit -Markdown $command.Markdown -CurrentCommentary $currentCommentary -CurrentBreakingText $summary.BreakingText -DeclaredBreakingPullRequests ([int[]]$summary.DeclaredBreakingPullRequests)
            if (-not $edit.Accepted) {
                return & $acknowledge -Accepted $false -Reason 'invalid-notes' -Detail $edit.Error -Message $edit.Message
            }
            if ($edit.CommentaryChanged) {
                $pending['notes']['commentary'] = $null
                if ($null -ne $edit.Commentary) {
                    $pending['notes']['commentary'] = [ordered]@{
                        text  = $edit.Commentary
                        setBy = $author
                        setAt = $postedAt
                    }
                }
            }
            if ($edit.BreakingChanged) {
                $pending['notes']['breakingOverride'] = [ordered]@{
                    text                = $edit.BreakingOverride
                    coveredPullRequests = @($edit.CoveredPullRequests | ForEach-Object { [long]$_ })
                    setBy               = $author
                    setAt               = $postedAt
                }
            }
            return & $acknowledge -Accepted $true -Message 'Release notes updated.'
        }
    }
}
