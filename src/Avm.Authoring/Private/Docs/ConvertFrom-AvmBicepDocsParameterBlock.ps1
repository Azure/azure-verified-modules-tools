function ConvertFrom-AvmBicepDocsParameterBlock {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowEmptyString()]
        [string] $Block,

        [Parameter(Mandatory)]
        [string] $SourcePath
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($Block)) {
        return @{}
    }

    $commentFree = Get-AvmBicepCommentFreeSource -Source $Block
    $lines = $commentFree.ReplaceLineEndings("`n") -split "`n"
    $firstParameter = $lines | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    } | Select-Object -First 1
    if ($null -eq $firstParameter) {
        return @{}
    }
    $indent = ([regex]::Match($firstParameter, '^(\s+)')).Groups[1].Value.Length
    $names = @($lines | Where-Object { $_ -match "^\s{$indent}[0-9a-zA-Z]+:.*" } |
            ForEach-Object { ($_ -split ':')[0].Trim() })
    $originalLines = $Block.ReplaceLineEndings("`n") -split "`n"
    $sourceLines = [System.Collections.Generic.List[string]]::new()
    $sourceLines.Add('{')
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if (-not [string]::IsNullOrWhiteSpace($lines[$index])) {
            $sourceLines.Add($originalLines[$index])
        }
    }
    $sourceLines.Add('}')
    $jsonLines = @('{', $commentFree, '}') -join "`n"
    $jsonLines = $jsonLines.Replace('"', '\"').Replace("'", '"')
    $jsonLines = @($jsonLines -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    for ($index = 0; $index -lt $jsonLines.Count; $index++) {
        $line = $jsonLines[$index]
        if ($null -eq $line) {
            continue
        }
        if ($line -match '^\s*//') {
            continue
        }
        $line = [regex]::Replace($line, '^\s*"{0}([0-9a-zA-Z_]+):', '"$1":', 1)
        if ($line -match '^\s*.+?:\s+') {
            $value = ($line -split '^\s*.+?:\s+')[1].Trim()
            $emptyObject = $line -match '^.+:\s*{\s*}\s*$'
            $propertyReference = $value -match '(?<=[^"])\b\.\b(?=[^"]*$)'
            $referenceKey = ($line -split ':')[0].Trim() -like '*.*'
            $interpolated = $value -match "['|`"]{1}.*(?<!\\)\$\{.+"
            $stringValue = $value -match '^".+"$'
            $functionValue = $value -match '^[a-zA-Z0-9]+\(.+'
            $plainValue = $value -match '^\w+$'
            $primitiveValue = $value -match '^\s*(true|false|[0-9])+$'
            $conditional = $value -match '^\w+ [=!?|&]{2} .+\?.+\:.+$'
            $multilineFunction = $value -match '[a-zA-Z]+\s*\([^\)]*\){0}\s*$'
            if ($multilineFunction) {
                $functionIndent = ([regex]::Match($jsonLines[$index], '^(\s+)')).Groups[1].Value.Length
                $end = $index + 1
                while ($end -lt $jsonLines.Count -and
                    $jsonLines[$end] -match "^\s{$($functionIndent+1),}") {
                    $end++
                }
                if ($end -ge $jsonLines.Count) {
                    throw [AvmConfigurationException]::new(
                        "Cannot locate the end of a Bicep function in '$SourcePath'.")
                }
                if ($jsonLines[$end] -notmatch '^\s*\)\s*$') {
                    throw [AvmConfigurationException]::new(
                        "Cannot locate the closing Bicep function parenthesis in '$SourcePath'.")
                }
                $key = ([regex]::Match(($line -split ':')[0], '"(.+)"')).Groups[1].Value
                $line = '{0}: "<{1}>"' -f ($line -split ':')[0], $key
                for ($functionLine = $index + 1; $functionLine -le $end; $functionLine++) {
                    $jsonLines[$functionLine] = $null
                }
            }
            elseif ((-not $emptyObject -and -not $stringValue -and $propertyReference) -or
                $interpolated -or $functionValue -or
                ($plainValue -and -not $primitiveValue) -or $conditional) {
                $key = ([regex]::Match(($line -split ':')[0], '"(.+)"')).Groups[1].Value
                $line = '{0}: "<{1}>"' -f ($line -split ':')[0], $key
            }
            elseif ($emptyObject -and $referenceKey) {
                $line = '"<{0}>": {1}' -f (($line -split ':')[0] -split '\.')[-1].TrimEnd('}"'), $value
            }
        }
        else {
            if ($line -notlike '*"*"*' -and $line -like '*.*') {
                $placeholder = $line.Split('.')[-1].Trim()
                $reference = [regex]::Match(
                    $sourceLines[$index].Trim(),
                    '^(?<code>[a-zA-Z_]\w*(?:\.[a-zA-Z_]\w*)+)(?<comment>\s+//[^\r\n]*)$')
                if ($reference.Success -and $reference.Groups['code'].Value -ceq $line.Trim()) {
                    $placeholder += $reference.Groups['comment'].Value.TrimEnd()
                    $line = ConvertTo-Json -InputObject "<$placeholder>" -Compress
                }
                else {
                    $line = '"<{0}>"' -f $placeholder
                }
            }
            elseif ($line -match '^\s*[a-zA-Z]+\s*$') {
                $line = '"<{0}>"' -f $line.Trim()
            }
            elseif ($line -match "['|`"]{1}.*\$\{.+") {
                $line = $line -replace '\$\{.+\}', '<value>'
            }
        }
        $jsonLines[$index] = $line -replace '\\\$', '\\$'
    }

    $jsonLines = @($jsonLines | Where-Object { $null -ne $_ })
    for ($index = 0; $index -lt $jsonLines.Count; $index++) {
        $open = $jsonLines[$index] -match '[\{|\[]\s*$'
        $closingNext = $index -lt $jsonLines.Count - 1 -and
        $jsonLines[$index + 1] -match '^\s*[\]|\}]\s*$'
        if ($open -or $closingNext -or $index -eq $jsonLines.Count - 1 -or
            $jsonLines[$index] -match '^\s*//') {
            continue
        }
        $jsonLines[$index] = $jsonLines[$index].TrimEnd() + ','
    }

    try {
        $parsed = ($jsonLines -join "`n") |
            ConvertFrom-Json -AsHashtable -Depth 99 -ErrorAction Stop
    }
    catch {
        throw [AvmConfigurationException]::new(
            "Cannot parse Bicep example parameters in '$SourcePath': $($_.Exception.Message)")
    }
    $parameters = @{}
    foreach ($name in $names) {
        if (-not $parsed.ContainsKey($name)) {
            throw [AvmConfigurationException]::new(
                "Bicep example '$SourcePath' is missing the extracted parameter '$name'.")
        }
        $parameters[$name] = @{ value = $parsed[$name] }
    }
    return $parameters
}
