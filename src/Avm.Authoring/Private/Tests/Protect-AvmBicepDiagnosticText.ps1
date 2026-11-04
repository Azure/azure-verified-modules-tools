function Protect-AvmBicepDiagnosticText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()] [string] $Text,
        [AllowEmptyCollection()] [string[]] $SensitiveValues = @()
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($Text.Length -gt 65536) { return '[diagnostic omitted: too long to redact safely]' }
    foreach ($value in $SensitiveValues) {
        if (-not [string]::IsNullOrEmpty($value)) {
            $Text = $Text.Replace($value, '[REDACTED]', [System.StringComparison]::Ordinal)
            $encoded = [uri]::EscapeDataString($value)
            if ($encoded -cne $value) {
                $Text = $Text.Replace($encoded, '[REDACTED]', [System.StringComparison]::OrdinalIgnoreCase)
            }
            $encoded = ConvertTo-Json -InputObject $value -Compress
            $encoded = $encoded.Substring(1, $encoded.Length - 2)
            if ($encoded -cne $value) {
                $Text = $Text.Replace($encoded, '[REDACTED]', [System.StringComparison]::Ordinal)
            }
            if ($value.Length -ge 4) {
                $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($value))
                $Text = $Text.Replace($encoded, '[REDACTED]', [System.StringComparison]::Ordinal)
                $encoded = $encoded.TrimEnd('=').Replace('+', '-').Replace('/', '_')
                $Text = $Text.Replace($encoded, '[REDACTED]', [System.StringComparison]::Ordinal)
            }
        }
    }
    $timeout = [timespan]::FromSeconds(1)
    try {
        $Text = [regex]::Replace($Text,
            '(?i)\b(bearer\s+)[A-Za-z0-9._~+/\-]+=*', '$1[REDACTED]', 'None', $timeout)
        $Text = [regex]::Replace($Text,
            '(?i)\b(authorization)(["'']?\s*[:=]\s*)(?:"(?:\\.|[^"\\])*"|''(?:\\.|[^''\\])*''|(?:basic|bearer)\s+[^\s,;&]+|[^\s,;&]+)',
            '$1$2[REDACTED]', 'None', $timeout)
        $Text = [regex]::Replace($Text,
            '(?i)\b(password|passwd|secret|token|key|access[_-]?token|refresh[_-]?token|access[_-]?key|account[_-]?key|sharedaccesskey|sharedaccesssignature|client[_-]?secret|sig|signature|api[_-]?key|connection[_-]?string)\b(["'']?\s*[:=]\s*)(?:"(?:\\.|[^"\\])*"|''(?:\\.|[^''\\])*''|[^\s,;&]+)',
            '$1$2[REDACTED]', 'None', $timeout)
        $Text = [regex]::Replace($Text,
            '\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b', '[REDACTED]', 'None', $timeout)
    }
    catch [System.Text.RegularExpressions.RegexMatchTimeoutException] {
        return '[diagnostic omitted: redaction timed out]'
    }
    $Text = [regex]::Replace($Text, '[\x00-\x1f\x7f]', ' ')
    if ($Text.Length -gt 2048) { return $Text.Substring(0, 2048) + ' [truncated]' }
    return $Text
}
