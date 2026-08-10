function Read-AvmContextOverride {
    <#
    .SYNOPSIS
        Parse a committed .avm/context.psd1 override at a context root.

    .DESCRIPTION
        Inspects only $Path for a .avm/context.psd1 file. When found, parses
        it as a PowerShell data file and validates the contents against the
        ModuleContext schema. Returns a pscustomobject in the same shape as
        Get-AvmModuleContextInternal would produce, or $null when no
        override file exists.

        The override file lets a repository declare its classification
        explicitly when direct source detection would misclassify the layout
        or be ambiguous.

        Schema (all fields optional except Ecosystem and Kind):

            @{
                Ecosystem = 'bicep'                # bicep | terraform
                Kind      = 'bicep-monorepo'       # bicep-monorepo | bicep-module |
                                                   # terraform-module-repo | terraform-module-path
                Scope     = 'res'                  # res | ptn | utl (bicep only)
                Owner     = '@Azure/avm-core'      # optional
            }

        $Path is used as the Root.
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

    $overridePath = Join-Path (Join-Path $Path '.avm') 'context.psd1'
    if (-not (Test-Path -LiteralPath $overridePath -PathType Leaf)) {
        return $null
    }

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
        Root      = $Path
        Ecosystem = [string]$data.Ecosystem
        Scope     = if ($data.ContainsKey('Scope')) { $data.Scope } else { $null }
        Owner     = if ($data.ContainsKey('Owner')) { $data.Owner } else { $null }
    }
}
