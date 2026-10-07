function Invoke-AvmBicepMetadataRead {
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
    Invoke-AvmRetry -RetryActivity $Activity -RetryMaxAttempts 3 -RetryInitialDelaySeconds 5 -RetryAction {
        try {
            $metadataResult = @(& $readAction)
            return $metadataResult
        }
        catch {
            $_.Exception.Data['AvmTransient'] = Test-AvmBicepRetryErrorRecord -ErrorRecord $_ -Kind MetadataTimeout
            throw
        }
    }
}
