function Find-AvmToolOnPath {
    <#
    .SYNOPSIS
        Locate a managed-tool entrypoint on the user's PATH and (if found)
        report the version it self-identifies as.

    .DESCRIPTION
        Implements step 2 of the spec section 10 lookup order. Looks for the
        tool's entrypoint via Get-Command. If found, runs '<exe> --version',
        scrapes a semver-shaped substring from stdout+stderr, and compares it
        to the lock-pinned version.

        The matcher is intentionally permissive: most managed tools (terraform,
        tflint, conftest, terraform-docs, bicep) print a 'X.Y.Z' or 'vX.Y.Z'
        substring somewhere in their --version output. Tools that don't can
        opt into a custom matcher via the lock schema in a later phase; for
        Phase 0 the default suffices.

    .PARAMETER Entrypoint
        Bare entrypoint name from the lock (no extension, no path). On Windows
        Get-Command resolves '.exe' automatically.

    .PARAMETER ExpectedVersion
        The version pinned in the lock (e.g. '1.9.5' or 'v1.9.5'). Compared
        loosely (a leading 'v' on either side is stripped before equality).

    .OUTPUTS
        $null when the entrypoint is not on PATH. Otherwise a pscustomobject
        with Path, DetectedVersion (or $null when no version could be parsed)
        and Matches ($true when DetectedVersion equals ExpectedVersion).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Entrypoint,
        [Parameter(Mandatory)] [string] $ExpectedVersion
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $cmd = Get-Command -Name $Entrypoint -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $cmd) { return $null }

    $path = $cmd.Source
    if (-not $path) { return $null }

    $detected = $null
    try {
        $proc = Invoke-AvmProcess -FilePath $path -ArgumentList @('--version') -TimeoutSec 10 -IgnoreExitCode
        $combined = "$($proc.StdOut)`n$($proc.StdErr)"
        $rx = [regex]::new('(?<![0-9.])(\d+\.\d+\.\d+(?:[\-+][0-9A-Za-z\.\-]+)?)')
        $m = $rx.Match($combined)
        if ($m.Success) {
            $detected = $m.Groups[1].Value
        }
    }
    catch {
        Write-Verbose "Find-AvmToolOnPath: '$path --version' failed: $($_.Exception.Message)"
    }

    $versionMatches = $false
    if ($detected) {
        $expectedNorm = $ExpectedVersion.TrimStart('v', 'V')
        $detectedNorm = $detected.TrimStart('v', 'V')
        $versionMatches = ($expectedNorm -ceq $detectedNorm)
    }

    [pscustomobject][ordered]@{
        Path            = $path
        DetectedVersion = $detected
        Matches         = $versionMatches
    }
}
