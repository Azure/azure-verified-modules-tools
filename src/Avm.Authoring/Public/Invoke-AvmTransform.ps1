function Invoke-AvmTransform {
    <#
    .SYNOPSIS
        Regenerate the module's README + test scaffolding from its source.

    .DESCRIPTION
        Routes to the engine matching the module's ecosystem:

          - bicep      -> Invoke-AvmBicepTransform      (Set-AVMModule.ps1 replacement; stubbed)
          - terraform  -> Invoke-AvmTerraformTransform  (mapotf transform + clean-backup)

        The Terraform engine is wired against the pinned mapotf binary and
        the vendored config bundle (config/mapotf/pre-commit). The Bicep
        engine remains intentionally stubbed in this slice and throws
        AvmConfigurationException with a clear "next slice" message.

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

    .PARAMETER CheckDrift
        When set, the Terraform engine runs the transform but treats any
        file it changes as a failure (one Issue per changed file) instead of
        a silent fix. Used by the pr-check chain to flag modules that did not
        run pre-commit. Ignored by the Bicep engine.

    .OUTPUTS
        pscustomobject from the engine: Engine, Tool, ToolPath, ToolSource,
        Status, FilesProcessed, Changed, Issues.

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

        [switch] $AllowPathFallback,

        [switch] $CheckDrift
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $context = Get-AvmModuleContext -Path $Path -Ecosystem $Ecosystem

    switch ($context.Ecosystem) {
        'bicep' {
            Invoke-AvmBicepTransform -Context $context -AllowPathFallback:$AllowPathFallback
        }
        'terraform' {
            Invoke-AvmTerraformTransform -Context $context -AllowPathFallback:$AllowPathFallback -CheckDrift:$CheckDrift
        }
        default {
            throw [AvmContextException]::new(
                "Cannot transform: unknown ecosystem '$($context.Ecosystem)'.")
        }
    }
}
