function Get-AvmNetworkFailureKind {
    <#
    .SYNOPSIS
        Classify a failure as Cancelled, Transient or Permanent for retry purposes.
    .DESCRIPTION
        Walks the exception, its inner exceptions and any wrapped ErrorRecord.
        Cancellation is never retried. Typed AVM errors are permanent unless they
        carry a transient HTTP status or process output. Anything else is matched
        against the configured transient status codes and message patterns.
        Type checks use names so bootstrap scripts can dot-source this file
        without the module's exception classes.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [object] $ErrorRecord
    )

    Set-StrictMode -Version 3.0
    $policy = Get-AvmNetworkRetryPolicy

    $exception = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
    $chain = [System.Collections.Generic.List[System.Exception]]::new()
    $pending = [System.Collections.Generic.Queue[System.Exception]]::new()
    if ($exception -is [System.Exception]) { $pending.Enqueue($exception) }
    while ($pending.Count -gt 0 -and $chain.Count -lt 16) {
        $current = $pending.Dequeue()
        if ($chain.Contains($current)) { continue }
        $chain.Add($current)
        if ($null -ne $current.InnerException) { $pending.Enqueue($current.InnerException) }
        if ($current -is [System.Management.Automation.IContainsErrorRecord] -and
            $null -ne $current.ErrorRecord -and $null -ne $current.ErrorRecord.Exception) {
            $pending.Enqueue($current.ErrorRecord.Exception)
        }
    }

    $isType = {
        param([System.Exception] $Item, [string] $Name)
        for ($type = $Item.GetType(); $null -ne $type; $type = $type.BaseType) {
            if ($type.Name -eq $Name) { return $true }
        }
        return $false
    }

    foreach ($item in $chain) {
        if ($item -is [System.Management.Automation.PipelineStoppedException]) { return 'Cancelled' }
        if ($item -is [System.OperationCanceledException] -and $item.InnerException -isnot [System.TimeoutException]) {
            return 'Cancelled'
        }
    }

    $text = [System.Text.StringBuilder]::new()
    foreach ($item in $chain) {
        if ($item.Data.Contains('AvmTransient')) {
            return $(if ([bool]$item.Data['AvmTransient']) { 'Transient' } else { 'Permanent' })
        }

        if (& $isType $item 'AvmGitHubException') {
            if ($policy.TransientStatusCodes -contains [int]$item.StatusCode -or
                $item.Message -match '(?i)secondary rate limit') { return 'Transient' }
            return 'Permanent'
        }
        if (& $isType $item 'AvmProcessException') {
            [void]$text.AppendLine($item.Message).AppendLine([string]$item.StdErr).AppendLine([string]$item.StdOut)
            continue
        }
        if ((& $isType $item 'AvmException') -or $item -is [System.Security.Authentication.AuthenticationException]) {
            return 'Permanent'
        }

        if ($item.GetType().Name -eq 'HttpResponseException') {
            return $(if ($policy.TransientStatusCodes -contains [int]$item.Response.StatusCode) { 'Transient' } else { 'Permanent' })
        }
        if ($item -is [System.Net.Http.HttpRequestException]) {
            if ($null -ne $item.StatusCode) {
                return $(if ($policy.TransientStatusCodes -contains [int]$item.StatusCode) { 'Transient' } else { 'Permanent' })
            }
            if ($item.InnerException -is [System.Security.Authentication.AuthenticationException]) { return 'Permanent' }
            return 'Transient'
        }
        if ($item -is [System.Net.Sockets.SocketException] -or
            $item -is [System.TimeoutException] -or
            $item.GetType().Name -eq 'HttpIOException') {
            return 'Transient'
        }
        if ($item -is [System.Net.WebException]) {
            if ($null -ne $item.Response -and $policy.TransientStatusCodes -contains [int]$item.Response.StatusCode) { return 'Transient' }
            if ($item.Status -in @('ConnectFailure', 'NameResolutionFailure', 'ReceiveFailure', 'SendFailure',
                    'ConnectionClosed', 'KeepAliveFailure', 'Timeout', 'PipelineFailure', 'ProxyNameResolutionFailure')) {
                return 'Transient'
            }
        }
        [void]$text.AppendLine($item.Message)
    }

    # Tools wrap diagnostics across lines with colour codes and box-drawing borders.
    $normalized = $text.ToString() `
        -replace '\x1B\[[0-?]*[ -/]*[@-~]', '' `
        -replace '[\r\n\u2502]+', ' ' `
        -replace '\s+', ' '
    if ($policy.TransientMessagePattern.IsMatch($normalized)) { return 'Transient' }
    return 'Permanent'
}