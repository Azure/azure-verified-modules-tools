function Test-AvmBicepNestedPreflightRejection {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $DeploymentId,

        [AllowEmptyCollection()]
        [object[]] $Operations
    )

    Set-StrictMode -Version 3.0
    $matching = @($Operations | Where-Object {
            $_['targetResource'] -is [System.Collections.IDictionary] -and
            $_['targetResource']['id'] -is [string] -and $_['targetResource']['id'] -ieq $DeploymentId
        })
    if ($matching.Count -ne 1) { return $false }
    $operation = $matching[0]
    $target = $operation['targetResource']
    $status = $operation['statusMessage']
    $name = $DeploymentId.Split('/')[-1]
    if ($operation['provisioningOperation'] -cne 'Create' -or
        $operation['provisioningState'] -isnot [string] -or $operation['provisioningState'] -cne 'Failed' -or
        $operation['statusCode'] -isnot [string] -or $operation['statusCode'] -cnotin @('BadRequest', '400') -or
        $target['resourceType'] -isnot [string] -or $target['resourceType'] -ine 'Microsoft.Resources/deployments' -or
        $target['resourceName'] -isnot [string] -or $target['resourceName'] -cne $name -or
        $status -isnot [System.Collections.IDictionary] -or
        $status['status'] -isnot [string] -or $status['status'] -cne 'Failed') { return $false }
    $errorBody = $status['error']
    if ($errorBody -isnot [System.Collections.IDictionary] -or $errorBody['code'] -isnot [string] -or
        ($null -ne $errorBody['target'] -and ($errorBody['target'] -isnot [string] -or $errorBody['target'] -ine $DeploymentId)) -or
        $errorBody['details'] -isnot [System.Collections.IList] -or $errorBody['details'].Count -eq 0) { return $false }
    foreach ($detail in $errorBody['details']) {
        if ($detail -isnot [System.Collections.IDictionary] -or
            $detail['code'] -isnot [string] -or [string]::IsNullOrWhiteSpace($detail['code']) -or
            $detail['message'] -isnot [string] -or [string]::IsNullOrWhiteSpace($detail['message'])) { return $false }
    }
    $rejection = [System.Management.Automation.ErrorRecord]::new(
        [System.InvalidOperationException]::new('Nested preflight rejection.'), 'AvmBicepNestedPreflightRejected',
        [System.Management.Automation.ErrorCategory]::InvalidResult, $status)
    $rejection.ErrorDetails = [System.Management.Automation.ErrorDetails]::new(
        (ConvertTo-Json -InputObject $status -Depth 30 -Compress -WarningAction Stop))
    return Test-AvmBicepDeploymentPreflightRejection -ErrorRecord $rejection -DeploymentName $name
}
