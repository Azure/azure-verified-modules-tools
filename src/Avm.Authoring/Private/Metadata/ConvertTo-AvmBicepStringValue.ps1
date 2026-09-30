function ConvertTo-AvmBicepStringValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Value
    )

    $escaped = [System.Text.StringBuilder]::new()
    foreach ($character in $Value.ToCharArray()) {
        switch -CaseSensitive ($character) {
            '\' { $null = $escaped.Append('\\') }
            "'" { $null = $escaped.Append("\'") }
            '$' { $null = $escaped.Append('\$') }
            "`r" { $null = $escaped.Append('\r') }
            "`n" { $null = $escaped.Append('\n') }
            "`t" { $null = $escaped.Append('\t') }
            default {
                if ([char]::IsControl($character)) {
                    $null = $escaped.Append('\u{' + ('{0:x}' -f [int]$character) + '}')
                }
                else {
                    $null = $escaped.Append($character)
                }
            }
        }
    }
    return $escaped.ToString()
}
