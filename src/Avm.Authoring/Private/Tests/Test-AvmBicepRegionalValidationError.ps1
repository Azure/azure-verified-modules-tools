function Test-AvmBicepRegionalValidationError {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord,

        [string] $SubscriptionId,
        [string] $ResourceLocation
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not (Test-AvmBicepRetryErrorRecord -ErrorRecord $ErrorRecord)) { return $false }
    $response = Get-AvmBicepErrorResponse -ErrorRecord $ErrorRecord
    if ($null -eq $response) { return $false }
    return Test-AvmBicepRetryErrorNode -Node $response -SubscriptionId $SubscriptionId -ResourceLocation $ResourceLocation
}
