function ConvertTo-AvmReleaseTimestamp {
    <#
    .SYNOPSIS
        Convert a release-engine timestamp into a UTC DateTimeOffset.

    .DESCRIPTION
        Accepts a DateTimeOffset, a UTC DateTime, or an ISO-8601 string with an explicit offset or a trailing Z. Returns the instant as a UTC DateTimeOffset. Local or unspecified DateTime values and strings without an offset are rejected, because the release timers depend on the exact UTC instant.

    .PARAMETER Value
        The timestamp to convert.

    .PARAMETER Name
        A label used in error messages.

    .EXAMPLE
        ConvertTo-AvmReleaseTimestamp -Value '2026-09-07T09:00:00Z'

        Returns Monday 7 September 2026 09:00 UTC.

    .OUTPUTS
        System.DateTimeOffset.
    #>
    [CmdletBinding()]
    [OutputType([System.DateTimeOffset])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Value,

        [string] $Name = 'Timestamp'
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($null -eq $Value) {
        throw [System.ArgumentException]::new("$Name is required.")
    }

    if ($Value -is [System.DateTimeOffset]) {
        return $Value.ToUniversalTime()
    }

    if ($Value -is [datetime]) {
        if ($Value.Kind -ne [System.DateTimeKind]::Utc) {
            throw [System.ArgumentException]::new("$Name must be a UTC DateTime.")
        }
        return [System.DateTimeOffset]::new($Value)
    }

    if ($Value -is [string]) {
        if ($Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?(Z|[+-]\d{2}:\d{2})$') {
            throw [System.ArgumentException]::new("$Name '$Value' must be an ISO-8601 timestamp with an offset, such as 2026-09-07T09:00:00Z.")
        }
        $parsed = [System.DateTimeOffset]::MinValue
        $styles = [System.Globalization.DateTimeStyles]::None
        if (-not [System.DateTimeOffset]::TryParse($Value, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref] $parsed)) {
            throw [System.ArgumentException]::new("$Name '$Value' is not a valid timestamp.")
        }
        return $parsed.ToUniversalTime()
    }

    throw [System.ArgumentException]::new("$Name must be a string, DateTime, or DateTimeOffset.")
}
