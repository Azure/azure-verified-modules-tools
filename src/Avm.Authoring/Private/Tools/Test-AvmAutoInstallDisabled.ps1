function Test-AvmAutoInstallDisabled {
    <#
    .SYNOPSIS
        Report whether transparent tool auto-install is disabled.

    .DESCRIPTION
        Auto-install is on by default. It is disabled when the caller passes
        -Explicit (surfaced as -NoAutoInstall on the resolver) or when the
        AVM_NO_AUTO_INSTALL environment variable is set to a truthy value
        ('1', 'true', 'yes', 'on', case-insensitive). Any other value, or an
        empty / whitespace value, leaves auto-install enabled.

        Both Resolve-AvmTool (which performs the install) and Get-AvmTool
        (which reports what `avm tool list` will do) call this so they never
        disagree about whether a missing tool will be installed on demand.

    .PARAMETER Explicit
        A caller-supplied switch (for example Resolve-AvmTool -NoAutoInstall)
        that forces auto-install off regardless of the environment.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [switch] $Explicit
    )

    Set-StrictMode -Version 3.0

    if ($Explicit) { return $true }

    $flag = $env:AVM_NO_AUTO_INSTALL
    if ([string]::IsNullOrWhiteSpace($flag)) { return $false }

    return @('1', 'true', 'yes', 'on') -contains $flag.Trim().ToLowerInvariant()
}
