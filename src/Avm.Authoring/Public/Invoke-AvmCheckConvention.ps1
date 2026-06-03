function Invoke-AvmCheckConvention {
    <#
    .SYNOPSIS
        Run convention checks against the resolved module.

    .DESCRIPTION
        Routes to the engine matching the module's ecosystem:

          - bicep      -> Invoke-AvmBicepCheckConvention      (compliance Pester suite a la module.tests.ps1; stubbed)
          - terraform  -> Invoke-AvmTerraformCheckConvention  ('grept run' against the AVM rule pack; stubbed)

        Both engines are intentionally stubbed in this PoC slice so the
        public verb dispatcher and engine plumbing land first. The
        engines will throw AvmConfigurationException with a clear
        "next slice" message until the real implementations land.

        The ecosystem is determined by Get-AvmModuleContext, which honours
        the .avm/context.psd1 override file and the -Ecosystem filter.

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

    .OUTPUTS
        pscustomobject from the engine: Engine, Tool, ToolPath, ToolSource,
        Status, Issues. (When implemented.)

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

        [switch] $Fix
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $context = Get-AvmModuleContext -Path $Path -Ecosystem $Ecosystem

    switch ($context.Ecosystem) {
        'bicep' {
            Invoke-AvmBicepCheckConvention -Context $context -AllowPathFallback:$AllowPathFallback
        }
        'terraform' {
            Invoke-AvmTerraformCheckConvention -Context $context -AllowPathFallback:$AllowPathFallback -Fix:$Fix
        }
        default {
            throw [AvmContextException]::new(
                "Cannot run convention check: unknown ecosystem '$($context.Ecosystem)'.")
        }
    }
}
