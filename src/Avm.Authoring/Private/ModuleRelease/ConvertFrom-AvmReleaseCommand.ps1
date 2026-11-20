function ConvertFrom-AvmReleaseCommand {
    <#
    .SYNOPSIS
        Read a release command from the first non-empty line of a release issue comment.

    .DESCRIPTION
        Recognises #Release, #DoNotRelease, and #ReleaseNotes. Only the first non-empty line can hold a command, and command names are case-insensitive. A first line that is quoted (starts with '>'), is indented code (a tab or four or more spaces), or starts a code span or fence (a backtick or '~~~') is never a command. Unknown '#' words, such as issue references, are not commands.

        #DoNotRelease takes its reason from the rest of the first line, or from the remaining comment text when the first line has none. A missing reason is reported in Error, so the caller can reject the command. #ReleaseNotes takes the rest of the first line and every following line as Markdown.

    .PARAMETER Body
        The comment body.

    .EXAMPLE
        ConvertFrom-AvmReleaseCommand -Body '#donotrelease waiting for a provider fix'

        Returns Name 'DoNotRelease' and Reason 'waiting for a provider fix'.

    .OUTPUTS
        Null when the comment holds no command. Otherwise an ordered dictionary with Name, Reason, Markdown, and Error.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Body
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($Body)) {
        return $null
    }

    $policy = Get-AvmReleasePolicy
    $lines = @(($Body -replace "`r`n?", "`n") -split "`n")
    $index = 0
    while ($index -lt $lines.Count -and [string]::IsNullOrWhiteSpace($lines[$index])) {
        $index++
    }
    if ($index -ge $lines.Count) {
        return $null
    }

    $line = $lines[$index]
    if ($line -match '^(\t| {4,})') {
        return $null
    }
    $trimmed = $line.Trim()
    if ($trimmed.StartsWith('>') -or $trimmed.StartsWith('`') -or $trimmed.StartsWith('~~~')) {
        return $null
    }

    $match = [regex]::Match($trimmed, '^#(?<name>[A-Za-z]+)(?:\s+(?<rest>.*))?$')
    if (-not $match.Success) {
        return $null
    }
    $name = @($policy.Commands | Where-Object { $_ -eq $match.Groups['name'].Value })
    if ($name.Count -eq 0) {
        return $null
    }

    $rest = $match.Groups['rest'].Value.Trim()
    $remaining = ''
    if ($index + 1 -lt $lines.Count) {
        $remaining = $lines[($index + 1)..($lines.Count - 1)] -join "`n"
    }

    $command = [ordered]@{
        Name     = $name[0]
        Reason   = $null
        Markdown = $null
        Error    = $null
    }

    switch ($command.Name) {
        'DoNotRelease' {
            $reason = $rest
            if ($reason.Length -eq 0) {
                $reason = ConvertTo-AvmReleaseNormalizedText -Text $remaining
            }
            if ($reason.Length -eq 0) {
                $command.Error = 'missing-reason'
            }
            else {
                $command.Reason = $reason
            }
        }
        'ReleaseNotes' {
            $command.Markdown = ConvertTo-AvmReleaseNormalizedText -Text (@($rest, $remaining) -join "`n")
        }
    }

    return $command
}
