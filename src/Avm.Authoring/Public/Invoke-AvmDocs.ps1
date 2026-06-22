function Invoke-AvmDocs {
    <#
    .SYNOPSIS
        Generate or refresh module documentation under $Path.

    .DESCRIPTION
        Routes to the engine matching the module's ecosystem:

          - bicep      -> Invoke-AvmBicepDocs      (ARM-JSON walker; stubbed)
          - terraform  -> Invoke-AvmTerraformDocs  ('terraform-docs markdown table' inject mode)

        The ecosystem is determined by Get-AvmModuleContext, which honours
        the .avm/context.psd1 override file and the -Ecosystem filter.

        Routed by the dispatcher: 'avm docs'.

    .PARAMETER Path
        Working directory whose enclosing module to document. Defaults to
        the current location.

    .PARAMETER Ecosystem
        Force the ecosystem selector. Defaults to 'auto'.

    .PARAMETER AllowPathFallback
        When set, accept a PATH-resolved tool binary that self-reports the
        lock-pinned version.

    .PARAMETER OutputFile
        README path (relative to module root) to inject into. Defaults to
        'README.md'.

    .OUTPUTS
        pscustomobject from the engine: Engine, Tool, ToolPath, ToolSource,
        Status, FilesProcessed, Changed.

    .EXAMPLE
        avm docs

    .EXAMPLE
        Invoke-AvmDocs -Path C:\repos\my-tf-module -Ecosystem terraform
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Noun mirrors the avm CLI verb (avm docs).')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string] $Path = $PWD.Path,

        [ValidateSet('auto', 'bicep', 'terraform')]
        [string] $Ecosystem = 'auto',

        [switch] $AllowPathFallback,

        [string] $OutputFile = 'README.md'
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $context = Get-AvmModuleContext -Path $Path -Ecosystem $Ecosystem

    switch ($context.Ecosystem) {
        'bicep' {
            Invoke-AvmBicepDocs -Context $context -AllowPathFallback:$AllowPathFallback -OutputFile $OutputFile
        }
        'terraform' {
            Invoke-AvmTerraformDocs -Context $context -AllowPathFallback:$AllowPathFallback -OutputFile $OutputFile
        }
        default {
            throw [AvmContextException]::new(
                "Cannot docs: unknown ecosystem '$($context.Ecosystem)'.")
        }
    }
}
