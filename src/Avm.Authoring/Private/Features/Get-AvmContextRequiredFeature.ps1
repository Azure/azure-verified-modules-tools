function Get-AvmContextRequiredFeature {
    <#
    .SYNOPSIS
        Read the required Azure features for a module context.

    .DESCRIPTION
        Bicep modules inside a registry checkout (.../avm/res|ptn|utl/...) use the
        repository-root manifest entry for their exact module path; all other
        modules use the array manifest at their own root.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $scope = $null
    if ((Get-AvmPropertyValue -InputObject $Context -Name 'Ecosystem') -eq 'bicep') {
        $scope = Get-AvmBicepConventionScope -Path $Context.Root
    }
    if ($null -eq $scope) {
        return Read-AvmRequiredFeature -Root $Context.Root
    }
    $ignored = @(Get-ChildItem -LiteralPath $Context.Root -File -Force |
            Where-Object { $_.Name -ieq '.required-features.json' })
    if ($ignored.Count -gt 0) {
        throw [AvmConfigurationException]::new(
            "Bicep registry modules declare required features in the repository-root .required-features.json entry for '$($scope.ModuleRelativePath)'; remove the module-root manifest.")
    }
    return Read-AvmRequiredFeature -Root $scope.RepositoryRoot -ModulePath $scope.ModuleRelativePath
}
