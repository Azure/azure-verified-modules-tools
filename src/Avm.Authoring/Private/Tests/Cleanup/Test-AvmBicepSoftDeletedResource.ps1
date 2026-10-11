function Test-AvmBicepSoftDeletedResource {
    <#
    .SYNOPSIS
        Returns whether a soft-deleted record still reserves the name of a removed resource.
    .DESCRIPTION
        Covers the resource types whose names stay reserved after deletion. Other types return false.
        Lookup failures propagate so an unknown answer never counts as free.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $ResourceId,

        [Parameter(Mandatory)]
        [string] $Type
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $segments = $ResourceId.Split('/')
    switch ($Type) {
        'Microsoft.KeyVault/vaults' {
            return @(Get-AzKeyVault -InRemovedState -ErrorAction Stop |
                    Where-Object { $_.ResourceId -ieq $ResourceId }).Count -gt 0
        }
        'Microsoft.CognitiveServices/accounts' {
            return @(Get-AzCognitiveServicesAccount -InRemovedState -ErrorAction Stop | Where-Object {
                    $_.AccountName -ieq $segments[-1] -and ($_.Id -ieq $ResourceId -or
                        $_.ResourceGroupName -ieq $segments[4] -or [string]::IsNullOrEmpty($_.ResourceGroupName))
                }).Count -gt 0
        }
        'Microsoft.AppConfiguration/configurationStores' {
            $path = "/subscriptions/$($segments[2])/providers/Microsoft.AppConfiguration/deletedConfigurationStores?api-version=2021-10-01-preview"
            return @(Get-AvmBicepCleanupRestCollection -Path $path |
                    Where-Object { $_.properties.configurationStoreId -ieq $ResourceId }).Count -gt 0
        }
        'Microsoft.ApiManagement/service' {
            $path = "/subscriptions/$($segments[2])/providers/Microsoft.ApiManagement/deletedservices?api-version=2021-08-01"
            return @(Get-AvmBicepCleanupRestCollection -Path $path |
                    Where-Object { $_.properties.serviceId -ieq $ResourceId }).Count -gt 0
        }
    }
    return $false
}
