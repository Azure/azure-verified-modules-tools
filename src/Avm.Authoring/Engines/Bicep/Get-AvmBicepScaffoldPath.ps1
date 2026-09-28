function Get-AvmBicepScaffoldPath {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [ValidateSet('resource', 'pattern', 'utility')]
        [string] $ModuleType,

        [switch] $ChildModule
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $normalized = $root.Replace('\', '/').TrimEnd('/')
    $match = [regex]::Match($normalized, '/avm/(?<kind>res|ptn|utl)/(?<group>[a-z0-9-]+)/(?<module>[a-z0-9-]+)(?<children>(?:/[a-z0-9-]+)*)$')
    if (-not $match.Success) {
        throw [System.ArgumentException]::new(
            "Full Bicep initialization requires an avm/<res|ptn|utl>/<group>/<module> path: $root")
    }
    $kind = @{ resource = 'res'; pattern = 'ptn'; utility = 'utl' }[$ModuleType]
    if ($match.Groups['kind'].Value -cne $kind) {
        throw [System.ArgumentException]::new("ModuleType '$ModuleType' does not match the Bicep module path: $root")
    }
    $children = @(
        if ($match.Groups['children'].Length -gt 0) {
            $match.Groups['children'].Value.TrimStart('/') -split '/'
        }
    )
    if (($children.Count -gt 0) -ne [bool]$ChildModule) {
        throw [System.ArgumentException]::new(
            "Use -ChildModule only for a nested Bicep module path: $root")
    }
    $rootModule = $root
    foreach ($child in $children) {
        $rootModule = Split-Path -Path $rootModule -Parent
    }
    $monorepo = $rootModule
    for ($index = 0; $index -lt 4; $index++) {
        $monorepo = Split-Path -Path $monorepo -Parent
    }
    $current = $monorepo
    foreach ($segment in @('avm', $kind, $match.Groups['group'].Value, $match.Groups['module'].Value) + $children) {
        if (Test-Path -LiteralPath $current -PathType Container) {
            $candidates = @(Get-ChildItem -LiteralPath $current -Force | Where-Object { $_.Name -ieq $segment })
            if ($candidates.Count -gt 0 -and
                ($candidates.Count -ne 1 -or -not $candidates[0].PSIsContainer -or $candidates[0].Name -cne $segment)) {
                throw [System.ArgumentException]::new("Bicep module directory must use exact casing: $(Join-Path $current $segment)")
            }
        }
        $current = Join-Path -Path $current -ChildPath $segment
    }

    return [pscustomobject][ordered]@{
        Path           = $root
        Kind           = $kind
        Group          = $match.Groups['group'].Value
        ModuleName     = $match.Groups['module'].Value
        RootModulePath = $rootModule
        ChildSegments  = $children
    }
}
