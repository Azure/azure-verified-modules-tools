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
        $status = Get-AvmBicepAzureErrorStatus -ErrorRecord $_
        if ($status -eq 404) {
            return $null
        }
        if ($status -eq 0 -and $Command -eq 'Get-AzResourceGroup' -and
            $Parameters.Count -eq 1 -and $Parameters['Name'] -is [string] -and
            $_.Exception.GetType() -eq [System.Exception] -and $null -eq $_.Exception.InnerException -and
            $_.CategoryInfo.Category -notin @(
                'AuthenticationError', 'PermissionDenied', 'SecurityError', 'ConnectionError',
                'OperationTimeout', 'InvalidArgument', 'InvalidData', 'InvalidResult', 'ParserError')) {
            # Verify only the SDK's unclassified named-group failure.
            $context = Get-AzContext -ErrorAction Stop
            $subscriptionId = Get-AvmPropertyValue -InputObject (
                Get-AvmPropertyValue -InputObject $context -Name 'Subscription') -Name 'Id'
            $groupId = '/subscriptions/{0}/resourceGroups/{1}' -f $subscriptionId, $Parameters['Name']
            $resource = ConvertTo-AvmBicepCleanupResource -ResourceIds @($groupId)
            if ($resource.type -ne 'Microsoft.Resources/resourceGroups') {
                throw [AvmConfigurationException]::new('A named resource-group lookup cannot target a child resource.')
            }
            $path = '/subscriptions/{0}/resourceGroups/{1}?api-version=2021-04-01' -f
            $subscriptionId, [uri]::EscapeDataString($Parameters['Name'])
            $verification = Invoke-AzRestMethod -Method GET -Path $path -ErrorAction Stop
            $verificationStatus = [int](Get-AvmPropertyValue -InputObject $verification -Name 'StatusCode')
            if ($verificationStatus -eq 404) {
                $content = [string](Get-AvmPropertyValue -InputObject $verification -Name 'Content')
                $document = ConvertFrom-Json -InputObject $content -AsHashtable -ErrorAction Stop
                $errorCode = Get-AvmPropertyValue -InputObject (
                    Get-AvmPropertyValue -InputObject $document -Name 'error') -Name 'code'
                if ($errorCode -ceq 'ResourceGroupNotFound') {
                    return $null
                }
            }
            if ($verificationStatus -ne 200) {
                throw [AvmProcessException]::new(
                    "Resource-group absence could not be confirmed for '$groupId' (HTTP $verificationStatus).")
            }
        }
        throw
    }
}
