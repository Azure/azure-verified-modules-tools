function Invoke-AvmTransform {
    <#
    .SYNOPSIS
        Transform the module's authored source into governed artifacts.

    .DESCRIPTION
        Routes to the engine matching the module's ecosystem:

          - bicep      -> Invoke-AvmBicepTransform      (compiled main.json)
          - terraform  -> Invoke-AvmTerraformTransform  (mapotf transform + clean-backup)

        The Terraform engine is wired against the pinned mapotf binary and
        scoped config profiles under Resources/mapotf/. Instrumented roots
        and children get metadata-backed AzAPI deployment telemetry using
        var.location. Missing required location inputs are generated for
        roots and Azure-resource children. Local module calls forward missing
        location inputs and the parent's telemetry opt-out; supported example
        calls expose and forward the same controls. Test-module requirements and
        standard empty modtm test mocks are migrated. Existing authored
        variables keep their location and metadata when their defaults change.
        -WhatIf previews the Terraform transformation without changing files.
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
        Maximum number of independent Terraform root, module, example, or test
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
            $apply = $PSCmdlet.ShouldProcess($context.Root, 'Apply Terraform mapotf transforms')
            Invoke-AvmTerraformTransform `
                -Context $context `
                -AllowPathFallback:$AllowPathFallback `
                -CheckDrift:$CheckDrift `
                -ThrottleLimit $ThrottleLimit `
                -WhatIf:(-not $apply) `
                -Confirm:$false
        }
        default {
            throw [AvmContextException]::new(
                "Cannot transform: unknown ecosystem '$($context.Ecosystem)'.")
        }
    }
}
