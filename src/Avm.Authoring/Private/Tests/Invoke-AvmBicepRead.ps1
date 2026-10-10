function Invoke-AvmBicepRead {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock] $Read,

        [Parameter(Mandatory)]
        [string] $Activity
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $readAction = $Read
    $readPolicy = (Get-AvmBicepRetryPolicy)['reads']
    Invoke-AvmRetry -RetryActivity $Activity -RetryMaxAttempts $readPolicy['attempts'] `
        -RetryInitialDelaySeconds $readPolicy['initialDelaySeconds'] -RetryQuiet -RetryAction {
        try {
            $readResult = @(& $readAction)
            return $readResult
        }
        catch {
            $_.Exception.Data['AvmTransient'] = Test-AvmBicepRetryErrorRecord -ErrorRecord $_ -Kind MetadataTimeout
            throw
        }
    }
}
