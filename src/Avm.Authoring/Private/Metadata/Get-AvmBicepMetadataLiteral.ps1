function Get-AvmBicepMetadataLiteral {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Source
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $literal = "'''[\s\S]*?'''|'(?:\\.|[^'\\\r\n])*'"
    $pattern = "(?m)(?<declaration>^[\t ]*metadata[\t ]+(?<name>name|description)[\t ]*=[\t ]*(?<value>$literal)(?=[\t ]*(?://[^\r\n]*)?\r?$))|/\*[\s\S]*?\*/|//[^\r\n]*|$literal"
    $values = @{}
    foreach ($token in [regex]::Matches($Source, $pattern)) {
        if (-not $token.Groups['declaration'].Success) {
            continue
        }
        $name = $token.Groups['name'].Value
        if ($values.ContainsKey($name)) {
            throw [System.ArgumentException]::new("main.bicep declares metadata $name more than once.")
        }
        $raw = $token.Groups['value'].Value
        if ($raw.StartsWith("'''", [System.StringComparison]::Ordinal)) {
            $value = $raw.Substring(3, $raw.Length - 6).Replace("`r`n", "`n")
            if ($value.StartsWith("`n", [System.StringComparison]::Ordinal)) {
                $value = $value.Substring(1)
            }
            $values[$name] = $value
            continue
        }

        $body = $raw.Substring(1, $raw.Length - 2)
        $decoded = [System.Text.StringBuilder]::new()
        for ($index = 0; $index -lt $body.Length; $index++) {
            $character = $body[$index]
            if ($character -eq '$' -and $index + 1 -lt $body.Length -and $body[$index + 1] -eq '{') {
                throw [System.ArgumentException]::new("metadata $name must be a literal, not an interpolated string.")
            }
            if ($character -ne '\') {
                $null = $decoded.Append($character)
                continue
            }
            $index++
            $escaped = $body[$index]
            switch -CaseSensitive ($escaped) {
                'n' { $null = $decoded.Append("`n") }
                'r' { $null = $decoded.Append("`r") }
                't' { $null = $decoded.Append("`t") }
                '\' { $null = $decoded.Append('\') }
                "'" { $null = $decoded.Append("'") }
                '$' { $null = $decoded.Append('$') }
                'u' {
                    $unicode = [regex]::Match($body.Substring($index), '^u\{([0-9a-fA-F]{1,6})\}')
                    if (-not $unicode.Success) {
                        throw [System.ArgumentException]::new("Invalid Unicode escape in metadata $name.")
                    }
                    $codePoint = [Convert]::ToInt32($unicode.Groups[1].Value, 16)
                    $null = $decoded.Append([char]::ConvertFromUtf32($codePoint))
                    $index += $unicode.Length - 1
                }
                default {
                    throw [System.ArgumentException]::new("Unsupported escape '\$escaped' in metadata $name.")
                }
            }
        }
        $values[$name] = $decoded.ToString()
    }

    foreach ($required in @('name', 'description')) {
        if (-not $values.ContainsKey($required)) {
            throw [System.ArgumentException]::new("main.bicep must declare metadata $required as a string literal.")
        }
    }
    return $values
}
