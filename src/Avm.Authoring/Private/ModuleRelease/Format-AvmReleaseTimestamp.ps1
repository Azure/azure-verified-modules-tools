function Format-AvmReleaseTimestamp {
    <#
    .SYNOPSIS
        Format a timestamp in the canonical release-state form.

    .DESCRIPTION
        Converts the value with ConvertTo-AvmReleaseTimestamp and formats it as yyyy-MM-ddTHH:mm:ssZ in UTC. Fractional seconds are dropped. Release state and release records store every timestamp in this form.

    .PARAMETER Value
        The timestamp to format. Accepts the same inputs as ConvertTo-AvmReleaseTimestamp.

    .PARAMETER Name
        A label used in error messages.

    .EXAMPLE
        Format-AvmReleaseTimestamp -Value '2026-09-07T11:00:00+02:00'

        Returns '2026-09-07T09:00:00Z'.

    .OUTPUTS
        String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Value,

        [string] $Name = 'Timestamp'
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $instant = ConvertTo-AvmReleaseTimestamp -Value $Value -Name $Name
    return $instant.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
}
