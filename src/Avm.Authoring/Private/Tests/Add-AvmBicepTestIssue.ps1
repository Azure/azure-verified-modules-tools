function Add-AvmBicepTestIssue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]] $Issues,

        [Parameter(Mandatory)]
        [string] $File,

        [Parameter(Mandatory)]
        [string] $Code,

        [Parameter(Mandatory)]
        [string] $Message,

        [int] $Line = 0
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $Issues.Add([pscustomobject][ordered]@{
            File = $File; Line = $Line; Column = 0; Severity = 'error'
            Code = "avm.bicep.e2e-$Code"; Message = $Message
        })
}
