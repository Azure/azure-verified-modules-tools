function Invoke-AvmCheckPolicy {
    <#
    .SYNOPSIS
        Run policy checks against the resolved module.

    .DESCRIPTION
        Routes to the engine matching the module's ecosystem:

          - bicep      -> Invoke-AvmBicepCheckPolicy      (PSRule.Rules.Azure; stubbed)
          - terraform  -> Invoke-AvmTerraformCheckPolicy  (Conftest with APRL + AVMSEC bundles; stubbed)

        Both engines are intentionally stubbed in this PoC slice so the
        public verb dispatcher and engine plumbing land first. The
        engines will throw AvmConfigurationException with a clear
        "next slice" message until the real implementations land.

        The ecosystem is determined by Get-AvmModuleContext, which honours
        the .avm/context.psd1 override file and the -Ecosystem filter.

        Routed by the dispatcher: 'avm check policy'.

    .PARAMETER Path
        Working directory whose enclosing module to check. Defaults to
        the current location.

    .PARAMETER Ecosystem
        Force the ecosystem selector. Defaults to 'auto'.

    .PARAMETER AllowPathFallback
        When set, accept a PATH-resolved tool binary that self-reports the
        lock-pinned version.

    .OUTPUTS
        pscustomobject from the engine: Engine, Tool, ToolPath, ToolSource,
        Status, Issues. (When implemented.)

    .EXAMPLE
        avm check policy

    .EXAMPLE
        Invoke-AvmCheckPolicy -Path C:\repos\my-bicep-module -Ecosystem bicep
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string] $Path = $PWD.Path,

        [ValidateSet('auto', 'bicep', 'terraform')]
        [string] $Ecosystem = 'auto',

        [switch] $AllowPathFallback
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $context = Get-AvmModuleContext -Path $Path -Ecosystem $Ecosystem

    switch ($context.Ecosystem) {
        'bicep' {
            Invoke-AvmBicepCheckPolicy -Context $context -AllowPathFallback:$AllowPathFallback
        }
        'terraform' {
            Invoke-AvmTerraformCheckPolicy -Context $context -AllowPathFallback:$AllowPathFallback
        }
        default {
            throw [AvmContextException]::new(
                "Cannot run policy check: unknown ecosystem '$($context.Ecosystem)'.")
        }
    }
}
