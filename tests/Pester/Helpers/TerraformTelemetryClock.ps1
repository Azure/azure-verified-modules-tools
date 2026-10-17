function New-TerraformTelemetryClockOverride {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Body)

    $options = [Text.RegularExpressions.RegexOptions]::CultureInvariant
    $timeout = [TimeSpan]::FromSeconds(1)
    $pattern = '(?s)\bapply_id\s*=\s*\{\s*type\s*=\s*"String"\s*value\s*=\s*(?<clock>plantimestamp\(\))\s*\}'
    $clockMatches = [regex]::Matches($Body, $pattern, $options, $timeout)
    if ($clockMatches.Count -ne 1 -or
        [regex]::Matches($Body, '\bplantimestamp\s*\(', $options, $timeout).Count -ne 1 -or
        $Body.Contains('qualification_plan_time', [StringComparison]::Ordinal)) {
        throw [InvalidOperationException]::new('The generated apply_id must have exactly one plantimestamp() clock expression and no existing qualification clock dependency.')
    }
    $clock = $clockMatches[0].Groups['clock']
    $rewritten = $Body.Remove($clock.Index, $clock.Length).Insert($clock.Index, 'var.qualification_plan_time')
    if ($rewritten.Replace('var.qualification_plan_time', 'plantimestamp()') -cne $Body) {
        throw [InvalidOperationException]::new('The qualification override changed more than the clock dependency.')
    }
    [ordered]@{
        resource = [ordered]@{
            azapi_resource = [ordered]@{
                telemetry = [ordered]@{
                    body = '${' + $rewritten + '}'
                }
            }
        }
    } | ConvertTo-Json -Depth 8 -Compress
}
