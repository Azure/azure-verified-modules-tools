function Read-AvmContextOverride {
    <#
    .SYNOPSIS
        Find and parse a committed .avm/context.psd1 override.

    .DESCRIPTION
        Walks upward from $Path looking for a .avm/context.psd1 file. When
        found, parses it as a PowerShell data file and validates the
        contents against the ModuleContext schema. Returns a pscustomobject
        in the same shape as Get-AvmModuleContextInternal would produce, or
        $null when no override file exists.

        The override file lets a repository declare its classification
        explicitly when the heuristics would either miss-classify the
        layout (custom monorepo shapes) or be ambiguous (a repo that
        contains both Bicep and Terraform sources at different roots).

        Schema (all fields optional except Ecosystem and Kind):

            @{
                Ecosystem = 'bicep'                # bicep | terraform
                Kind      = 'bicep-monorepo'       # bicep-monorepo | bicep-module |
                                                   # terraform-module-repo | terraform-module-path
                Scope     = 'res'                  # res | ptn | utl (bicep only)
                Owner     = '@Azure/avm-core'      # optional
            }

        The override file's containing directory (the parent of .avm/) is
        used as the Root.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $validEcosystems = @('bicep', 'terraform')
    $validKinds = @('bicep-monorepo', 'bicep-module', 'terraform-module-repo', 'terraform-module-path')
    $validScopes = @('res', 'ptn', 'utl')

    $dir = (Resolve-Path -LiteralPath $Path).ProviderPath
    if ((Get-Item -LiteralPath $dir).PSIsContainer -eq $false) {
        $dir = Split-Path -Parent $dir
    }

    while ($dir) {
        $overridePath = Join-Path (Join-Path $dir '.avm') 'context.psd1'
        if (Test-Path -LiteralPath $overridePath -PathType Leaf) {
            $data = Import-PowerShellDataFile -LiteralPath $overridePath
            if (-not $data.ContainsKey('Ecosystem')) {
                throw [AvmConfigurationException]::new(
                    "${overridePath}: missing required key 'Ecosystem'.")
            }
            if (-not $data.ContainsKey('Kind')) {
                throw [AvmConfigurationException]::new(
                    "${overridePath}: missing required key 'Kind'.")
            }
            if ($data.Ecosystem -notin $validEcosystems) {
                throw [AvmConfigurationException]::new(
                    "${overridePath}: Ecosystem '$($data.Ecosystem)' is not one of: $($validEcosystems -join ', ').")
            }
            if ($data.Kind -notin $validKinds) {
                throw [AvmConfigurationException]::new(
                    "${overridePath}: Kind '$($data.Kind)' is not one of: $($validKinds -join ', ').")
            }
            if ($data.ContainsKey('Scope') -and $null -ne $data.Scope -and $data.Scope -notin $validScopes) {
                throw [AvmConfigurationException]::new(
                    "${overridePath}: Scope '$($data.Scope)' is not one of: $($validScopes -join ', ').")
            }
            return [pscustomobject][ordered]@{
                Kind      = [string]$data.Kind
                Root      = $dir
                Ecosystem = [string]$data.Ecosystem
                Scope     = if ($data.ContainsKey('Scope')) { $data.Scope } else { $null }
                Owner     = if ($data.ContainsKey('Owner')) { $data.Owner } else { $null }
            }
        }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}
