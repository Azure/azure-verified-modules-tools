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
    $policy = Get-AvmBicepRetryPolicy
    $readPolicy = $policy['reads']
    $propagationDeadline = if ($RetryAuthorizationPropagation) {
        (Get-Date -AsUTC).AddSeconds($policy['authorizationPropagation']['timeoutSeconds'])
    }
    else { $null }
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
        return Invoke-AvmBicepAuthorizationRead -Read $networkRead -DeadlineUtc $propagationDeadline -Policy $policy
    }
    return & $networkRead
}
