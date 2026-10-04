function Invoke-AvmCheckConvention {
    <#
    .SYNOPSIS
        Run convention checks against the resolved module.

    .DESCRIPTION
        Routes to the engine matching the module's ecosystem:

          - bicep      -> first-party layout, version, changelog, test-source,
                          compiled ARM, checked-in JSON, workflow, and CODEOWNERS
                          checks; fails closed until registry parity
          - terraform  -> built-in AVM convention rules

        The ecosystem is determined by Get-AvmModuleContext, which honours
        the .avm/context.psd1 override file and the -Ecosystem filter.
        Bicep workflow checks require powershell-yaml 0.4.12, loaded only
        when a module workflow is inspected. Install it separately with
        Install-PSResource; missing or invalid YAML fails the check.

        Routed by the dispatcher: 'avm check convention'.

    .PARAMETER Path
        Working directory whose enclosing module to check. Defaults to
        the current location.

    .PARAMETER Ecosystem
        Force the ecosystem selector. Defaults to 'auto'.

    .PARAMETER AllowPathFallback
        When set, accept a PATH-resolved tool binary that self-reports the
        lock-pinned version.

    .PARAMETER Fix
        When set, rule primitives that declare a fix path apply it (e.g.
        renaming output.tf to outputs.tf, appending missing globs to
        .gitignore). Without -Fix the verb is check-only.

    .PARAMETER FixableOnly
        Evaluate only rules that declare a deterministic fix. Pre-commit uses
        this with -Fix; standalone checks and pr-check evaluate every rule.

    .OUTPUTS
        pscustomobject from the engine: Engine, Tool, ToolPath, ToolSource,
        Status, Issues.

    .EXAMPLE
        avm check convention

    .EXAMPLE
        Invoke-AvmCheckConvention -Path C:\repos\my-tf-module -Ecosystem terraform
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string] $Path = $PWD.Path,

        [ValidateSet('auto', 'bicep', 'terraform')]
        [string] $Ecosystem = 'auto',

        [switch] $AllowPathFallback,

        [switch] $Fix,

        [switch] $FixableOnly,

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck

    $context = Get-AvmModuleContextInternal -Path $Path -Ecosystem $Ecosystem

    switch ($context.Ecosystem) {
        'bicep' {
            Invoke-AvmBicepCheckConvention -Context $context -AllowPathFallback:$AllowPathFallback
        }
        'terraform' {
            Invoke-AvmTerraformCheckConvention `
                -Context $context `
                -AllowPathFallback:$AllowPathFallback `
                -Fix:$Fix `
                -FixableOnly:$FixableOnly
        }
        default {
            throw [AvmContextException]::new(
                "Cannot run convention check: unknown ecosystem '$($context.Ecosystem)'.")
        }
    }
}
