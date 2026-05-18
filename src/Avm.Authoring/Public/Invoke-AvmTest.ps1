function Invoke-AvmTest {
    <#
    .SYNOPSIS
        Build/validate every source file in the resolved module under $Path.

    .DESCRIPTION
        Routes to the engine matching the module's ecosystem:

          - bicep      -> Invoke-AvmBicepTest      ('bicep build --stdout' per file)
          - terraform  -> Invoke-AvmTerraformTest  ('terraform validate -json' with auto-init)

        The ecosystem is determined by Get-AvmModuleContext, which honours
        the .avm/context.psd1 override file and the -Ecosystem filter.

        This verb covers the cheap, no-network build-validation pass. It is
        not the same as 'avm test unit' / 'avm test integration' / 'avm test
        e2e' which will live under nested dispatcher paths in later slices.

        Routed by the dispatcher: 'avm test'.

    .PARAMETER Path
        Working directory whose enclosing module to test. Defaults to the
        current location.

    .PARAMETER Ecosystem
        Force the ecosystem selector. Defaults to 'auto'.

    .PARAMETER AllowPathFallback
        When set, accept a PATH-resolved tool binary that self-reports the
        lock-pinned version.

    .PARAMETER NoInit
        Terraform-only: skip the auto 'terraform init -backend=false' step
        even when '.terraform/' is missing. Ignored for bicep contexts.

    .OUTPUTS
        pscustomobject from the engine: Engine, Tool, ToolPath, ToolSource,
        Status, FilesProcessed, Issues.

    .EXAMPLE
        avm test

    .EXAMPLE
        Invoke-AvmTest -Path C:\repos\my-module -Ecosystem bicep
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string] $Path = $PWD.Path,

        [ValidateSet('auto', 'bicep', 'terraform')]
        [string] $Ecosystem = 'auto',

        [switch] $AllowPathFallback,

        [switch] $NoInit
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $context = Get-AvmModuleContext -Path $Path -Ecosystem $Ecosystem

    switch ($context.Ecosystem) {
        'bicep' {
            $null = $NoInit  # -NoInit is terraform-only; harmless for bicep.
            Invoke-AvmBicepTest -Context $context -AllowPathFallback:$AllowPathFallback
        }
        'terraform' {
            Invoke-AvmTerraformTest -Context $context -AllowPathFallback:$AllowPathFallback -NoInit:$NoInit
        }
        default {
            throw [AvmContextException]::new(
                "Cannot test: unknown ecosystem '$($context.Ecosystem)'.")
        }
    }
}
