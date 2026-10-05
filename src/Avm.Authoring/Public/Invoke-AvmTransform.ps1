function Invoke-AvmTransform {
    <#
    .SYNOPSIS
        Transform the module's authored source into governed artifacts.

    .DESCRIPTION
        Routes to the engine matching the module's ecosystem:

          - bicep      -> Invoke-AvmBicepTransform      (compiled main.json)
          - terraform  -> Invoke-AvmTerraformTransform  (mapotf transform + clean-backup)

        The Terraform engine is wired against the pinned mapotf binary and
        scoped config profiles under Resources/mapotf/{common,module,root,example}.
        Examples set enable_telemetry=var.enable_telemetry only when the called
        module declares that input. The example's input defaults to true,
        preserving an existing declaration's location and metadata or adding
        a missing declaration to variables.tf. Source-module defaults remain
        unchanged.
        A consumer repository can override a profile under
        config/mapotf/<profile> or set AVM_MPTF_CONFIG_DIR to a profile root.
        The Bicep engine compiles root and child main.bicep sources, including
        children under modules/, into main.json. README generation and
        repeatable test scaffolding remain separate follow-on slices.

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
        When set, compare generated artifacts without leaving module-file
        changes. Bicep compares build output directly; Terraform restores
        mapotf changes after detecting drift.

    .PARAMETER ThrottleLimit
        Maximum number of independent Terraform root, module, or example
        targets to transform at once. Defaults to four. Ignored by Bicep.

    .PARAMETER SkipModuleVersionCheck
        Skip the PowerShell Gallery check that otherwise stops the command when a
        newer Avm.Authoring version is available. Writes a warning once.

    .OUTPUTS
        pscustomobject from the engine: Engine, Tool, ToolPath, ToolSource,
        Status, FilesProcessed, Changed, Issues.

    .EXAMPLE
        avm transform

    .EXAMPLE
        Invoke-AvmTransform -Path C:\repos\my-tf-module -Ecosystem terraform
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'The Bicep and Terraform engines own ShouldProcess and receive the caller WhatIf preference.')]
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
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

    $context = Get-AvmModuleContextInternal -Path $Path -Ecosystem $Ecosystem

    switch ($context.Ecosystem) {
        'bicep' {
            Invoke-AvmBicepTransform -Context $context -AllowPathFallback:$AllowPathFallback -CheckDrift:$CheckDrift
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
