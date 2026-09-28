function ConvertTo-AvmBicepDocsExampleParameter {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Parameters,

        [AllowEmptyCollection()]
        [string[]] $RequiredParameters = @()
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $sortedNames = @($Parameters.psbase.Keys | Sort-Object -Culture 'en-US')
    $orderedNames = @($sortedNames | Where-Object { $_ -in $RequiredParameters }) +
    @($sortedNames | Where-Object { $_ -notin $RequiredParameters })
    $ordered = [ordered]@{}
    $withValue = [ordered]@{}
    foreach ($name in $orderedNames) {
        if ($Parameters[$name] -isnot [System.Collections.IDictionary] -or
            -not $Parameters[$name].Contains('value')) {
            throw [AvmConfigurationException]::new(
                "Bicep example parameter '$name' must have a value.")
        }
        $value = Get-AvmBicepDocsOrderedValue -Value $Parameters[$name]['value']
        $ordered[$name] = $value
        $withValue[$name] = [ordered]@{ value = $value }
    }

    $addComments = $RequiredParameters.Count -ge 1 -and $orderedNames.Count -ge 2
    $bicepLines = [System.Collections.Generic.List[string]]::new()
    $json = (ConvertTo-Json -InputObject $ordered -Depth 99).ReplaceLineEndings("`n")
    $rawLines = $json -split "`n"
    if ($rawLines.Count -gt 2) {
        foreach ($rawLine in $rawLines[1..($rawLines.Count - 2)]) {
            $line = $rawLine.Replace("'", "\'").Replace('"', "'")
            $line = $line -replace ',$', ''
            $line = $line -replace "'(\w+)':", '$1:'
            $line = $line -replace "'(.+\.getSecret\(\\'.+'\\\))'", '$1'
            $line = $line -replace '\\\\\$', '\$'
            $bicepLines.Add("  $line")
        }
    }
    if ($addComments) {
        $seenRequired = $false
        for ($index = 0; $index -lt $bicepLines.Count; $index++) {
            if ($bicepLines[$index] -notmatch '^ {4}([A-Za-z][A-Za-z0-9_]*):') {
                continue
            }
            if ($Matches[1] -in $RequiredParameters) {
                $seenRequired = $true
            }
            elseif ($seenRequired) {
                $bicepLines.Insert($index, '    // Non-required parameters')
                break
            }
        }
        $bicepLines.Insert(0, '    // Required parameters')
    }
    $bicep = ($bicepLines.ToArray() -join "`n").TrimEnd()

    $jsonDocument = [ordered]@{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = $withValue
    }
    $jsonLines = [System.Collections.Generic.List[string]]::new()
    $printedRequired = $false
    $printedOptional = $false
    $inParameters = $false
    foreach ($line in ((ConvertTo-Json -InputObject $jsonDocument -Depth 99).ReplaceLineEndings("`n") -split "`n")) {
        $jsonLines.Add($line)
        if ($line -match '^ {2}"parameters": \{$') {
            $inParameters = $true
            if ($addComments) {
                $jsonLines.Add('    // Required parameters')
                $printedRequired = $true
            }
            continue
        }
        if ($inParameters -and $addComments -and
            $line -match '^ {4}"([^"]+)": \{$' -and
            $Matches[1] -notin $RequiredParameters -and -not $printedOptional) {
            $jsonLines.RemoveAt($jsonLines.Count - 1)
            $jsonLines.Add('    // Non-required parameters')
            $jsonLines.Add($line)
            $printedOptional = $true
        }
    }
    if ($printedRequired -and -not $printedOptional -and
        $orderedNames.Count -gt $RequiredParameters.Count) {
        throw [AvmConfigurationException]::new(
            'Bicep example JSON parameters could not be grouped by requirement.')
    }

    $fileLines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($bicep -split "`n")) {
        if ([string]::IsNullOrEmpty($line)) {
            continue
        }
        $text = $line -creplace '^ {4}([a-zA-Z]*):(.*)$', 'param $1 =$2'
        $fileLines.Add(($text -creplace '^ {4}', ''))
    }

    return [pscustomobject]@{
        BicepParameters    = $bicep
        JsonParameters     = ($jsonLines.ToArray() -join "`n").Trim()
        BicepParameterFile = $fileLines.ToArray() -join "`n"
    }
}
