function Invoke-AvmBicepAuthorizationRead {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [scriptblock] $Read,
        [ValidateScript({ $_.Kind -eq [System.DateTimeKind]::Utc })] [datetime] $DeadlineUtc
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $deadline = (Get-Date -AsUTC).AddSeconds(60)
    if ($PSBoundParameters.ContainsKey('DeadlineUtc') -and $DeadlineUtc -lt $deadline) { $deadline = $DeadlineUtc }
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        if ((Get-Date -AsUTC) -ge $deadline) {
            throw [System.TimeoutException]::new('Authorization propagation read exceeded its deadline.')
        }
        $failure = $null
        try {
            $result = @(& $Read)
            if ($result.Count -ne 1 -or -not (Test-AvmBicepAuthorizationFailed -Response $result[0])) { return $result }
        }
        catch {
            $failure = $_
            if (-not (Test-AvmBicepAuthorizationFailed -ErrorRecord $failure)) { throw }
        }
        $remaining = ($deadline - (Get-Date -AsUTC)).TotalSeconds
        if ($attempt -eq 12 -or $remaining -le 0) {
            if ($null -ne $failure) { throw $failure }
            return $result
        }
        Start-Sleep -Seconds ([math]::Min(5, $remaining))
        if ((Get-Date -AsUTC) -ge $deadline) {
            if ($null -ne $failure) { throw $failure }
            return $result
        }
    }
}
