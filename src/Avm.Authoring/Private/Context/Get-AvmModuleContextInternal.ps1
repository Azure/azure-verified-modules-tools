function Get-AvmModuleContextInternal {
    <#
    .SYNOPSIS
        Walk up the filesystem from $Path looking for the nearest Bicep or
        Terraform module/monorepo signature defined in the consolidation plan
        section 5. Throws AvmContextException when nothing matches.

    .DESCRIPTION
        Private helper used by the public Get-AvmModuleContext verb.

        Resolution order (highest precedence first):
          1. A committed .avm/context.psd1 override file anywhere up the
             tree from $Path (see Read-AvmContextOverride for the schema).
          2. Heuristic detection. Rules at each directory:
               a. Bicep monorepo root:   bicepconfig.json + avm/{res,ptn,utl}/
               b. Terraform module repo: terraform.tf + examples/ + tests/
               c. Bicep module path:     main.bicep + version.json
               d. Terraform module path: any *.tf + tests/

        The 'module path' rules can match anywhere inside a monorepo or repo;
        the 'repo' rules only match at the repo root. We walk upward from the
        starting directory once for each tier and prefer the more specific
        module-path match. When a bicep module sits inside a monorepo, the
        Scope field gets populated from 'avm/<scope>/<name>/'.

        $Ecosystem filters the heuristic phase: when set to 'bicep' or
        'terraform' we only consider rules in that ecosystem. The override
        file phase always runs regardless because the override is intended
        to be the final word on classification.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Path,

        [ValidateSet('auto', 'bicep', 'terraform')]
        [string] $Ecosystem = 'auto'
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not (Test-Path -LiteralPath $Path)) {
        throw [AvmContextException]::new("Path does not exist: $Path")
    }
    $start = (Resolve-Path -LiteralPath $Path).ProviderPath
    if ((Get-Item -LiteralPath $start).PSIsContainer -eq $false) {
        $start = Split-Path -Parent $start
    }

    # 1. Committed override file. Highest precedence.
    $override = Read-AvmContextOverride -Path $start
    if ($override) {
        if ($Ecosystem -ne 'auto' -and $override.Ecosystem -ne $Ecosystem) {
            throw [AvmContextException]::new(
                "Ecosystem '$Ecosystem' conflicts with .avm/context.psd1 at $($override.Root) which declares '$($override.Ecosystem)'.")
        }
        return $override
    }

    $tryBicep = $Ecosystem -in @('auto', 'bicep')
    $tryTerraform = $Ecosystem -in @('auto', 'terraform')

    # 2a. Try repo-root rules walking up from start.
    $dir = $start
    $rootHit = $null
    while ($dir) {
        if ($tryBicep) {
            $bicepCfg = Join-Path $dir 'bicepconfig.json'
            if (Test-Path -LiteralPath $bicepCfg) {
                foreach ($scope in @('res', 'ptn', 'utl')) {
                    $sub = Join-Path (Join-Path $dir 'avm') $scope
                    if (Test-Path -LiteralPath $sub -PathType Container) {
                        $rootHit = [pscustomobject][ordered]@{
                            Kind      = 'bicep-monorepo'
                            Root      = $dir
                            Ecosystem = 'bicep'
                            Scope     = $null
                            Owner     = $null
                        }
                        break
                    }
                }
            }
        }
        if (-not $rootHit -and $tryTerraform) {
            $tfRoot = Join-Path $dir 'terraform.tf'
            $exDir = Join-Path $dir 'examples'
            $teDir = Join-Path $dir 'tests'
            if ((Test-Path -LiteralPath $tfRoot) -and (Test-Path -LiteralPath $exDir -PathType Container) -and (Test-Path -LiteralPath $teDir -PathType Container)) {
                $rootHit = [pscustomobject][ordered]@{
                    Kind      = 'terraform-module-repo'
                    Root      = $dir
                    Ecosystem = 'terraform'
                    Scope     = $null
                    Owner     = $null
                }
            }
        }
        if ($rootHit) { break }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }

    # 2b. Try module-path rules walking up from start.
    $dir = $start
    $pathHit = $null
    while ($dir) {
        if ($tryBicep) {
            $mainBicep = Join-Path $dir 'main.bicep'
            $verJson = Join-Path $dir 'version.json'
            if ((Test-Path -LiteralPath $mainBicep) -and (Test-Path -LiteralPath $verJson)) {
                $pathHit = [pscustomobject][ordered]@{
                    Kind      = 'bicep-module'
                    Root      = $dir
                    Ecosystem = 'bicep'
                    Scope     = $null
                    Owner     = $null
                }
                break
            }
        }
        if ($tryTerraform) {
            $testsDir = Join-Path $dir 'tests'
            if (Test-Path -LiteralPath $testsDir -PathType Container) {
                $tfs = Get-ChildItem -LiteralPath $dir -Filter '*.tf' -File -ErrorAction SilentlyContinue
                if ($tfs) {
                    $pathHit = [pscustomobject][ordered]@{
                        Kind      = 'terraform-module-path'
                        Root      = $dir
                        Ecosystem = 'terraform'
                        Scope     = $null
                        Owner     = $null
                    }
                    break
                }
            }
        }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }

    # Scope detection: bicep module inside a monorepo.
    if ($pathHit -and $pathHit.Kind -eq 'bicep-module' -and $rootHit -and $rootHit.Kind -eq 'bicep-monorepo') {
        $rel = $pathHit.Root.Substring($rootHit.Root.Length).TrimStart([char]'/', [char]'\')
        $parts = $rel -split '[\\/]'
        if ($parts.Count -ge 3 -and $parts[0] -ceq 'avm' -and $parts[1] -in @('res', 'ptn', 'utl')) {
            $pathHit.Scope = $parts[1]
        }
    }

    # Resolution priority: module-path (more specific) over repo-root, EXCEPT
    # when both tiers match at the same directory. In that case the repo-root
    # classification is more specific (e.g. a Terraform module repo is also
    # technically a terraform-module-path, but the repo signature dominates).
    if ($pathHit -and $rootHit -and $pathHit.Root -eq $rootHit.Root) {
        return $rootHit
    }
    if ($pathHit) { return $pathHit }
    if ($rootHit) { return $rootHit }

    $hint = if ($Ecosystem -ne 'auto') { " (Ecosystem='$Ecosystem' filter applied)" } else { '' }
    throw [AvmContextException]::new(
        "No Bicep or Terraform module context found starting from '$start' upward$hint. " +
        "Expected one of: bicepconfig.json+avm/, terraform.tf+examples+tests, main.bicep+version.json, or *.tf+tests. " +
        "To override, place a .avm/context.psd1 file at the repo root.")
}
