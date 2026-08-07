function Write-AvmResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Result,

        [Parameter(Mandatory)]
        [string] $Verb
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $lines = @(ConvertTo-AvmResultLine -Result $Result -Verb $Verb)
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $level = if ($index -eq 0 -and @($Result).Count -eq 1 -and [string]$Result[0].Status -eq 'pass') {
            'Pass'
        }
        else {
            'Info'
        }
        Write-AvmLog $lines[$index] -Level $level
    }

    if ([string]::IsNullOrWhiteSpace($env:GITHUB_ACTIONS)) {
        return
    }
    if ([string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        Write-AvmLog 'GITHUB_ACTIONS is set but GITHUB_STEP_SUMMARY is unavailable.' -Level Warning
        return
    }

    $summary = [System.Collections.Generic.List[string]]::new()
    $summary.Add(('## `avm {0}`' -f $Verb))
    $summary.Add('')
    $summary.Add('```text')
    foreach ($line in $lines) {
        $summary.Add($line)
    }
    $summary.Add('```')
    $summary.Add('')
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ($summary -join "`n") -Encoding utf8
}
