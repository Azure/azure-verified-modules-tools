function Get-AvmModuleContext {
    <#
    .SYNOPSIS
        Classify a directory as a Bicep or Terraform module/monorepo context.

    .DESCRIPTION
        Walks the filesystem upward from -Path (default $PWD) looking for the
        nearest signature of a known AVM-style repo or module layout, and
        returns a context object the rest of the CLI consumes.

        Resolution order (highest precedence first):
          1. A committed .avm/context.psd1 override file anywhere up the
             tree. The file is a PowerShell data file with Ecosystem and
             Kind keys; the file's directory becomes Root. Use this when a
             repo's on-disk layout does not match the default heuristics or
             when contributors need a stable, audit-friendly classification.
          2. Heuristic detection (from the consolidation plan section 5):
               - bicep-monorepo:        bicepconfig.json + avm/{res,ptn,utl}/ dirs.
               - bicep-module:          main.bicep + version.json.
               - terraform-module-repo: terraform.tf + examples/ + tests/.
               - terraform-module-path: any *.tf file + tests/ directory.

        Module-path matches take priority over repo-root matches because they
        are more specific. When a bicep module sits inside a monorepo, the
        'Scope' field is populated with 'res', 'ptn' or 'utl' parsed from the
        path under avm/.

        Throws AvmContextException when nothing matches, or when an
        explicit -Ecosystem value conflicts with what was detected.

    .PARAMETER Path
        Directory to start the walk from. Defaults to the current location.
        This is the canonical --module override.

    .PARAMETER Ecosystem
        Force the ecosystem instead of auto-detecting. One of 'auto',
        'bicep' or 'terraform'. Defaults to 'auto'. Overrides the heuristic
        but cannot override a committed .avm/context.psd1; a conflict
        between -Ecosystem and the file throws AvmContextException so
        contributors notice the disagreement instead of silently picking one.

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

        [switch] $Json
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

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
