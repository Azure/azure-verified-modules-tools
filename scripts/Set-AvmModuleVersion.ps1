[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string] $ManifestPath,

    [Parameter(Mandatory = $true, Position = 1)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string] $Version,

    [Parameter()]
    [AllowEmptyString()]
    [string] $ReleaseNotes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Anchored on the assignments themselves so a version-like or notes-like string
# elsewhere in the manifest (a URI, the Description) can never be rewritten.
# The ReleaseNotes alternation accepts a here-string so re-stamping an already
# stamped manifest stays idempotent.
$versionPattern = @'
(?m)^(?<pre>[ \t]*ModuleVersion[ \t]*=[ \t]*)(?<q>['"])[^'"]*\k<q>
'@
$notesPattern = @'
(?ms)^(?<pre>[ \t]*ReleaseNotes[ \t]*=[ \t]*)(?:@'\r?\n.*?\r?\n'@|'(?:[^']|'')*'|"(?:[^"]|"")*")
'@

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "Manifest not found at $ManifestPath."
}

$resolved = (Resolve-Path -LiteralPath $ManifestPath).Path
$original = [System.IO.File]::ReadAllText($resolved)

if ($original -notmatch $versionPattern) {
    throw "No 'ModuleVersion = <quoted value>' assignment found in $resolved. The manifest layout changed; update Set-AvmModuleVersion.ps1."
}

# MatchEvaluator rather than the -replace operator: the replacement carries
# user-supplied CHANGELOG prose and must never be parsed for $-substitutions.
$stampVersion = [System.Text.RegularExpressions.MatchEvaluator] {
    param($stampMatch)
    $stampMatch.Groups['pre'].Value + "'" + $Version + "'"
}
$updated = [regex]::Replace($original, $versionPattern, $stampVersion)

if ($PSBoundParameters.ContainsKey('ReleaseNotes') -and -not [string]::IsNullOrWhiteSpace($ReleaseNotes)) {
    if ($updated -notmatch $notesPattern) {
        throw "No 'ReleaseNotes = <quoted value>' assignment found in $resolved. The manifest layout changed; update Set-AvmModuleVersion.ps1."
    }

    # A literal here-string keeps markdown verbatim for the gallery listing: no
    # escaping, no interpolation. Its terminator must sit in column 0, so the
    # notes body cannot contain a line that starts with the terminator itself.
    $notesBody = ($ReleaseNotes -replace "`r`n", "`n").Trim()
    if ($notesBody -match "(?m)^'@") {
        throw "Release notes contain a line beginning with the here-string terminator, which would truncate the manifest. Reword the CHANGELOG entry."
    }

    $stampNotes = [System.Text.RegularExpressions.MatchEvaluator] {
        param($notesMatch)
        $notesMatch.Groups['pre'].Value + "@'`n" + $notesBody + "`n'@"
    }
    $updated = [regex]::Replace($updated, $notesPattern, $stampNotes)
}

if ($updated -ceq $original) {
    Write-Verbose "Manifest $resolved is already stamped at version $Version; nothing to write."
    return
}

if ($PSCmdlet.ShouldProcess($resolved, "Stamp ModuleVersion $Version")) {
    # UTF-8 without BOM and LF only, matching the repo-wide encoding contract
    # enforced by tests/Pester/Unit/Module/Encoding.Tests.ps1.
    [System.IO.File]::WriteAllText(
        $resolved,
        ($updated -replace "`r`n", "`n"),
        (New-Object System.Text.UTF8Encoding $false))
    Write-Verbose "Stamped ModuleVersion $Version into $resolved."
}
