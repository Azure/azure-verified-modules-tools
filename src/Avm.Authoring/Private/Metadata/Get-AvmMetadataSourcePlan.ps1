function Get-AvmMetadataSourcePlan {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Metadata
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $sourcePath = Join-Path -Path $Path -ChildPath 'main.bicep'
    $source = Get-Content -LiteralPath $sourcePath -Raw
    $code = Get-AvmBicepCommentFreeSource -Source $source
    $literals = Get-AvmBicepMetadataLiteral -Source $source
    if ($literals.description -cne $Metadata.moduleDescription) {
        throw [System.ArgumentException]::new('The metadata description must match the existing main.bicep description.')
    }
    if (-not $Metadata.Contains('telemetryIdPrefix')) {
        if ($Metadata.canonicalType -cne 'helper' -and
            [regex]::IsMatch($code, "(?m)^[\t ]*resource[\t ]+avmTelemetry[\t ]+'Microsoft\.Resources/deployments@")) {
            throw [System.ArgumentException]::new('This Bicep module emits telemetry and requires telemetryIdPrefix.')
        }
        return
    }

    $declaration = "var avmTelemetryIdPrefix = loadJsonContent('metadata.json', '$.telemetryIdPrefix')"
    $nameReference = '${avmTelemetryIdPrefix}'
    $headPattern = "(?m)(?<head>^[\t ]*resource[\t ]+avmTelemetry[\t ]+'Microsoft\.Resources/deployments@[^']+'[^\r\n]*\{\s*name[\t ]*:[\t ]*')"
    if ($code.Contains($declaration) -and
        [regex]::IsMatch($code, $headPattern + [regex]::Escape($nameReference) + '\.')) {
        return
    }
    if ([regex]::IsMatch($code, '(?m)^[\t ]*var[\t ]+avmTelemetryIdPrefix\b')) {
        throw [System.ArgumentException]::new('main.bicep already defines avmTelemetryIdPrefix differently; review its source manually.')
    }

    $prefixPattern = $headPattern + [regex]::Escape($Metadata.telemetryIdPrefix) + '(?=\.)'
    $prefixMatches = [regex]::Matches($code, $prefixPattern)
    if ($prefixMatches.Count -ne 1) {
        throw [System.ArgumentException]::new('Expected one avmTelemetry deployment using the supplied telemetryIdPrefix; inspect this Bicep source before changing it.')
    }
    $prefixMatch = $prefixMatches[0]
    $prefixIndex = $prefixMatch.Index + $prefixMatch.Groups['head'].Length
    $content = $source.Substring(0, $prefixIndex) + $nameReference +
    $source.Substring($prefixIndex + $Metadata.telemetryIdPrefix.Length)
    $content = $content.Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n`n$declaration`n"
    return [pscustomobject]@{ Path = $sourcePath; Content = $content; Original = $source }
}
