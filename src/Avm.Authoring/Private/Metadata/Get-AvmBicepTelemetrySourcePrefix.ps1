function Get-AvmBicepTelemetrySourcePrefix {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $sourcePath = Join-Path -Path $Path -ChildPath 'main.bicep'
    $source = Get-AvmBicepCommentFreeSource -Source (Get-Content -LiteralPath $sourcePath -Raw)
    if (-not [regex]::IsMatch($source, "(?m)^[\t ]*resource[\t ]+avmTelemetry[\t ]+'Microsoft\.Resources/deployments@")) {
        return $null
    }
    $head = "(?m)^[\t ]*resource[\t ]+avmTelemetry[\t ]+'Microsoft\.Resources/deployments@[^']+'[^\r\n]*\{\s*name[\t ]*:[\t ]*'"
    $prefixPattern = $head + '(?<prefix>46d3xbcp\.(?:resourcegraph-query|(?:res|ptn|utl)\.[a-z0-9_-]+))(?=\.)'
    $prefixMatches = [regex]::Matches($source, $prefixPattern)
    if ($prefixMatches.Count -ne 1) {
        throw [System.ArgumentException]::new(
            'Cannot identify one authored avmTelemetry prefix in main.bicep. Supply a matching telemetryIdPrefix or review its source before using -UpdateSource.')
    }
    return $prefixMatches[0].Groups['prefix'].Value
}
