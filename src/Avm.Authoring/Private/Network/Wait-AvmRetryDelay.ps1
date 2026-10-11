function Wait-AvmRetryDelay {
    <#
    .SYNOPSIS
        Sleep between retry attempts. Separate so tests can mock the delay.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [double] $Seconds
    )

    if ($Seconds -gt 0) { Start-Sleep -Milliseconds ([int][math]::Ceiling($Seconds * 1000)) }
}