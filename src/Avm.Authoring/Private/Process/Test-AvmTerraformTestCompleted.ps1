function Test-AvmTerraformTestCompleted {
    <#
    .SYNOPSIS
        Confirm a successful test attempt or a safely retryable failure.

    .DESCRIPTION
        Requires the selected test_abstract runs, terminal test_run events,
        test_file teardown then complete, and a matching test_summary.
        Cleanup diagnostics, interruptions, assertions, and unclassified errors
        veto replay. Terraform's test_retry event is in-run provider backoff,
        not a test failure. No Terraform state is inspected.

    .PARAMETER RetryableFailure
        Require a recognized capacity failure instead of a complete pass.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        $Result,

        [switch] $RetryableFailure
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $expectedExitCode = if ($RetryableFailure) { 1 } else { 0 }
    if ($Result.ExitCode -ne $expectedExitCode -or -not [string]::IsNullOrWhiteSpace($Result.StdErr)) {
        return $false
    }

    $files = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    $runs = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    $errors = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $fileErrors = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $cleanup = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $summary = $null
    $abstractSeen = $false

    foreach ($line in ([string]$Result.StdOut -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $entry = ConvertFrom-Json -InputObject $line -AsHashtable -ErrorAction Stop
        }
        catch [System.ArgumentException] {
            return $false
        }
        if ($entry -isnot [System.Collections.IDictionary] -or $entry['type'] -isnot [string] -or
            [string]::IsNullOrWhiteSpace($entry.type)) {
            return $false
        }
        if ([string]$entry['@message'] -match '\binterrupt(?:ed|s|ion)?\b') {
            return $false
        }
        if ($null -ne $summary) { return $false }

        switch ($entry.type) {
            'test_abstract' {
                if ($abstractSeen -or $entry['test_abstract'] -isnot [System.Collections.IDictionary]) { return $false }
                $abstractSeen = $true
                foreach ($path in $entry.test_abstract.Keys) {
                    if ([string]::IsNullOrWhiteSpace($path)) { return $false }
                    $files.Add($path, 'pending')
                    if ($entry.test_abstract[$path] -isnot [array]) { return $false }
                    foreach ($name in $entry.test_abstract[$path]) {
                        if ($name -isnot [string] -or -not $name) { return $false }
                        $key = "$path`0$name"
                        if ($runs.ContainsKey($key)) { return $false }
                        $runs.Add($key, 'pending')
                    }
                }
            }
            'test_file' {
                $file = $entry['test_file']
                if ($file -isnot [System.Collections.IDictionary] -or $file['path'] -isnot [string] -or -not $file.path -or
                    $file['progress'] -isnot [string] -or
                    -not $files.ContainsKey([string]$file.path)) { return $false }
                $previous = $files[$file.path]
                switch ($file.progress) {
                    'starting' {
                        if ($previous -ne 'pending') { return $false }
                    }
                    'teardown' {
                        if ($previous -ne 'starting') { return $false }
                    }
                    'complete' {
                        if ($previous -ne 'teardown' -or $file['status'] -notin @('pass', 'error', 'skip')) { return $false }
                        if (($file.status -eq 'error') -ne $fileErrors.Contains($file.path)) { return $false }
                    }
                    default { return $false }
                }
                $files[$file.path] = $file.progress
            }
            'test_run' {
                $run = $entry['test_run']
                if ($run -isnot [System.Collections.IDictionary] -or $run['path'] -isnot [string] -or
                    $run['run'] -isnot [string] -or -not $run.path -or -not $run.run -or
                    $run['progress'] -isnot [string]) { return $false }
                $key = "$($run.path)`0$($run.run)"
                if (-not $runs.ContainsKey($key)) { return $false }
                switch ($run.progress) {
                    'complete' {
                        if ($files[$run.path] -ne 'starting' -or $runs[$key] -ne 'pending' -or
                            $run['status'] -notin @('pass', 'error', 'skip')) { return $false }
                        $runs[$key] = $run.status
                    }
                    'teardown' { $null = $cleanup.Add($key) }
                    'starting' { }
                    'running' { }
                    default { return $false }
                }
            }
            'diagnostic' {
                $diagnostic = $entry['diagnostic']
                if ($diagnostic -isnot [System.Collections.IDictionary] -or $diagnostic['summary'] -isnot [string] -or
                    [string]::IsNullOrWhiteSpace($diagnostic.summary) -or
                    ($diagnostic.Contains('detail') -and $diagnostic.detail -isnot [string])) { return $false }
                if ($diagnostic.summary -match '^Incomplete (destroy|restore) plan$') { return $false }
                if ($diagnostic['severity'] -eq 'warning') { continue }
                if ($diagnostic['severity'] -ne 'error') { return $false }
                $path = [string]$entry['@testfile']
                $key = "$path`0$($entry['@testrun'])"
                if (-not $files.ContainsKey($path) -or $files[$path] -ne 'starting' -or
                    -not $runs.ContainsKey($key) -or $runs[$key] -ne 'error' -or $cleanup.Contains($key)) { return $false }

                $message = '{0} - {1}' -f $diagnostic.summary, $diagnostic['detail']
                if ($diagnostic.summary -match '\b(assertion|precondition|postcondition|validation|configuration|credentials|authentication|authorization|inconsistent|interrupted)\b|^(Invalid|Unsupported|Missing|Unknown|Duplicate|Incorrect|Reference to|Failed to load|Error in function call)\b' -or
                    $message -match '\b(AuthorizationFailed|LinkedAuthorizationFailed|DenyAssignmentAuthorizationFailed|AuthenticationFailed|InvalidAuthenticationToken|InvalidAuthenticationTokenTenant|AuthorizationPermissionMismatch|Unauthorized|AADSTS\d+|401)\b') {
                    return $false
                }
                $locationIneligible = ($message -match '\bRequestDisallowedByAzure\b') -and ($message -match '\baka\.ms/locationineligible\b')
                if ($message -match '\b(403|Forbidden|RequestDisallowedByAzure)\b' -and -not $locationIneligible) { return $false }
                if (-not $locationIneligible -and -not (Test-AvmTerraformTransientError -Output $message -BuiltInOnly)) {
                    return $false
                }
                $null = $errors.Add($key)
                $null = $fileErrors.Add($path)
            }
            'test_summary' {
                if ($entry['test_summary'] -isnot [System.Collections.IDictionary]) { return $false }
                $summary = $entry['test_summary']
                foreach ($name in @('passed', 'failed', 'errored', 'skipped')) {
                    if (($summary[$name] -isnot [int] -and $summary[$name] -isnot [long]) -or $summary[$name] -lt 0) { return $false }
                }
                if ($summary.failed -ne 0 -or
                    $files.Values -contains 'pending' -or $files.Values -contains 'starting' -or $files.Values -contains 'teardown') {
                    return $false
                }
                if ($RetryableFailure) {
                    if ($summary['status'] -ne 'error' -or $summary.errored -eq 0) { return $false }
                }
                elseif ($summary['status'] -ne 'pass' -or $summary.errored -ne 0 -or $summary.skipped -ne 0 -or $summary.passed -eq 0) {
                    return $false
                }
            }
            'test_cleanup' { return $false }
            'test_interrupt' { return $false }
            'test_retry' { continue }
            default {
                if ($entry['@level'] -eq 'error') { return $false }
            }
        }
    }

    if (-not $abstractSeen -or $files.Count -eq 0 -or $null -eq $summary -or
        $runs.Values -contains 'pending' -or $errors.Count -ne $summary.errored) { return $false }
    foreach ($pair in @{ pass = 'passed'; error = 'errored'; skip = 'skipped' }.GetEnumerator()) {
        if (@($runs.Values | Where-Object { $_ -eq $pair.Key }).Count -ne $summary[$pair.Value]) { return $false }
    }
    return $true
}
