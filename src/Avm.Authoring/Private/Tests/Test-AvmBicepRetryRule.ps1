function Test-AvmBicepRetryRule {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Rule,
        [Parameter(Mandatory)] [hashtable] $Node,
        [hashtable] $Parent = @{},
        [string[]] $Targets = @(),
        [string] $SubscriptionId,
        [string] $ResourceLocation
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ([string]$Node['code'] -cne $Rule['code'] -or $Node['message'] -isnot [string] -or
        $Node.ContainsKey('innererror') -or
        ($Node.ContainsKey('details') -and -not ($Rule['allowEmptyDetails'] -and $Node['details'].Count -eq 0)) -or
        ($Rule['forbidTarget'] -and $Node.ContainsKey('target')) -or
        ($Rule.Contains('parentCode') -and $Parent['code'] -cne $Rule['parentCode']) -or
        ($Rule['parentTargetRequired'] -and -not $Parent.ContainsKey('target')) -or
        ($Rule['parentWithoutTarget'] -and ($Parent.ContainsKey('target') -or $Parent.ContainsKey('innererror'))) -or
        ($Rule['parentSingleDetail'] -and ($Parent['details'] -isnot [System.Collections.IList] -or
            $Parent['details'].Count -ne 1 -or $Parent.ContainsKey('innererror')))) { return $false }

    $captures = @{}
    $patterns = @($Rule['messagePatterns'] | ForEach-Object { @{ Pattern = $_; Text = $Node['message'] } })
    if ($Rule.Contains('parentMessagePattern')) {
        if ($Parent['message'] -isnot [string]) { return $false }
        $patterns += @{ Pattern = $Rule['parentMessagePattern']; Text = $Parent['message'] }
    }
    for ($index = 0; $index -lt $patterns.Count; $index++) {
        $pattern = $patterns[$index]
        try {
            $match = [regex]::Match($pattern.Text, $pattern.Pattern,
                [System.Text.RegularExpressions.RegexOptions]::Singleline, [timespan]::FromMilliseconds(100))
        }
        catch [System.Text.RegularExpressions.RegexMatchTimeoutException] { return $false }
        if (-not $match.Success) { return $false }
        foreach ($group in $match.Groups) {
            if ($group.Name -notmatch '^\d+$' -and $group.Success) { $captures[$group.Name] = $group.Value }
        }
        if ($index -eq $patterns.Count - 1 -and $Rule.Contains('jsonEquals')) {
            try { $body = ConvertFrom-AvmStrictJson -Json $captures['json'] -RejectCaseInsensitiveDuplicates }
            catch [System.ArgumentException] { return $false }
            $keys = @($Rule['jsonEquals'].psbase.Keys)
            if ($Rule.Contains('jsonMessagePattern')) { $keys += 'message' }
            if ($body.psbase.Count -ne $keys.Count -or
                @($body.psbase.Keys | Where-Object { $_ -cnotin $keys }).Count -gt 0) { return $false }
            foreach ($key in $Rule['jsonEquals'].psbase.Keys) {
                $expected = $Rule['jsonEquals'][$key]
                if ($expected -is [string] -and $expected.StartsWith('@')) { $expected = $captures[$expected.Substring(1)] }
                if ($null -eq $expected) {
                    if ($null -ne $body[$key]) { return $false }
                }
                elseif ($body[$key] -isnot [string] -or $body[$key] -cne $expected) { return $false }
            }
            if ($Rule.Contains('jsonMessagePattern') -and -not $captures.ContainsKey('jsonChecked')) {
                if ($body['message'] -isnot [string]) { return $false }
                $patterns += @{ Pattern = $Rule['jsonMessagePattern']; Text = $body['message'] }
                $captures['jsonChecked'] = $true
            }
        }
    }
    $region = ($ResourceLocation -replace '\s', '').ToLowerInvariant()
    if ($Rule.Contains('regionCapture') -and
        (-not $region -or $region -eq 'global' -or
        ($captures[$Rule['regionCapture']] -replace '\s', '').ToLowerInvariant() -ne $region)) { return $false }
    foreach ($name in @('numberCaptures', 'dateCaptures', 'listCaptures')) {
        if (-not $Rule.Contains($name)) { continue }
        foreach ($key in $Rule[$name].psbase.Keys) {
            $value = $captures[$key]
            $constraint = $Rule[$name][$key]
            switch ($name) {
                'numberCaptures' {
                    $number = 0.0
                    if (-not [double]::TryParse($value, [System.Globalization.NumberStyles]::AllowDecimalPoint,
                            [cultureinfo]::InvariantCulture, [ref]$number) -or
                        $number -le $constraint['exclusiveMinimum'] -or $number -gt $constraint['maximum']) { return $false }
                }
                'dateCaptures' {
                    $date = [datetime]::MinValue
                    if (-not [datetime]::TryParseExact($value, $constraint, [cultureinfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::None, [ref]$date)) { return $false }
                }
                'listCaptures' {
                    if ($value -isnot [string] -or -not $value) { return $false }
                    $items = $value.Split(',')
                    if ($items.Count -gt $constraint['maximumCount'] -or
                        @($items | Select-Object -Unique).Count -ne $items.Count) { return $false }
                    foreach ($item in $items) {
                        if (($constraint.Contains('allowed') -and $item -cnotin $constraint['allowed']) -or
                            $item -cin $constraint['excluded'] -or
                            ($constraint['excludeRegion'] -and $item -eq $region)) { return $false }
                    }
                }
            }
        }
    }
    if ($Rule.Contains('targetTypes')) {
        $serviceTarget = ''
        if ($Targets.Count -gt 0) {
            $subscription = [guid]::Empty
            if (-not [guid]::TryParseExact($SubscriptionId, 'D', [ref]$subscription) -or $subscription -eq [guid]::Empty) { return $false }
            $prefix = '\A/subscriptions/' + [regex]::Escape($subscription.ToString('D'))
            $types = @($Rule['targetTypes'] | ForEach-Object { [regex]::Escape($_) }) -join '|'
            $resourcePattern = "$prefix/resourceGroups/[^/?#\s]+/providers/(?:$types)/[^/?#\s]+\z"
            $deploymentPattern = "$prefix(?:/resourceGroups/[^/?#\s]+)?/providers/Microsoft\.Resources/deployments/[^/?#\s]+\z"
            foreach ($target in $Targets) {
                if ($target -match $resourcePattern) {
                    if ($serviceTarget -and $serviceTarget -ine $target) { return $false }
                    $serviceTarget = $target
                }
                elseif ($target -notmatch $deploymentPattern) { return $false }
            }
        }
        if ($Rule['targetRequired'] -and -not $serviceTarget) { return $false }
    }
    if ($Rule.Contains('headerNames')) {
        $headers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($line in $captures['headers'] -split '\r?\n') {
            if (-not $line) { continue }
            $separator = $line.IndexOf(':')
            if ($separator -lt 1) { return $false }
            $name = $line.Substring(0, $separator)
            if ($name -notin $Rule['headerNames'] -or -not $headers.Add($name) -or
                [string]::IsNullOrWhiteSpace($line.Substring($separator + 1))) { return $false }
        }
    }
    return $true
}
