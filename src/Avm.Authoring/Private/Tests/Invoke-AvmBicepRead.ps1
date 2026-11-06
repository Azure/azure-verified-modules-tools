function Invoke-AvmBicepRead {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock] $Read,

        [Parameter(Mandatory)]
        [string] $Activity,

        [switch] $RetryAuthorizationPropagation
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $readAction = $Read
    $retryActivity = $Activity
    $readPolicy = (Get-AvmBicepRetryPolicy)['reads']
    $propagationDeadline = if ($RetryAuthorizationPropagation) { (Get-Date -AsUTC).AddSeconds(60) } else { $null }
    $networkRead = {
        Invoke-AvmRetry -RetryActivity $retryActivity -RetryMaxAttempts $readPolicy['attempts'] `
            -RetryInitialDelaySeconds $readPolicy['initialDelaySeconds'] -RetryQuiet -RetryAction {
            try {
                if ($RetryAuthorizationPropagation -and (Get-Date -AsUTC) -ge $propagationDeadline) {
                    throw [AvmProcessException]::new('Authorization propagation read exceeded its deadline.')
                }
                $readResult = @(& $readAction)
                return $readResult
            }
            catch {
                $_.Exception.Data['AvmTransient'] = Test-AvmBicepRetryErrorRecord -ErrorRecord $_ -Kind MetadataTimeout
                throw
            }
        }
    }
    if ($RetryAuthorizationPropagation) {
        return Invoke-AvmBicepAuthorizationRead -Read $networkRead -DeadlineUtc $propagationDeadline
    }
    return & $networkRead
}
