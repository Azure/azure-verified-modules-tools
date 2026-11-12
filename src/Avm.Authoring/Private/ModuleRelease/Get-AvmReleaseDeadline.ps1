function Get-AvmReleaseDeadline {
    <#
    .SYNOPSIS
        Calculate when a pending release becomes due.

    .DESCRIPTION
        Applies the release timing policy to the times at which release-triggering events happened. A release-triggering merge or an accepted opt-in each count as one trigger time.

        The 24-hour timer runs from the latest trigger time, so each new trigger restarts it. The 72-hour cap runs from the earliest trigger time and never restarts. When either timer would end on a Saturday or Sunday (UTC), that timer gets 48 more hours. Only the end instant is checked, and the extension applies once. The release is due at whichever timer ends first. When both end together, the 24-hour timer is reported.

    .PARAMETER TriggerTimes
        The trigger times. Each accepts the inputs of ConvertTo-AvmReleaseTimestamp.

    .EXAMPLE
        Get-AvmReleaseDeadline -TriggerTimes @('2026-09-04T15:00:00Z')

        Returns DueAt '2026-09-07T15:00:00Z', because the 24-hour timer would end on Saturday.

    .OUTPUTS
        Ordered dictionary with FirstTriggerAt, LastTriggerAt, RestartDeadline, CapDeadline, DueAt, and DueBy ('timer' or 'cap'). Timestamps use the canonical UTC form.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $TriggerTimes
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $policy = Get-AvmReleasePolicy
    $instants = @($TriggerTimes | ForEach-Object { ConvertTo-AvmReleaseTimestamp -Value $_ -Name 'Trigger time' })
    if ($instants.Count -eq 0) {
        throw [System.ArgumentException]::new('At least one trigger time is required to calculate a release deadline.')
    }

    $sorted = @($instants | Sort-Object -Property UtcTicks)
    $first = $sorted[0]
    $last = $sorted[-1]

    $restart = $last.Add($policy.RestartTimer)
    if ($restart.DayOfWeek -eq [System.DayOfWeek]::Saturday -or $restart.DayOfWeek -eq [System.DayOfWeek]::Sunday) {
        $restart = $restart.Add($policy.WeekendExtension)
    }

    $cap = $first.Add($policy.CapTimer)
    if ($cap.DayOfWeek -eq [System.DayOfWeek]::Saturday -or $cap.DayOfWeek -eq [System.DayOfWeek]::Sunday) {
        $cap = $cap.Add($policy.WeekendExtension)
    }

    $dueAt = $restart
    $dueBy = 'timer'
    if ($cap -lt $restart) {
        $dueAt = $cap
        $dueBy = 'cap'
    }

    return [ordered]@{
        FirstTriggerAt  = Format-AvmReleaseTimestamp -Value $first
        LastTriggerAt   = Format-AvmReleaseTimestamp -Value $last
        RestartDeadline = Format-AvmReleaseTimestamp -Value $restart
        CapDeadline     = Format-AvmReleaseTimestamp -Value $cap
        DueAt           = Format-AvmReleaseTimestamp -Value $dueAt
        DueBy           = $dueBy
    }
}
