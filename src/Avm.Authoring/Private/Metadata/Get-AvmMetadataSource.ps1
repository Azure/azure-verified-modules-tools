function Get-AvmMetadataSource {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,
        [Parameter(Mandatory)]
        [ValidateSet('bicep', 'terraform')]
        [string] $Ecosystem
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $prefixes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $types = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $unresolvedResource = $false
    $telemetryPresent = $false
    $literals = $null
    if ($Ecosystem -eq 'bicep') {
        $source = Get-Content -LiteralPath (Join-Path -Path $Path -ChildPath 'main.bicep') -Raw
        $literals = Get-AvmBicepMetadataLiteral -Source $source
        $literal = "'''[\s\S]*?'''|'(?:\\.|[^'\\\r\n])*'"
        $resource = "(?m)(?<resource>^[\t ]*resource[\t ]+(?<symbol>\w+)[\t ]+'(?<type>[^'@\r\n]+)@[^'\r\n]+'[\t ]*(?<existing>existing[\t ]+)?=)"
        $pattern = "$resource|/\*[\s\S]*?\*/|//[^\r\n]*|$literal"
        foreach ($token in [regex]::Matches($source, $pattern)) {
            if (-not $token.Groups['resource'].Success) {
                continue
            }
            if ($token.Groups['symbol'].Value -ceq 'avmTelemetry') {
                $telemetryPresent = $true
                $tail = Get-AvmBicepCommentFreeSource -Source $source.Substring($token.Index + $token.Length)
                $prefix = [regex]::Match($tail, "^\s*(?:if\s*\([^\r\n]*\)\s*)?\{\s*name\s*:\s*'(?<prefix>46d3xbcp\.(?:(?:res|ptn|utl)\.[a-z0-9_-]+|resourcegraph-query))\.")
                if ($prefix.Success) {
                    $null = $prefixes.Add($prefix.Groups['prefix'].Value)
                }
                continue
            }
            if ($token.Groups['existing'].Success) {
                continue
            }
            $type = $token.Groups['type'].Value
            if ($type -cmatch '^Microsoft\.[A-Z]\w+(/[a-zA-Z]\w*)+$') {
                $null = $types.Add($type)
            }
            else {
                $unresolvedResource = $true
            }
        }
    }
    else {
        foreach ($file in Get-ChildItem -LiteralPath $Path -Filter '*.tf' -File) {
            $source = Get-Content -LiteralPath $file.FullName -Raw
            if ($source.Contains('46d3xtrf', [System.StringComparison]::Ordinal)) {
                $telemetryPresent = $true
            }
            $pattern = '(?m)(?<assignment>^[\t ]*(?:avm_telemetry_id_prefix|telemetry_id_prefix)[\t ]*=[\t ]*"(?<prefix>46d3xtrf\.(?:res|ptn|utl)\.[a-z0-9_-]+)"[\t ]*(?=(?:#|//|$)))|/\*[\s\S]*?\*/|#[^\r\n]*|//[^\r\n]*|"(?:\\.|[^"\\])*"|<<-?(?<delimiter>[A-Za-z_]\w*)\r?\n[\s\S]*?^\s*\k<delimiter>[\t ]*\r?$'
            foreach ($token in [regex]::Matches($source, $pattern)) {
                if ($token.Groups['assignment'].Success) {
                    $null = $prefixes.Add($token.Groups['prefix'].Value)
                }
            }
        }
    }

    return [pscustomobject]@{
        Literals           = $literals
        CanonicalTypes     = @($types | Sort-Object -CaseSensitive)
        UnresolvedResource = $unresolvedResource
        TelemetryPresent   = $telemetryPresent
        TelemetryPrefixes  = @($prefixes | Sort-Object -CaseSensitive)
    }
}
