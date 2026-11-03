function Get-AvmReleasePolicy {
    <#
    .SYNOPSIS
        Return the fixed rules that drive the Terraform release engine.

    .DESCRIPTION
        Returns a new hashtable of release-engine constants. It holds the version labels, timer durations, command names, pull request body markers, release-notes headings, routine bot identities, the repo-sync identity, the default core AVM team, and the state schema version. RequireBreakingCheckbox controls whether the release-metadata check fails a human-authored pull request whose description has no breaking-changes checkbox line. Bot pull requests never need the line. Each call returns a fresh copy, so callers can change it without affecting later calls.

    .EXAMPLE
        (Get-AvmReleasePolicy).RestartTimer

        Returns the 24-hour restart timer as a TimeSpan.

    .OUTPUTS
        Hashtable.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    return @{
        SchemaVersion           = 1
        VersionLabels           = @('patch', 'minor', 'major')
        RestartTimer            = [timespan]::FromHours(24)
        CapTimer                = [timespan]::FromHours(72)
        WeekendExtension        = [timespan]::FromHours(48)
        Commands                = @('Release', 'DoNotRelease', 'ReleaseNotes')
        RoutineBots             = @('dependabot[bot]', 'azure-verified-modules[bot]')
        AutomationAuthor        = 'azure-verified-modules[bot]'
        AutomationTitlePrefix   = 'chore: run avm pre-commit'
        CoreTeam                = 'Azure/azure-verified-modules-engineering-owners'
        BreakingCheckbox        = 'Breaking changes'
        RequireBreakingCheckbox = $true
        WhatChangesHeading      = 'What changes'
        RequiredUpgradeHeading  = 'Required upgrade'
        BodyPlaceholders        = @(
            'Describe what breaks for consumers.'
            'Describe what consumers must change.'
        )
        BreakingHeading         = 'Breaking changes'
        CommentaryHeading       = 'Notes from maintainers'
        ChangesHeading          = "What's changed"
        CommentaryPlaceholder   = 'Replace this line with a short summary for users.'
        MissingDetail           = '_Not provided._'
        PublicationStages       = @('cutoff')
        PublicationTriggers     = @('timer', 'cap', 'release-command')
        PullRequestKinds        = @('Human', 'RoutineBot', 'Automation')
    }
}
