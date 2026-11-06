function Invoke-AvmBicepAuthorizationRead {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [scriptblock] $Read,
        [ValidateScript({ $_.Kind -eq [System.DateTimeKind]::Utc })] [datetime] $DeadlineUtc,
        [System.Collections.IDictionary] $Policy
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if (-not $PSBoundParameters.ContainsKey('Policy')) { $Policy = Get-AvmBicepRetryPolicy }
    $propagation = $Policy['authorizationPropagation']
    $deadline = (Get-Date -AsUTC).AddSeconds($propagation['timeoutSeconds'])
    if ($PSBoundParameters.ContainsKey('DeadlineUtc') -and $DeadlineUtc -lt $deadline) { $deadline = $DeadlineUtc }
    for ($attempt = 1; $attempt -le $propagation['attempts']; $attempt++) {
        if ((Get-Date -AsUTC) -ge $deadline) {
            throw [System.TimeoutException]::new('Authorization propagation read exceeded its deadline.')
        }
        $failure = $null
        try {
            $result = @(& $Read)
            if ($result.Count -ne 1 -or -not (Test-AvmBicepAuthorizationFailed -Response $result[0] -Policy $Policy)) { return $result }
        }
        catch {
            $failure = $_
            if (-not (Test-AvmBicepAuthorizationFailed -ErrorRecord $failure -Policy $Policy)) { throw }
        }
        $remaining = ($deadline - (Get-Date -AsUTC)).TotalSeconds
        if ($attempt -eq $propagation['attempts'] -or $remaining -le 0) {
            if ($null -ne $failure) { throw $failure }
            return $result
        }
        Start-Sleep -Seconds ([math]::Min($propagation['pollIntervalSeconds'], $remaining))
        if ((Get-Date -AsUTC) -ge $deadline) {
            if ($null -ne $failure) { throw $failure }
            return $result
        }
    }
}
