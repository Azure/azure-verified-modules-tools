function Get-AvmBicepDocsExampleCommentDifferenceCount {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]] $CurrentBytes,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $GeneratedContent
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $lines = $GeneratedContent.Split([char]"`n")
    $commentPairs = [System.Collections.Generic.Dictionary[int, int]]::new()
    $optionalToRequired = [System.Collections.Generic.Dictionary[int, int]]::new()
    $inUsageExamples = $false
    $inExample = $false
    $exampleStart = -1
    $ordinal = [System.StringComparison]::Ordinal
    $schemaLine = '  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",'
    $usageStart = -1
    $parametersStart = -1
    for ($scan = 0; $scan -lt $lines.Length; $scan++) {
        if ($lines[$scan].Equals('## Usage examples', $ordinal)) {
            if ($usageStart -ge 0) { return 0 }
            $usageStart = $scan
        }
        elseif ($lines[$scan].Equals('## Parameters', $ordinal)) {
            if ($parametersStart -ge 0) { return 0 }
            $parametersStart = $scan
        }
    }
    if ($usageStart -lt 0 -or $parametersStart -le $usageStart) {
        return 0
    }
    $tocCount = 0
    $exampleCount = 0
    for ($scan = $usageStart + 1; $scan -lt $parametersStart; $scan++) {
        $line = $lines[$scan]
        if ($line.StartsWith('## ', $ordinal)) {
            return 0
        }
        if ($line -cmatch '^### Example ([1-9]\d*): _.+_$') {
            $exampleCount++
            if ($Matches[1] -cne [string]$exampleCount) { return 0 }
        }
        elseif ($line -cmatch '^- \[.+\]\(#example-([1-9]\d*)-[^)]+\)$') {
            if ($exampleCount -gt 0 -or
                $Matches[1] -cne [string]($tocCount + 1)) {
                return 0
            }
            $tocCount++
        }
    }
    if ($exampleCount -eq 0 -or $tocCount -ne $exampleCount) {
        return 0
    }
    for ($index = 0; $index -lt $lines.Length; $index++) {
        $line = $lines[$index]
        if ($line.Equals('## Usage examples', $ordinal)) {
            $inUsageExamples = $true
            $inExample = $false
            $exampleStart = -1
            continue
        }
        if ($line.StartsWith('## ', [System.StringComparison]::Ordinal)) {
            $inUsageExamples = $false
            $inExample = $false
            $exampleStart = -1
            continue
        }
        if ($line.StartsWith('### ', [System.StringComparison]::Ordinal)) {
            if ($inUsageExamples -and $line -cmatch '^### Example [1-9]\d*: _.+_$') {
                $inExample = $true
                $exampleStart = $index
            }
            continue
        }
        if (-not $line.StartsWith('```', [System.StringComparison]::Ordinal)) {
            continue
        }

        $end = $index + 1
        while ($end -lt $lines.Length -and -not $lines[$end].Equals('```', $ordinal)) {
            $end++
        }
        if ($end -eq $lines.Length) {
            return 0
        }

        if ($inExample -and $line.Equals('```json', $ordinal) -and $index -ge 9 -and
            $end + 9 -lt $lines.Length -and
            $lines[$index - 9].Equals('```', $ordinal) -and
            $lines[$index - 8].Equals('', $ordinal) -and
            $lines[$index - 7].Equals('</details>', $ordinal) -and
            $lines[$index - 6].Equals('<p>', $ordinal) -and
            $lines[$index - 5].Equals('', $ordinal) -and
            $lines[$index - 4].Equals('<details>', $ordinal) -and
            $lines[$index - 3].Equals('', $ordinal) -and
            $lines[$index - 2].Equals('<summary>via JSON parameters file</summary>', $ordinal) -and
            $lines[$index - 1].Equals('', $ordinal) -and $index + 6 -lt $end -and
            $lines[$index + 1].Equals('{', $ordinal) -and
            $lines[$index + 2].Equals($schemaLine, $ordinal) -and
            $lines[$index + 3].Equals('  "contentVersion": "1.0.0.0",', $ordinal) -and
            $lines[$index + 4].Equals('  "parameters": {', $ordinal) -and
            $lines[$index + 5].Equals('    // Required parameters', $ordinal) -and
            $lines[$index + 6] -cmatch '^ {4}"[^"]+": \{$' -and
            $lines[$end - 2].Equals('  }', $ordinal) -and
            $lines[$end - 1].Equals('}', $ordinal) -and
            $lines[$end + 1].Equals('', $ordinal) -and
            $lines[$end + 2].Equals('</details>', $ordinal) -and
            $lines[$end + 3].Equals('<p>', $ordinal) -and
            $lines[$end + 4].Equals('', $ordinal) -and
            $lines[$end + 5].Equals('<details>', $ordinal) -and
            $lines[$end + 6].Equals('', $ordinal) -and
            $lines[$end + 7].Equals('<summary>via Bicep parameters file</summary>', $ordinal) -and
            $lines[$end + 8].Equals('', $ordinal) -and
            $lines[$end + 9].Equals('```bicep-params', $ordinal)) {
            $exampleEnd = $end + 1
            while ($exampleEnd -lt $lines.Length -and
                -not $lines[$exampleEnd].Equals('## Parameters', $ordinal) -and
                $lines[$exampleEnd] -cnotmatch '^### Example [1-9]\d*: _.+_$') {
                $exampleEnd++
            }
            $moduleSummary = -1
            $jsonSummary = -1
            $paramsSummary = -1
            $optional = -1
            $valid = $true
            for ($lineIndex = $exampleStart + 1; $lineIndex -lt $exampleEnd; $lineIndex++) {
                if ($lines[$lineIndex].Equals('<summary>via Bicep module</summary>', $ordinal)) {
                    if ($moduleSummary -ge 0) {
                        $valid = $false
                        break
                    }
                    $moduleSummary = $lineIndex
                }
                elseif ($lines[$lineIndex].Equals('<summary>via JSON parameters file</summary>', $ordinal)) {
                    if ($jsonSummary -ge 0) {
                        $valid = $false
                        break
                    }
                    $jsonSummary = $lineIndex
                }
                elseif ($lines[$lineIndex].Equals('<summary>via Bicep parameters file</summary>', $ordinal)) {
                    if ($paramsSummary -ge 0) {
                        $valid = $false
                        break
                    }
                    $paramsSummary = $lineIndex
                }
            }
            if (-not $valid -or $moduleSummary -lt $exampleStart -or
                $moduleSummary -ge $jsonSummary -or $jsonSummary -ne ($index - 2) -or
                $paramsSummary -ne ($end + 7) -or
                -not $lines[$moduleSummary - 2].Equals('<details>', $ordinal) -or
                -not $lines[$moduleSummary + 2].Equals('```bicep', $ordinal)) {
                $index = $end
                continue
            }
            for ($lineIndex = $index + 7; $lineIndex -lt $end; $lineIndex++) {
                if ($lines[$lineIndex].Equals('    // Required parameters', $ordinal)) {
                    $valid = $false
                    break
                }
                if (-not $lines[$lineIndex].Equals('    // Non-required parameters', $ordinal)) {
                    continue
                }
                if ($optional -ge 0 -or
                    $lines[$lineIndex - 1] -cnotmatch '^ {4}\},?$' -or
                    $lineIndex + 1 -ge $end -or
                    $lines[$lineIndex + 1] -cnotmatch '^ {4}"[^"]+": \{$') {
                    $valid = $false
                    break
                }
                $optional = $lineIndex
            }
            if ($valid -and $optional -gt $index + 7) {
                $commentPairs.Add($index + 5, $optional)
                $optionalToRequired.Add($optional, $index + 5)
            }
        }
        $index = $end
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
