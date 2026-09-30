function Invoke-AvmTestUnit {
    <#
    .SYNOPSIS
        Run the module's Bicep Pester or Terraform unit-test tier.

    .DESCRIPTION
        For Bicep, runs tests/unit/*.tests.ps1 and, when available, the
        registry's compliance module.tests.ps1 suite. Pester runs in a child
        PowerShell process and receives repoRootPath and moduleFolderPaths,
        as in Test-ModuleLocally. The compliance suite uses the pinned Bicep
        binary. -Recurse includes nested module scopes. A standalone module
        without the registry's compliance suite runs only its own unit tests;
        ComplianceFile is null in the result. -CompliancePath selects an
        external suite explicitly.

        For Terraform, runs 'terraform test' against tests/unit/ through
        Invoke-AvmTerraformTestSuite -Tier unit.

        Unlike the bare 'avm test' verb (which is the cheap, offline
        'terraform validate' build pass), this tier executes real
        'terraform test' HCL run blocks. A missing suite or a Pester filter
        matching no tests reports 'skipped' with zero runs, never a pass.
        Explicitly skipped Pester tests fail the tier.

        This is a standalone credential-free tier. The Terraform tier also
        runs in 'avm pr-check'; Bicep compliance is not yet wired into
        'avm pr-check' or 'avm check convention'.

        Routed by the dispatcher: 'avm test unit'.

    .PARAMETER Path
        Working directory whose enclosing module to test. Defaults to the
        current location.

    .PARAMETER Ecosystem
        Force the ecosystem selector. Defaults to 'auto'.

    .PARAMETER AllowPathFallback
        When set, accept a PATH-resolved tool binary that self-reports the
        lock-pinned version.

    .PARAMETER NoInit
        Terraform-only: skip the automatic terraform init step.

    .PARAMETER Tag
        Bicep-only Pester tag filter. Alias: PesterTag.

    .PARAMETER TestName
        Bicep-only Pester full-name filter (supports Pester wildcards).

    .PARAMETER Recurse
        Bicep-only: include child module scopes and their unit tests.

    .PARAMETER CompliancePath
        Bicep-only: explicit compliance Pester suite file. Relative paths
        resolve under -RepositoryRoot or the discovered repository root.

    .PARAMETER RepositoryRoot
        Bicep-only: override the registry root passed to compliance tests.

    .OUTPUTS
        pscustomobject from the engine: Engine, Tool, ToolPath, ToolSource,
        Status, FilesProcessed, RunsTotal, RunsPassed, RunsFailed, Issues.
        Bicep also reports RunsSkipped, RunsInconclusive, RunsFiltered, UnitFiles,
        ComplianceFile and ModuleScopes.

    .EXAMPLE
        avm test unit

    .EXAMPLE
        Invoke-AvmTestUnit -Path C:\repos\terraform-azurerm-avm-res-foo

    .EXAMPLE
        avm test unit --ecosystem bicep --tag UDT --recurse
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string] $Path = $PWD.Path,

        [ValidateSet('auto', 'bicep', 'terraform')]
        [string] $Ecosystem = 'auto',

        [switch] $AllowPathFallback,

        [switch] $NoInit,

        [Alias('PesterTag', 'PesterTags')]
        [AllowEmptyCollection()]
        [string[]] $Tag = @(),

        [AllowEmptyCollection()]
        [string[]] $TestName = @(),

        [Alias('PesterTestRecurse')]
        [switch] $Recurse,

        [string] $CompliancePath,

        [string] $RepositoryRoot,

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck

    $context = Get-AvmModuleContext -Path $Path -Ecosystem $Ecosystem

    switch ($context.Ecosystem) {
        'bicep' {
            if ($NoInit) {
                throw [AvmConfigurationException]::new('-NoInit is only supported for Terraform unit tests.')
            }
            Invoke-AvmBicepTestUnit -Context $context -AllowPathFallback:$AllowPathFallback `
                -Tag $Tag -TestName $TestName -Recurse:$Recurse `
                -CompliancePath $CompliancePath -RepositoryRoot $RepositoryRoot
        }
        'terraform' {
            if ($Tag.Count -gt 0 -or $TestName.Count -gt 0 -or $Recurse -or
                -not [string]::IsNullOrWhiteSpace($CompliancePath) -or
                -not [string]::IsNullOrWhiteSpace($RepositoryRoot)) {
                throw [AvmConfigurationException]::new(
                    '-Tag, -TestName, -Recurse, -CompliancePath and -RepositoryRoot are only supported for Bicep unit tests.')
            }
            Invoke-AvmTerraformTestSuite -Context $context -Tier 'unit' -AllowPathFallback:$AllowPathFallback -NoInit:$NoInit
        }
        default {
            throw [AvmContextException]::new(
                "Cannot run unit tests: unknown ecosystem '$($context.Ecosystem)'.")
        }
    }
}
