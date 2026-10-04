function Test-AvmBicepDeploymentPreflightRejection {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord,

        [Parameter(Mandatory)]
        [string] $DeploymentName
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
        if ($null -ne $status -and [string]$status -notin @('400', 'BadRequest')) { return $false }
    }
    $response = $null
    $bodyProperty = $ErrorRecord.Exception.PSObject.Properties['Body']
    if ($null -ne $bodyProperty) { $response = $bodyProperty.Value }
    $message = Get-AvmPropertyValue -InputObject $ErrorRecord.ErrorDetails -Name 'Message'
    if ($message -is [string] -and -not [string]::IsNullOrWhiteSpace($message)) {
        try {
            $response = ConvertFrom-Json -InputObject $message -AsHashtable -NoEnumerate -ErrorAction Stop
        }
        catch [System.ArgumentException] { $response = $null }
    }
    else { $message = $ErrorRecord.Exception.Message }
    if ($null -eq $response) {
        $errorMatch = [regex]::Match($message, '^(?:\d{2}:\d{2}:\d{2} - )?Error: Code=(?<code>[^;]+); Message=(?<message>[\s\S]+)$')
        if (-not $errorMatch.Success) { return $false }
        $response = @{ code = $errorMatch.Groups['code'].Value; message = $errorMatch.Groups['message'].Value }
    }
    if ($response -is [array]) { return $false }
    $nested = Get-AvmPropertyValue -InputObject $response -Name 'error'
    if ($null -ne $nested) {
        if ($null -ne (Get-AvmPropertyValue -InputObject $response -Name 'code') -or
            $null -ne (Get-AvmPropertyValue -InputObject $response -Name 'message')) { return $false }
        $response = $nested
    }
    $code = Get-AvmPropertyValue -InputObject $response -Name 'code'
    $message = Get-AvmPropertyValue -InputObject $response -Name 'message'
    $expected = "The template deployment '$DeploymentName' is not valid according to the validation procedure."
    return $code -ceq 'InvalidTemplateDeployment' -and $message -is [string] -and
    $message.StartsWith($expected, [System.StringComparison]::Ordinal) -and
    $message.Contains('reported preflight validation errors.')
}
