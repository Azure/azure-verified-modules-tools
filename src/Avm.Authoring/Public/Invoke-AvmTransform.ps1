function Invoke-AvmTransform {
    <#
    .SYNOPSIS
        Regenerate the module's README + test scaffolding from its source.

    .DESCRIPTION
        Routes to the engine matching the module's ecosystem:

          - bicep      -> Invoke-AvmBicepTransform      (Set-AVMModule.ps1 replacement; stubbed)
          - terraform  -> Invoke-AvmTerraformTransform  (mapotf transform + clean-backup)

        The Terraform engine is wired against the pinned mapotf binary and
        scoped config profiles under Resources/mapotf/{common,module,root}.
        A consumer repository can override a profile under
        config/mapotf/<profile> or set AVM_MPTF_CONFIG_DIR to a profile root.
        The Bicep engine remains intentionally stubbed in
        this slice and throws AvmConfigurationException with a clear "next
        slice" message.

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

    .PARAMETER ThrottleLimit
        Maximum number of independent Terraform root, module, or example
        targets to transform at once. Defaults to four. Ignored by Bicep.

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

        [switch] $CheckDrift,

        [ValidateRange(1, 32)]
        [int] $ThrottleLimit = 4,

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck

    $context = Get-AvmModuleContext -Path $Path -Ecosystem $Ecosystem

    switch ($context.Ecosystem) {
        'bicep' {
            Invoke-AvmBicepTransform -Context $context -AllowPathFallback:$AllowPathFallback
        }
        'terraform' {
            Invoke-AvmTerraformTransform `
                -Context $context `
                -AllowPathFallback:$AllowPathFallback `
                -CheckDrift:$CheckDrift `
                -ThrottleLimit $ThrottleLimit
        }
        default {
            throw [AvmContextException]::new(
                "Cannot transform: unknown ecosystem '$($context.Ecosystem)'.")
        }
    }
}
