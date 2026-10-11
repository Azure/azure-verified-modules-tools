function ConvertFrom-AvmRetryAfterHeader {
    <#
    .SYNOPSIS
        Convert a Retry-After header value (seconds or HTTP date) to seconds, or $null.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [AllowNull()] [object] $Value,
        [datetimeoffset] $Now = [datetimeoffset]::UtcNow
    )

    Set-StrictMode -Version 3.0
    $text = @($Value | Where-Object { $null -ne $_ } | Select-Object -First 1) -join ''
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $seconds = 0
    if ([int]::TryParse($text.Trim(), [ref]$seconds)) { return [double][math]::Max(0, $seconds) }
    $date = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse($text.Trim(), [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$date)) {
        return [double][math]::Max(0, ($date - $Now).TotalSeconds)
    }
    return $null
}