function Invoke-AvmTestUnit {
    <#
    .SYNOPSIS
        Run the module's Bicep Pester or Terraform unit-test tier.

    .DESCRIPTION
        For Bicep, runs module tests/unit/*.tests.ps1 only by default.
        Pester runs in a child PowerShell process and receives repoRootPath
        and moduleFolderPaths. -Recurse includes nested module scopes.
        -IncludeCompliance explicitly adds the registry's compliance
        module.tests.ps1 suite using the pinned Bicep binary; -CompliancePath
        selects an alternate suite and implies -IncludeCompliance. Compliance
        is not run twice by default when convention checks are enabled.

        For Terraform, runs 'terraform test' against tests/unit/ through
        Invoke-AvmTerraformTestSuite -Tier unit.

        Unlike the bare 'avm test' verb (which is the cheap, offline
        'terraform validate' build pass), this tier executes real
        'terraform test' HCL run blocks. A missing suite or a Pester filter
        matching no tests reports 'skipped' with zero runs, never a pass.
        Explicitly skipped Pester tests fail the tier.

        This is a standalone credential-free tier. The Terraform tier also
        runs in 'avm pr-check'. Bicep convention checks are separate; the
        existing registry CI remains authoritative until that work is
        complete and a cutover is approved.

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

    .PARAMETER IncludeCompliance
        Bicep-only: also run the registry compliance suite. This is an
        explicit transition option, not part of the default unit tier.

    .PARAMETER CompliancePath
        Bicep-only: explicit compliance Pester suite file. Relative paths
        resolve under -RepositoryRoot or the discovered repository root.
        Selecting a path enables compliance without -IncludeCompliance.

    .PARAMETER RepositoryRoot
        Bicep-only: override the registry root passed to compliance tests.

    .PARAMETER SkipModuleVersionCheck
        Skip the PowerShell Gallery check that otherwise stops the command when a
        newer Avm.Authoring version is available. Writes a warning once.

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

    .EXAMPLE
        avm test unit --include-compliance
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

        [switch] $IncludeCompliance,

        [string] $CompliancePath,

        [string] $RepositoryRoot,

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck

    $context = Get-AvmModuleContextInternal -Path $Path -Ecosystem $Ecosystem

    switch ($context.Ecosystem) {
        'bicep' {
            if ($NoInit) {
                throw [AvmConfigurationException]::new('-NoInit is only supported for Terraform unit tests.')
            }
            if ($PSBoundParameters.ContainsKey('CompliancePath') -and
                [string]::IsNullOrWhiteSpace($CompliancePath)) {
                throw [AvmConfigurationException]::new('-CompliancePath cannot be empty.')
            }
            Invoke-AvmBicepTestUnit -Context $context -AllowPathFallback:$AllowPathFallback `
                -Tag $Tag -TestName $TestName -Recurse:$Recurse `
                -IncludeCompliance:$IncludeCompliance -CompliancePath $CompliancePath `
                -RepositoryRoot $RepositoryRoot
        }
        'terraform' {
            if ($Tag.Count -gt 0 -or $TestName.Count -gt 0 -or $Recurse -or
                $IncludeCompliance -or $PSBoundParameters.ContainsKey('CompliancePath') -or
                -not [string]::IsNullOrWhiteSpace($RepositoryRoot)) {
                throw [AvmConfigurationException]::new(
                    '-Tag, -TestName, -Recurse, -IncludeCompliance, -CompliancePath and -RepositoryRoot are only supported for Bicep unit tests.')
            }
            Invoke-AvmTerraformTestSuite -Context $context -Tier 'unit' -AllowPathFallback:$AllowPathFallback -NoInit:$NoInit
        }
        default {
            throw [AvmContextException]::new(
                "Cannot run unit tests: unknown ecosystem '$($context.Ecosystem)'.")
        }
    }
}
