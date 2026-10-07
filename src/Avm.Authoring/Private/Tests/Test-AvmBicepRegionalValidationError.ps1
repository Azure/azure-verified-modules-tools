function Test-AvmBicepRegionalValidationError {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($ErrorRecord.CategoryInfo.Category -in @('AuthenticationError', 'PermissionDenied', 'SecurityError', 'OperationStopped') -or
        (Get-AvmBicepDeploymentErrorKind -ErrorRecord $ErrorRecord) -ne 'Other') { return $false }
    for ($exception = $ErrorRecord.Exception; $null -ne $exception; $exception = $exception.InnerException) {
        if ($exception -is [System.UnauthorizedAccessException]) { return $false }
        $response = Get-AvmPropertyValue -InputObject $exception -Name 'Response'
        $status = Get-AvmPropertyValue -InputObject $response -Name 'StatusCode'
        if ($null -eq $status) { $status = Get-AvmPropertyValue -InputObject $exception -Name 'StatusCode' }
        if ($null -ne $status -and [string]$status -notin @('400', '409', '503', 'BadRequest', 'Conflict', 'ServiceUnavailable')) {
            return $false
        }
    }
    $response = Get-AvmBicepErrorResponse -ErrorRecord $ErrorRecord
    if ($null -eq $response) { return $false }
    return Test-AvmBicepRegionalErrorNode -Node $response
}
