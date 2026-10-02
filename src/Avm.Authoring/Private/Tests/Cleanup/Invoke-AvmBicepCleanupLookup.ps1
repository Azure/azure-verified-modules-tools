function Invoke-AvmBicepCleanupLookup {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^Get-Az[A-Za-z]+$')]
        [string] $Command,

        [Parameter(Mandatory)]
        [hashtable] $Parameters
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $inputParameters = @{} + $Parameters
    $inputParameters.ErrorAction = 'Stop'
    try {
        & $Command @inputParameters
    }
    catch {
        if ((Get-AvmBicepAzureErrorStatus -ErrorRecord $_) -eq 404) {
            return $null
        }
        throw
    }
}
