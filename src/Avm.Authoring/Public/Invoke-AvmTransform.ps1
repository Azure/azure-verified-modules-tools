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
        roots and Azure-resource children; utility roots that deploy no Azure
        resources are exempt. Local module calls forward missing
        location inputs and the parent's telemetry opt-out; supported example
        calls expose and forward the same controls. Only newly generated
        example location inputs default to "eastus"; new reusable-module
        inputs are required without defaults. Authored location declarations
        and per-item regions are preserved.

        Before telemetry migration, authored registry calls with older exact
        pins upgrade Regions to 0.13.0 and Interfaces to 0.9.0. Newer versions,
        custom sources and local module sources are not rewritten. Ambiguous
        version constraints require review. Legacy Azure/naming/azurerm calls
        become Azure/avm-utl-naming/azure 0.2.0 with legacy_mode = true,
        preserving labels, inputs, named outputs and the utility's state
        migration. Already-modern naming calls keep their authored mode.
        New utility locations use var.location rather than their own outputs;
        authored utility locations and opt-outs remain unchanged. Dependency
        constraints require Terraform 1.9 or later, below 2.0, for naming.

        Generated removed blocks let Terraform forget legacy modtm telemetry
        state without destroying its resources. Existing state may require
        the old providers for one final initialization. Test-module provider
        requirements and standard empty modtm test mocks are retired only
        when selected test targets no longer require ModTM. Unchanged
        dependencies retain correctly typed mocks, source requirements and
        explicit provider bindings; unrelated targets do not regain unused
        requirements. Complete same-provider alias bindings and literal local
        source-backed client defaults are preserved; unproven, computed or
        cross-provider bindings still require review. Mocked
        unit tests receive location values only for newly required inputs,
        preserving their assertions, targets and telemetry opt-outs.
        Fresh dependency inspection retires proven obsolete utility provider
        bindings without trusting stale installed module manifests. Genuine
        ModTM dependencies and non-telemetry Random use remain supported.
        Downloaded dependency source and unprefixed legacy telemetry are not
        rewritten.

        -WhatIf previews the Terraform transformation without changing files.
        A consumer repository can override a profile under
        config/mapotf/<profile> or set AVM_MPTF_CONFIG_DIR to a profile root.
        The Bicep engine compiles root and child main.bicep sources, including
        children under modules/, into main.json. Bicep README generation is
        handled separately by Invoke-AvmDocs.

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
