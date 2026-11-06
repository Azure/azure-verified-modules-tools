function Invoke-AvmBicepAuthorizationRead {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [scriptblock] $Read,
        [ValidateScript({ $_.Kind -eq [System.DateTimeKind]::Utc })] [datetime] $DeadlineUtc,
        [System.Collections.IDictionary] $Policy,
        [string] $Activity,
        [string] $DiagnosticTarget
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if (-not $PSBoundParameters.ContainsKey('Policy')) { $Policy = Get-AvmBicepRetryPolicy }
    $propagation = $Policy['authorizationPropagation']
    $started = Get-Date -AsUTC
    $deadline = $started.AddSeconds($propagation['timeoutSeconds'])
    if ($PSBoundParameters.ContainsKey('DeadlineUtc') -and $DeadlineUtc -lt $deadline) { $deadline = $DeadlineUtc }
    $safeActivity = if ($Activity -ceq 'Read cleanup operation page') { 'cleanup operation page' } else { 'Azure read' }
    $target = 'unavailable'
    if (-not [string]::IsNullOrWhiteSpace($DiagnosticTarget)) {
        $targetText = $DiagnosticTarget.Split('?')[0].Split('#')[0].ToLowerInvariant()
        $target = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData(
                [System.Text.Encoding]::UTF8.GetBytes($targetText)))
    }
    $attempt = 0
    $reads = 0
    $matched = 0
    $unclassified = $false
    $outcome = 'interrupted'
    $lastStatus = 'unavailable'
    $lastRequestId = 'unavailable'
    try {
        for ($attempt = 1; $attempt -le $propagation['attempts']; $attempt++) {
            if ((Get-Date -AsUTC) -ge $deadline) {
                $outcome = 'deadline exceeded'
                throw [System.TimeoutException]::new('Authorization propagation read exceeded its deadline.')
            }
            $failure = $null
            $response = $null
            $lastStatus = 'unavailable'
            $lastRequestId = 'unavailable'
            try {
                $reads++
                $result = @(& $Read)
                if ($result.Count -eq 1) { $response = $result[0] }
                $retryable = $result.Count -eq 1 -and (Test-AvmBicepAuthorizationFailed -Response $response -Policy $Policy)
                if (-not $retryable) {
                    $status = Get-AvmPropertyValue -InputObject $response -Name 'StatusCode' -NoEnumerate
                    if (($status -is [int] -or $status -is [System.Net.HttpStatusCode]) -and
                        [int]$status -eq $propagation['statusCode']) { $unclassified = $true }
                    $outcome = if ($unclassified) { 'not retryable' } else { 'returned' }
                }
            }
            catch {
                $failure = $_
                if (-not (Test-AvmBicepAuthorizationFailed -ErrorRecord $failure -Policy $Policy)) {
                    $outcome = 'exception'
                    throw
                }
                $response = Get-AvmPropertyValue -InputObject $failure.Exception -Name 'Response' -NoEnumerate
                $retryable = $true
            }
            if ($retryable -or $matched -gt 0 -or $unclassified) {
                $status = Get-AvmPropertyValue -InputObject $response -Name 'StatusCode' -NoEnumerate
                if (($status -is [int] -or $status -is [System.Net.HttpStatusCode]) -and
                    [int]$status -ge 100 -and [int]$status -le 599) { $lastStatus = [string][int]$status }
                try {
                    $requestId = Get-AvmBicepResponseRequestId -Response $response
                    if ($requestId) { $lastRequestId = $requestId }
                }
                catch { $lastRequestId = 'unavailable' }
            }
            if (-not $retryable) {
                return $result
            }
            $matched++
            if ($matched -eq 1) {
                Write-AvmLog -Level Warning -WarningAction Continue -Message (
                    "Authorization read retry started: activity=$safeActivity; target-sha256=$target; " +
                    "HTTP $lastStatus; code=$($propagation['errorCode']); request-id=$lastRequestId.")
            }
            $remaining = ($deadline - (Get-Date -AsUTC)).TotalSeconds
            if ($attempt -eq $propagation['attempts'] -or $remaining -le 0) {
                $outcome = 'exhausted'
                if ($null -ne $failure) { throw $failure }
                return $result
            }
            Start-Sleep -Seconds ([math]::Min($propagation['pollIntervalSeconds'], $remaining))
            if ((Get-Date -AsUTC) -ge $deadline) {
                $outcome = 'exhausted'
                if ($null -ne $failure) { throw $failure }
                return $result
            }
        }
    }
    finally {
        if ($matched -gt 0 -or $unclassified) {
            $elapsed = [math]::Round(((Get-Date -AsUTC) - $started).TotalSeconds, 1)
            Write-AvmLog -Level Warning -WarningAction Continue -Message (
                "Authorization read finished: activity=$safeActivity; target-sha256=$target; " +
                "attempts=$reads; matched=$matched; elapsed-seconds=$elapsed; outcome=$outcome; " +
                "HTTP $lastStatus; request-id=$lastRequestId.")
        }
    }
}
