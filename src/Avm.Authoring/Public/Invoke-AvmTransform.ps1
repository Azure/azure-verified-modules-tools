function Invoke-AvmTransform {
    <#
    .SYNOPSIS
        Regenerate the module's README + test scaffolding from its source.

    .DESCRIPTION
        Routes to the engine matching the module's ecosystem:

          - bicep      -> Invoke-AvmBicepTransform      (Set-AVMModule.ps1 replacement; stubbed)
          - terraform  -> Invoke-AvmTerraformTransform  (mapotf transform + clean-backup; stubbed)

        Both engines are intentionally stubbed in this PoC slice so the
        public verb dispatcher and engine plumbing land first. The
        engines will throw AvmConfigurationException with a clear
        "next slice" message until the real implementations land.

        The ecosystem is determined by Get-AvmModuleContext, which honours
        the .avm/context.psd1 override file and the -Ecosystem filter.

        Routed by the dispatcher: 'avm transform'.

    .PARAMETER Path
        Working directory whose enclosing module to transform. Defaults to
        the current location.

    .PARAMETER Ecosystem
        Force the ecosystem selector. Defaults to 'auto'.

    .PARAMETER AllowPathFallback
        When set, accept a PATH-resolved tool binary that self-reports the
        lock-pinned version.

    .OUTPUTS
        pscustomobject from the engine: Engine, Tool, ToolPath, ToolSource,
        Status, FilesProcessed, Changed. (When implemented.)

    .EXAMPLE
        avm transform

    .EXAMPLE
        Invoke-AvmTransform -Path C:\repos\my-tf-module -Ecosystem terraform
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
            Invoke-AvmBicepTransform -Context $context -AllowPathFallback:$AllowPathFallback
        }
        'terraform' {
            Invoke-AvmTerraformTransform -Context $context -AllowPathFallback:$AllowPathFallback
        }
        default {
            throw [AvmContextException]::new(
                "Cannot transform: unknown ecosystem '$($context.Ecosystem)'.")
        }
    }
}
