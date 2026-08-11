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
    $items = @($Result)
    $singleStatus = if ($items.Count -eq 1) {
        ([string]$items[0].Status).ToLowerInvariant()
    }
    else {
        ''
    }
    $currentLevel = switch ($singleStatus) {
        'pass' { 'Pass' }
        'fail' { 'Fail' }
        'error' { 'Fail' }
        default { 'Info' }
    }

    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($index -gt 0 -and $lines[$index] -match '^\s+\[(?<status>pass|fail|error|skipped)\]') {
            $currentLevel = switch ($Matches.status) {
                'pass' { 'Pass' }
                'fail' { 'Fail' }
                'error' { 'Fail' }
                default { 'Info' }
            }
        }
        Write-AvmLog $lines[$index] -Level $currentLevel
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
