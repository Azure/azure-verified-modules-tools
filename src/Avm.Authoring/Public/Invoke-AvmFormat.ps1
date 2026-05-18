function Invoke-AvmFormat {
    <#
    .SYNOPSIS
        Format all source files in the resolved module under $Path.

    .DESCRIPTION
        Routes to the engine matching the module's ecosystem:

          - bicep      -> Format-AvmBicepModule (bicep format)
          - terraform  -> Format-AvmTerraformModule (terraform fmt -recursive)

        The ecosystem is determined by Get-AvmModuleContext, which honours
        the .avm/context.psd1 override file and the -Ecosystem filter.

        The required tool binary (bicep or terraform) is resolved against
        the bundled tools.lock; install missing tools beforehand with
        'avm tool install bicep' / 'avm tool install terraform'.

        Routed by the dispatcher: 'avm format'.

    .PARAMETER Path
        Working directory whose enclosing module to format. Defaults to
        the current location.

    .PARAMETER Ecosystem
        Force the ecosystem selector to 'bicep' or 'terraform' regardless
        of heuristics. Defaults to 'auto'.

    .PARAMETER AllowPathFallback
        When set, accept a PATH-resolved tool binary that self-reports the
        lock-pinned version. Off by default; production callers usually
        want only the managed cache.

    .OUTPUTS
        pscustomobject from the engine: Engine, Tool, ToolPath, ToolSource,
        FilesProcessed, Changed.

    .EXAMPLE
        avm format
        # Detect ecosystem from the current directory and format every
        # source file under the module root.

    .EXAMPLE
        Invoke-AvmFormat -Path C:\repos\my-module -Ecosystem bicep

    .EXAMPLE
        avm format --allow-path-fallback
        # Use bicep / terraform from the host PATH when the managed cache
        # is empty (useful in tightly-controlled CI images).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
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

    if (-not $PSCmdlet.ShouldProcess($context.Root, "Format $($context.Ecosystem) module sources")) {
        return
    }

    switch ($context.Ecosystem) {
        'bicep' {
            Format-AvmBicepModule -Context $context -AllowPathFallback:$AllowPathFallback
        }
        'terraform' {
            Format-AvmTerraformModule -Context $context -AllowPathFallback:$AllowPathFallback
        }
        default {
            throw [AvmContextException]::new(
                "Cannot format: unknown ecosystem '$($context.Ecosystem)'.")
        }
    }
}
