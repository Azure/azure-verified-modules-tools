function Get-AvmBicepDocsExampleCommentDifferenceCount {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]] $CurrentBytes,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $GeneratedContent,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $ProbeContent,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Markers
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Markers.Count -eq 0) {
        return 0
    }
    $lines = $GeneratedContent.Split([char]"`n")
    $probeLines = $ProbeContent.Split([char]"`n")
    if ($lines.Length -ne $probeLines.Length) {
        return 0
    }

    $ordinal = [System.StringComparison]::Ordinal
    $requiredLine = '    // Required parameters'
    $nonRequiredLine = '    // Non-required parameters'
    $markerLookup = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::Ordinal)
    $positions = [System.Collections.Generic.List[object]]::new()
    foreach ($marker in $Markers) {
        $requiredMarker = [string]$marker.RequiredMarker
        $nonRequiredMarker = [string]$marker.NonRequiredMarker
        if ([string]::IsNullOrEmpty($requiredMarker) -or
            [string]::IsNullOrEmpty($nonRequiredMarker) -or
            $requiredMarker.Contains("`n") -or $nonRequiredMarker.Contains("`n") -or
            $markerLookup.ContainsKey($requiredMarker) -or
            $markerLookup.ContainsKey($nonRequiredMarker) -or
            $requiredMarker.Equals($nonRequiredMarker, $ordinal) -or
            $GeneratedContent.Contains($requiredMarker, $ordinal) -or
            $GeneratedContent.Contains($nonRequiredMarker, $ordinal)) {
            return 0
        }
        $pair = [pscustomobject]@{ Required = -1; NonRequired = -1 }
        $positions.Add($pair)
        $markerLookup.Add($requiredMarker, [pscustomobject]@{
                Pair = $pair; Kind = 'Required'
            })
        $markerLookup.Add($nonRequiredMarker, [pscustomobject]@{
                Pair = $pair; Kind = 'NonRequired'
            })
    }

    for ($index = 0; $index -lt $lines.Length; $index++) {
        $probeLine = $probeLines[$index]
        foreach ($token in $markerLookup.Keys) {
            if (-not $probeLine.StartsWith($token, $ordinal)) {
                continue
            }
            $entry = $markerLookup[$token]
            $probeLine = $probeLine.Substring($token.Length)
            if ($entry.Kind -eq 'Required') {
                if ($entry.Pair.Required -ge 0 -or
                    -not $probeLine.Equals($requiredLine, $ordinal)) {
                    return 0
                }
                $entry.Pair.Required = $index
            }
            else {
                if ($entry.Pair.NonRequired -ge 0 -or
                    -not $probeLine.Equals($nonRequiredLine, $ordinal)) {
                    return 0
                }
                $entry.Pair.NonRequired = $index
            }
            break
        }
        if (-not $probeLine.Equals($lines[$index], $ordinal)) {
            return 0
        }
    }

    $commentPairs = [System.Collections.Generic.Dictionary[int, int]]::new()
    $optionalToRequired = [System.Collections.Generic.Dictionary[int, int]]::new()
    foreach ($pair in $positions) {
        $required = $pair.Required
        $nonRequired = $pair.NonRequired
        if ($required -lt 0 -and $nonRequired -lt 0) {
            continue
        }
        if ($required -lt 1 -or $nonRequired -le ($required + 1) -or
            $nonRequired + 1 -ge $lines.Length -or
            -not $lines[$required - 1].Equals('  "parameters": {', $ordinal) -or
            $lines[$required + 1] -cnotmatch '^ {4}"[^"]+": \{$' -or
            $lines[$nonRequired - 1] -cnotmatch '^ {4}\},?$' -or
            $lines[$nonRequired + 1] -cnotmatch '^ {4}"[^"]+": \{$' -or
            $commentPairs.ContainsKey($required) -or
            $optionalToRequired.ContainsKey($nonRequired)) {
            return 0
        }
        $commentPairs.Add($required, $nonRequired)
        $optionalToRequired.Add($nonRequired, $required)
    }
    if ($commentPairs.Count -eq 0) {
        return 0
    }

    try {
        $currentLines = [System.Text.UTF8Encoding]::new($false, $true).GetString(
            $CurrentBytes).Split([char]"`n")
    }
    catch [System.Text.DecoderFallbackException] {
        return 0
    }
    $missingRequired = [System.Collections.Generic.HashSet[int]]::new()
    $missingPairs = 0
    $currentIndex = 0
    for ($index = 0; $index -lt $lines.Length; $index++) {
        if ($currentIndex -ge $currentLines.Length) {
            return 0
        }
        if ($lines[$index].Equals($currentLines[$currentIndex], $ordinal)) {
            $currentIndex++
            continue
        }
        if ($commentPairs.ContainsKey($index) -and $index + 1 -lt $lines.Length -and
            $lines[$index + 1].Equals($currentLines[$currentIndex], $ordinal)) {
            $null = $missingRequired.Add($index)
            continue
        }
        if ($optionalToRequired.ContainsKey($index) -and
            $missingRequired.Contains($optionalToRequired[$index]) -and
            $index + 1 -lt $lines.Length -and
            $lines[$index + 1].Equals($currentLines[$currentIndex], $ordinal)) {
            $missingPairs++
            continue
        }
        return 0
    }
    if ($currentIndex -ne $currentLines.Length -or $missingPairs -eq 0 -or
        $missingRequired.Count -ne $missingPairs) {
        return 0
    }
    return ($missingPairs * 2)
}
