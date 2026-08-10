function Get-AvmModuleContext {
    <#
    .SYNOPSIS
        Classify a directory as a Bicep or Terraform module/monorepo context.

    .DESCRIPTION
        Treats -Path (default $PWD) as the authoritative module root and
        returns a context object the rest of the CLI consumes. Parent
        directories are never searched for module context.

        Resolution order (highest precedence first):
          1. A committed .avm/context.psd1 override at the authoritative root.
          2. Direct *.tf or *.bicep source files at that root.
          3. A Bicep monorepo root signature: bicepconfig.json plus at least
             one avm/{res,ptn,utl}/ directory.

        Terraform roots containing terraform.tf are classified as
        terraform-module-repo; other direct Terraform source roots are
        terraform-module-path. Direct Bicep source roots are bicep-module.
        Convention folders such as tests, examples and modules do not
        participate in detection.

        Known nested and administrative folders are rejected so source files
        inside them cannot become an accidental module root. When both direct
        ecosystems are present, automatic detection throws and an explicit
        -Ecosystem selection is required.

        Throws AvmContextException when nothing matches, or when an
        explicit -Ecosystem value conflicts with what was detected.

    .PARAMETER Path
        Authoritative module root. Defaults to the current location. This is
        the canonical --module override.

    .PARAMETER Ecosystem
        Force the ecosystem instead of auto-detecting. One of 'auto',
        'bicep' or 'terraform'. Defaults to 'auto'. Explicit selection resolves
        mixed-source roots only when matching source exists. This cannot
        override a committed same-root .avm/context.psd1; a conflict between
        -Ecosystem and the file throws AvmContextException.

    .PARAMETER Json
        Emit the result as a JSON document instead of a pscustomobject.

    .OUTPUTS
        pscustomobject with Kind, Root, Ecosystem, Scope, Owner.

    .EXAMPLE
        PS> Get-AvmModuleContext

    .EXAMPLE
        PS> avm context --ecosystem terraform ./my-module

    .EXAMPLE
        PS> avm context --json
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string] $Path,

        [ValidateSet('auto', 'bicep', 'terraform')]
        [string] $Ecosystem = 'auto',

        [switch] $Json,

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck

    if (-not $Path) {
        $Path = (Get-Location).ProviderPath
    }

    $ctx = Get-AvmModuleContextInternal -Path $Path -Ecosystem $Ecosystem

    if ($Json) {
        $ctx | ConvertTo-Json -Depth 3
    }
    else {
        $ctx
    }
}
