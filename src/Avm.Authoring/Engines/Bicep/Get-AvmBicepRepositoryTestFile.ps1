function Get-AvmBicepRepositoryTestFile {
    <#
    .SYNOPSIS
        List every regular main.test.bicep under a Bicep registry checkout.

    .OUTPUTS
        System.IO.FileInfo for each non-linked e2e test source. Filesystem errors propagate.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    Get-ChildItem -LiteralPath $RepositoryRoot -File -Recurse -Filter 'main.test.bicep' -ErrorAction Stop |
        Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) }
}
