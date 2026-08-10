function Get-AvmContextRootSignature {
    <#
    .SYNOPSIS
        Inspect source signatures directly at a candidate context root.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    Set-StrictMode -Version 3.0

    $terraformFiles = @(Get-ChildItem -LiteralPath $Path -Filter '*.tf' -File -ErrorAction Stop)
    $bicepFiles = @(Get-ChildItem -LiteralPath $Path -Filter '*.bicep' -File -ErrorAction Stop)
    $avmPath = Join-Path $Path 'avm'
    $hasBicepModuleFolders = @('res', 'ptn', 'utl') |
        Where-Object { Test-Path -LiteralPath (Join-Path $avmPath $_) -PathType Container } |
        Select-Object -First 1

    [pscustomobject]@{
        HasTerraformSource = $terraformFiles.Count -gt 0
        HasTerraformRoot   = Test-Path -LiteralPath (Join-Path $Path 'terraform.tf') -PathType Leaf
        HasBicepSource     = $bicepFiles.Count -gt 0
        HasBicepMonorepo   = (
            (Test-Path -LiteralPath (Join-Path $Path 'bicepconfig.json') -PathType Leaf) -and
            $null -ne $hasBicepModuleFolders
        )
    }
}
