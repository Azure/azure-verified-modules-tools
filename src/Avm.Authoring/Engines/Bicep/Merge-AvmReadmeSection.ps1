function Merge-AvmReadmeSection {
    <#
    .SYNOPSIS
        Replace (or append) a markdown section's body in a README, keyed
        by an exact-match level-2 heading line.

    .DESCRIPTION
        Internal helper used by the Bicep docs engine to keep README
        sections in sync with regenerated content. The heading is
        matched on the trimmed line, exactly. The section body runs
        from the line after the heading up to (but not including) the
        next heading whose line matches NextHeadingPattern (default
        '^## '), or to end-of-file if no following heading exists.

        Behavior:
          - If the heading is present: the existing body is replaced
            with NewBody. A single blank line is preserved between the
            heading and the new body, and between the new body and the
            next heading (if any).
          - If the heading is absent: the heading and body are appended
            at end-of-file, separated from the preceding content by a
            single blank line.

        Trailing blank lines inside NewBody are stripped so consecutive
        runs are idempotent.

    .PARAMETER Content
        Existing README content as an array of lines. Empty or $null is
        treated as an empty document.

    .PARAMETER Heading
        Full heading line including the leading hashes, e.g. '## Outputs'.
        Matched against trimmed line content.

    .PARAMETER NewBody
        New body lines for the section. Must NOT include the heading
        itself. Pass @() to clear the section to empty.

    .PARAMETER NextHeadingPattern
        Regex used to find the end of the current section. Defaults to
        '^## ' so any same- or higher-level heading terminates the run.

    .OUTPUTS
        [string[]] - the new README content.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Content,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Heading,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $NewBody,

        [string] $NextHeadingPattern = '^##\s'
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $lines = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $Content) {
        foreach ($l in $Content) { $lines.Add([string]$l) }
    }

    $body = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $NewBody) {
        foreach ($l in $NewBody) { $body.Add([string]$l) }
    }
    while ($body.Count -gt 0 -and [string]::IsNullOrWhiteSpace($body[$body.Count - 1])) {
        $body.RemoveAt($body.Count - 1)
    }

    $headingTrim = $Heading.Trim()

    $headingIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq $headingTrim) {
            $headingIndex = $i
            break
        }
    }

    $out = [System.Collections.Generic.List[string]]::new()

    if ($headingIndex -lt 0) {
        if ($lines.Count -gt 0) {
            foreach ($l in $lines) { $out.Add($l) }
            while ($out.Count -gt 0 -and [string]::IsNullOrWhiteSpace($out[$out.Count - 1])) {
                $out.RemoveAt($out.Count - 1)
            }
            $out.Add('')
        }
        $out.Add($Heading)
        $out.Add('')
        foreach ($l in $body) { $out.Add($l) }
        return , $out.ToArray()
    }

    $nextHeadingIndex = $lines.Count
    for ($i = $headingIndex + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $NextHeadingPattern) {
            $nextHeadingIndex = $i
            break
        }
    }

    for ($i = 0; $i -le $headingIndex; $i++) { $out.Add($lines[$i]) }
    $out.Add('')
    foreach ($l in $body) { $out.Add($l) }

    if ($nextHeadingIndex -lt $lines.Count) {
        $out.Add('')
        for ($i = $nextHeadingIndex; $i -lt $lines.Count; $i++) {
            $out.Add($lines[$i])
        }
    }

    return , $out.ToArray()
}
