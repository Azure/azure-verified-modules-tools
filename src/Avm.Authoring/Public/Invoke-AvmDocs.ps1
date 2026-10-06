function Invoke-AvmDocs {
    <#
    .SYNOPSIS
        Generate or refresh module documentation under $Path.

    .DESCRIPTION
        Routes to the engine matching the module's ecosystem:

          - bicep      -> Invoke-AvmBicepDocs      (Bicep docs + Scriban template)
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
        README path relative to a Terraform module. Bicep documentation
        always targets README.md in each source-bearing module.

    .PARAMETER CheckDrift
        Report-only mode used by pr-check. Any README that regeneration
        would change makes the result Status 'fail' and is emitted as an
        Issue, instead of being silently rewritten. Without it a CI run
        regenerates docs in the throwaway working copy and reports a pass,
        so stale READMEs merge unnoticed.

    .PARAMETER IncludeRenderedContent
        With Bicep and -CheckDrift, return generated README text and relative
        paths for independent raw-byte comparisons, without writing files.

    .PARAMETER SkipModuleVersionCheck
        Skip the PowerShell Gallery check that otherwise stops the command when a
        newer Avm.Authoring version is available. Writes a warning once.

    .OUTPUTS
        pscustomobject from the engine: Engine, Tool, ToolPath, ToolSource,
        Status, FilesProcessed, Changed, Issues. Bicep results also include
        FilesSelected and NotRendered.

    .EXAMPLE
        avm docs

    .EXAMPLE
        avm docs --check-drift
        # Fail instead of regenerating: what pr-check runs.

    .EXAMPLE
        Invoke-AvmDocs -Path C:\repos\my-tf-module -Ecosystem terraform
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
        Justification = 'The facade forwards WhatIf to the Bicep engine and explicitly refuses it for Terraform.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Noun mirrors the avm CLI verb (avm docs).')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string] $Path = $PWD.Path,

        [ValidateSet('auto', 'bicep', 'terraform')]
        [string] $Ecosystem = 'auto',

        [switch] $AllowPathFallback,

        [string] $OutputFile = 'README.md',

        [switch] $CheckDrift,

        [switch] $IncludeRenderedContent,

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck

    $context = Get-AvmModuleContextInternal -Path $Path -Ecosystem $Ecosystem

    switch ($context.Ecosystem) {
        'bicep' {
            Invoke-AvmBicepDocs -Context $context -AllowPathFallback:$AllowPathFallback `
                -OutputFile $OutputFile -CheckDrift:$CheckDrift `
                -IncludeRenderedContent:$IncludeRenderedContent -WhatIf:$WhatIfPreference
        }
        'terraform' {
            if ($IncludeRenderedContent) {
                throw [AvmConfigurationException]::new(
                    '-IncludeRenderedContent is available only for Bicep -CheckDrift.')
            }
            if ($WhatIfPreference) {
                throw [AvmConfigurationException]::new(
                    "Terraform documentation does not support -WhatIf; use -CheckDrift to compare without changing module files.")
            }
            Invoke-AvmTerraformDocs -Context $context -AllowPathFallback:$AllowPathFallback -OutputFile $OutputFile -CheckDrift:$CheckDrift
        }
        default {
            throw [AvmContextException]::new(
                "Cannot docs: unknown ecosystem '$($context.Ecosystem)'.")
        }
    }
}
