function Get-AvmBicepDocsExampleCommentProbe {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Values,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $GeneratedContent
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $ordinal = [System.StringComparison]::Ordinal
    $requiredLine = '    // Required parameters'
    $nonRequiredLine = '    // Non-required parameters'
    if (-not $GeneratedContent.Contains($requiredLine, $ordinal) -or
        -not $GeneratedContent.Contains($nonRequiredLine, $ordinal)) {
        return $null
    }

    $examples = ConvertFrom-Json -InputObject ([string]$Values['examples']) `
        -AsHashtable -Depth 99
    if ($examples -isnot [System.Collections.IDictionary]) {
        throw [AvmConfigurationException]::new(
            'Bicep documentation examples must be a JSON object for comment provenance.')
    }

    $markers = [System.Collections.Generic.List[object]]::new()
    $probeId = [guid]::NewGuid().ToString('N')
    foreach ($path in @($examples.Keys)) {
        $example = $examples[$path]
        if ($example -isnot [System.Collections.IDictionary] -or
            -not $example.Contains('JsonParameters')) {
            throw [AvmConfigurationException]::new(
                "Bicep documentation example '$path' has no JSON parameters for comment provenance.")
        }

        $fragmentLines = ([string]$example['JsonParameters']).Split([char]"`n")
        $required = -1
        $nonRequired = -1
        for ($index = 0; $index -lt $fragmentLines.Length; $index++) {
            if ($fragmentLines[$index].Equals($requiredLine, $ordinal)) {
                if ($required -ge 0) { return $null }
                $required = $index
            }
            elseif ($fragmentLines[$index].Equals($nonRequiredLine, $ordinal)) {
                if ($nonRequired -ge 0) { return $null }
                $nonRequired = $index
            }
        }
        if ($required -lt 0 -and $nonRequired -lt 0) {
            continue
        }
        if ($required -lt 1 -or $nonRequired -le ($required + 1) -or
            $nonRequired + 1 -ge $fragmentLines.Length -or
            -not $fragmentLines[$required - 1].Equals('  "parameters": {', $ordinal) -or
            $fragmentLines[$required + 1] -cnotmatch '^ {4}"[^"]+": \{$' -or
            $fragmentLines[$nonRequired - 1] -cnotmatch '^ {4}\},?$' -or
            $fragmentLines[$nonRequired + 1] -cnotmatch '^ {4}"[^"]+": \{$') {
            return $null
        }

        $markerNumber = $markers.Count
        $requiredMarker = "__AVM_DOCS_REQUIRED_${probeId}_${markerNumber}__"
        $nonRequiredMarker = "__AVM_DOCS_NON_REQUIRED_${probeId}_${markerNumber}__"
        if ($GeneratedContent.Contains($requiredMarker, $ordinal) -or
            $GeneratedContent.Contains($nonRequiredMarker, $ordinal)) {
            throw [AvmConfigurationException]::new(
                'Bicep documentation provenance marker collides with rendered content.')
        }
        $fragmentLines[$required] = $requiredMarker + $requiredLine
        $fragmentLines[$nonRequired] = $nonRequiredMarker + $nonRequiredLine
        $example['JsonParameters'] = $fragmentLines -join "`n"
        $markers.Add([pscustomobject]@{
                RequiredMarker    = $requiredMarker
                NonRequiredMarker = $nonRequiredMarker
            })
    }
    if ($markers.Count -eq 0) {
        return $null
    }

    $probeValues = @{}
    foreach ($key in $Values.Keys) {
        $probeValues[$key] = $Values[$key]
    }
    $probeValues['examples'] = ConvertTo-Json -InputObject $examples -Compress -Depth 99
    return [pscustomobject]@{
        Values  = $probeValues
        Markers = $markers.ToArray()
    }
}
