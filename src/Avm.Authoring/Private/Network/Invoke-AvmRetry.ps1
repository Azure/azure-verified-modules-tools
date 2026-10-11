function Invoke-AvmRetry {
    <#
    .SYNOPSIS
        Run an idempotent network action, retrying bounded transient failures.
    .DESCRIPTION
        Retries only failures classified as Transient by Get-AvmNetworkFailureKind,
        using exponential backoff with jitter capped by Resources/network.json and
        at least any server Retry-After delay. Cancellation and permanent errors
        are rethrown immediately. A Retry-After longer than the configured cap is
        not waited for. After the final attempt the original error is rethrown,
        unless it carries Data['AvmResult'], which is then returned so callers can
        report the last response themselves. Retry progress is written only to
        the verbose stream. After retries are exhausted, the original exception
        is preserved with a concise user-facing error detail. -RetryQuiet leaves
        the original error detail unchanged for advisory callers that report
        failure themselves.

        Only wrap reads or operations that are safe to repeat. Never wrap
        deployments, creates or other mutations whose outcome may be ambiguous.

        Locals use a retry prefix because the action runs in this function's
        dynamic scope and must still see the caller's variables.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock] $RetryAction,
        [Parameter(Mandatory)] [string] $RetryActivity,
        [int] $RetryMaxAttempts = 0,
        [double] $RetryInitialDelaySeconds = -1,
        [switch] $RetryQuiet
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $retryPolicy = Get-AvmNetworkRetryPolicy
    $retryLimit = if ($RetryMaxAttempts -gt 0) { $RetryMaxAttempts } else { $retryPolicy.MaxAttempts }
    $retryBaseDelay = if ($RetryInitialDelaySeconds -ge 0) { $RetryInitialDelaySeconds } else { $retryPolicy.InitialDelaySeconds }

    for ($retryAttempt = 1; ; $retryAttempt++) {
        try {
            return & $RetryAction
        }
        catch {
            $retryError = $_
            $retryKind = Get-AvmNetworkFailureKind -ErrorRecord $retryError
            if ($retryKind -ne 'Transient') { throw }

            $retryAfter = Get-AvmRetryAfterDelay -ErrorRecord $retryError
            $retryTooLong = $null -ne $retryAfter -and $retryAfter -gt $retryPolicy.MaxRetryAfterSeconds
            if ($retryAttempt -ge $retryLimit -or $retryTooLong) {
                $retryReason = if ($retryTooLong) { "server asked to wait $([math]::Round($retryAfter))s, above the $($retryPolicy.MaxRetryAfterSeconds)s limit" } else { "$retryAttempt attempts" }
                Write-Verbose ("{0} failed after {1}: {2}" -f $RetryActivity, $retryReason, $retryError.Exception.Message)
                if ($retryError.Exception.Data.Contains('AvmResult')) { return $retryError.Exception.Data['AvmResult'] }
                if (-not $RetryQuiet) {
                    $retryError.ErrorDetails = [System.Management.Automation.ErrorDetails]::new(
                        (Get-AvmRetryFailureMessage -Activity $RetryActivity -ErrorRecord $retryError -Attempts $retryAttempt))
                }
                throw $retryError
            }

            $retryCap = [math]::Min($retryPolicy.MaxDelaySeconds, $retryBaseDelay * [math]::Pow(2, $retryAttempt - 1))
            $retryDelay = ($retryCap / 2) + (Get-Random -Minimum 0.0 -Maximum ([math]::Max($retryCap / 2, 0.001)))
            if ($null -ne $retryAfter) { $retryDelay = [math]::Max($retryDelay, $retryAfter) }
            $retryMessage = "{0} hit a transient failure (attempt {1} of {2}); retrying in {3:0.#}s: {4}" -f
            $RetryActivity, $retryAttempt, $retryLimit, $retryDelay, $retryError.Exception.Message
            Write-Verbose $retryMessage
            Wait-AvmRetryDelay -Seconds $retryDelay
        }
    }
}