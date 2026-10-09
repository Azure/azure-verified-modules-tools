function Get-AvmBicepRetryPolicy {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [System.Collections.IDictionary] $InputObject
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $root = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath @('..', 'Resources', 'bicep')
    $json = if ($PSBoundParameters.ContainsKey('InputObject')) {
        ConvertTo-Json -InputObject $InputObject -Depth 40 -Compress -WarningAction Stop
    }
    else { [System.IO.File]::ReadAllText((Join-Path $root 'retry-policy.json')) }
    try {
        $policy = ConvertFrom-AvmStrictJson -Json $json -RejectCaseInsensitiveDuplicates
    }
    catch [System.ArgumentException] {
        throw [AvmConfigurationException]::new('The Bicep retry policy must be strict JSON.', $_.Exception)
    }
    $schema = [System.IO.File]::ReadAllText((Join-Path $root 'retry-policy.schema.json'))
    if (-not (Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue)) {
        throw [AvmConfigurationException]::new('The Bicep retry policy has invalid fields, modes or execution limits.')
    }
    $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($rule in $policy['rules']) {
        if (-not $ids.Add($rule['id']) -or
            ($rule['code'] -eq '' -and -not $rule['parentSingleDetail']) -or
            ($rule['targetRequired'] -and (-not $rule.Contains('targetTypes') -or $rule['forbidTarget'])) -or
            ($rule['parentTargetRequired'] -and $rule['parentWithoutTarget']) -or
            ($rule.Contains('jsonMessagePattern') -and -not $rule.Contains('jsonEquals'))) {
            throw [AvmConfigurationException]::new('The Bicep retry policy contains an ambiguous rule.')
        }
        if ($rule.Contains('numberCaptures')) {
            foreach ($bounds in $rule['numberCaptures'].psbase.Values) {
                if ($bounds['exclusiveMinimum'] -ge $bounds['maximum']) {
                    throw [AvmConfigurationException]::new("Invalid numeric bounds in Bicep retry rule '$($rule['id'])'.")
                }
            }
        }
        $captures = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $patterns = @($rule['messagePatterns'])
        foreach ($name in @('parentMessagePattern', 'jsonMessagePattern')) {
            if ($rule.Contains($name)) { $patterns += $rule[$name] }
        }
        foreach ($pattern in $patterns) {
            try {
                $regex = [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline,
                    [timespan]::FromMilliseconds(100))
            }
            catch [System.ArgumentException] {
                throw [AvmConfigurationException]::new("Invalid Bicep retry pattern in '$($rule['id'])'.", $_.Exception)
            }
            foreach ($name in $regex.GetGroupNames()) { $null = $captures.Add($name) }
        }
        $required = @()
        foreach ($name in @('numberCaptures', 'dateCaptures', 'listCaptures')) {
            if ($rule.Contains($name)) { $required += @($rule[$name].psbase.Keys) }
        }
        if ($rule.Contains('regionCapture')) { $required += $rule['regionCapture'] }
        if ($rule.Contains('jsonEquals')) {
            $required += 'json'
            $required += @($rule['jsonEquals'].psbase.Values | Where-Object { $_ -is [string] -and $_.StartsWith('@') } |
                    ForEach-Object { $_.Substring(1) })
        }
        if ($rule.Contains('headerNames')) { $required += 'headers' }
        foreach ($name in $required) {
            if (-not $captures.Contains($name)) {
                throw [AvmConfigurationException]::new("Bicep retry rule '$($rule['id'])' references an absent capture '$name'.")
            }
        }
    }
    return $policy
}
