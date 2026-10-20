function Get-AvmPropertyValue {
    [CmdletBinding()]
    [OutputType([object], [object[]])]
    param(
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [switch] $NoEnumerate
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) {
            if ($NoEnumerate) { return , $InputObject[$Name] }
            return $InputObject[$Name]
        }
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    if ($NoEnumerate) { return , $property.Value }
    return $property.Value
}
