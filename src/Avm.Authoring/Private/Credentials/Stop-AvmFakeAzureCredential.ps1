function Stop-AvmFakeAzureCredential {
    <#
    .SYNOPSIS
        Stop a synthetic Azure token endpoint and release its resources.

    .DESCRIPTION
        Stops the loopback listener started by Start-AvmFakeAzureCredential,
        which is what unblocks the worker's accept loop, then disposes the
        worker and its runspace.

        Every step is best-effort: this runs from a finally block, so a
        failure here must never mask the policy failure that is already on
        its way to the caller.

    .PARAMETER Credential
        The object returned by Start-AvmFakeAzureCredential. A $null value
        is ignored so callers can call this unconditionally.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [AllowNull()]
        $Credential
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($null -eq $Credential) {
        return
    }

    foreach ($step in @(
            { $Credential.Listener.Stop() }
            { $Credential.Worker.Dispose() }
            { $Credential.Runspace.Dispose() }
        )) {
        try {
            & $step
        }
        catch {
            Write-AvmLog `
                -Level Verbose `
                -Message ("policy: synthetic token endpoint cleanup ignored an error: {0}" -f $_.Exception.Message) |
                Out-Null
        }
    }
}
