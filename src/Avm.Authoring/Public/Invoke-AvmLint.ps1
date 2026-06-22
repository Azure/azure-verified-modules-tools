function Invoke-AvmLint {
    <#
    .SYNOPSIS
        Lint all source files in the resolved module under $Path.

    .DESCRIPTION
        Routes to the engine matching the module's ecosystem:

          - bicep      -> Invoke-AvmBicepLint     ('bicep lint <file>' per file)
          - terraform  -> Invoke-AvmTerraformLint ('tflint' - not yet wired)

        The ecosystem is determined by Get-AvmModuleContext, which honours
        the .avm/context.psd1 override file and the -Ecosystem filter.

        Returns an envelope with structured Issue records; callers should
        treat Status='fail' as a failed lint pass.

        Routed by the dispatcher: 'avm lint'.

    .PARAMETER Path
        Working directory whose enclosing module to lint. Defaults to the
        current location.

    .PARAMETER Ecosystem
        Force the ecosystem selector. Defaults to 'auto'.

    .PARAMETER AllowPathFallback
        When set, accept a PATH-resolved tool binary that self-reports the
        lock-pinned version.

    .OUTPUTS
        pscustomobject from the engine: Engine, Tool, ToolPath, ToolSource,
        Status, FilesProcessed, Issues.

    .EXAMPLE
        avm lint

    .EXAMPLE
        Invoke-AvmLint -Path C:\repos\my-module -Ecosystem bicep
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
            Invoke-AvmBicepLint -Context $context -AllowPathFallback:$AllowPathFallback
        }
        'terraform' {
            Invoke-AvmTerraformLint -Context $context -AllowPathFallback:$AllowPathFallback
        }
        default {
            throw [AvmContextException]::new(
                "Cannot lint: unknown ecosystem '$($context.Ecosystem)'.")
        }
    }
}
