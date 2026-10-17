function Get-AvmContextRequiredRegistration {
    <#
    .SYNOPSIS
        Read the required Azure features or providers for a module context.

    .DESCRIPTION
        Bicep modules inside a registry checkout (.../avm/res|ptn|utl/...) use the
        repository-root manifest entry for their exact module path; all other
        modules use the feature array manifest at their own root. Provider
        requirements only use the exact entry in the root registry map.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context,

        [ValidateSet('Feature', 'Provider')]
        [string] $Kind = 'Feature'
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $scope = $null
    if ((Get-AvmPropertyValue -InputObject $Context -Name 'Ecosystem') -eq 'bicep') {
        $scope = Get-AvmBicepConventionScope -Path $Context.Root
    }
    if ($null -eq $scope) {
        if ($Kind -eq 'Provider') {
            Write-AvmLog -Level Info -Message 'No Bicep registry module context; required provider registration is skipped.'
            return
        }
        return Read-AvmRequiredRegistration -Root $Context.Root -Kind $Kind
    }
    $ignored = @(Get-ChildItem -LiteralPath $Context.Root -File -Force |
            Where-Object { $_.Name -ieq '.required-features.json' })
    if ($Kind -eq 'Feature' -and $ignored.Count -gt 0) {
        throw [AvmConfigurationException]::new(
            "Bicep registry modules declare required features in the repository-root .required-features.json entry for '$($scope.ModuleRelativePath)'; remove the module-root manifest.")
    }
    return Read-AvmRequiredRegistration -Root $scope.RepositoryRoot -ModulePath $scope.ModuleRelativePath -Kind $Kind
}
