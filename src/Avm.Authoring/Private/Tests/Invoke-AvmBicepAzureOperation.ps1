function Test-AvmBicepAzureOperationCancellation {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [System.Exception] $Exception)

    if ($Exception -isnot [System.OperationCanceledException]) { return $false }
    if ($null -eq $Exception.InnerException) { return $true }
    return $Exception.InnerException -is [System.TimeoutException] -and $null -eq $Exception.InnerException.InnerException
}

function Invoke-AvmBicepAzureOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock] $Operation,
        [Parameter(Mandatory)] [string] $Activity
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            return & $Operation
        }
        catch [System.OperationCanceledException] {
            if ($attempt -eq 3 -or -not (Test-AvmBicepAzureOperationCancellation -Exception $_.Exception)) {
                throw
            }
            Write-AvmLog -Level Warning -Message "$Activity was canceled; retrying (attempt $($attempt + 1) of 3)."
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
}
