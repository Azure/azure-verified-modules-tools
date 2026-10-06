function Get-AvmNetworkRetryPolicy {
    <#
    .SYNOPSIS
        Return the bounded retry policy for transient network failures.
    .DESCRIPTION
        Reads Resources/network.json once per session. AdvisoryMaxAttempts is the
        smaller budget for best-effort lookups that run on every command.
        AVM_NETWORK_RETRY_MAX_ATTEMPTS overrides the attempt count (1 disables
        retries, at most 10) and also caps the advisory budget. This file
        has no other module dependencies so bootstrap scripts can dot-source it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not (Get-Variable -Name AvmNetworkRetryPolicy -Scope Script -ErrorAction Ignore) -or
        $null -eq $script:AvmNetworkRetryPolicy) {
        $path = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath @('..', 'Resources', 'network.json')
        $document = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable
        $retry = $document['retry']
        $script:AvmNetworkRetryPolicy = [pscustomobject]@{
            MaxAttempts             = [int]$retry['maxAttempts']
            AdvisoryMaxAttempts     = [int]$retry['advisoryMaxAttempts']
            InitialDelaySeconds     = [double]$retry['initialDelaySeconds']
            MaxDelaySeconds         = [double]$retry['maxDelaySeconds']
            MaxRetryAfterSeconds    = [double]$retry['maxRetryAfterSeconds']
            TransientStatusCodes    = [int[]]@($document['transientHttpStatusCodes'])
            TransientMessagePattern = [regex]::new(
                '(?:' + (@($document['transientMessagePatterns']) -join ')|(?:') + ')',
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }
    }

    $policy = $script:AvmNetworkRetryPolicy
    $override = [Environment]::GetEnvironmentVariable('AVM_NETWORK_RETRY_MAX_ATTEMPTS')
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $attempts = 0
        if (-not [int]::TryParse($override, [ref]$attempts) -or $attempts -lt 1 -or $attempts -gt 10) {
            throw [System.ArgumentException]::new(
                "AVM_NETWORK_RETRY_MAX_ATTEMPTS must be an integer from 1 to 10; got '$override'.")
        }
        $policy = $policy.PSObject.Copy()
        $policy.MaxAttempts = $attempts
        $policy.AdvisoryMaxAttempts = [math]::Min($policy.AdvisoryMaxAttempts, $attempts)
    }
    return $policy
}
