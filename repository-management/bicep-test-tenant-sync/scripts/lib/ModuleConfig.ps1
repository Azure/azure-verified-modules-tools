function Assert-AvmBicepModulePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if ($Path -cnotmatch '^avm/(res|ptn|utl)/[a-z0-9]+(-[a-z0-9]+)*/[a-z0-9]+(-[a-z0-9]+)*$' -or $Path.Length -gt 68) {
        throw [System.ArgumentException]::new("Invalid root Bicep module path '$Path'; expected a canonical path of at most 68 characters.")
    }
}

function Get-AvmBicepModuleIdentityName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $ModulePath)

    Assert-AvmBicepModulePath -Path $ModulePath
    $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($ModulePath))
    return 'id-avm-bicep-' + $ModulePath.Replace('/', '-') + '-' + [Convert]::ToHexString($hash).Substring(0, 8).ToLowerInvariant()
}

function Get-AvmBicepModulePath {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [string] $BicepRoot)

    $root = Get-Item -LiteralPath $BicepRoot -ErrorAction Stop
    if (-not $root.PSIsContainer -or ($root.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw [System.IO.InvalidDataException]::new('Bicep discovery requires a real source directory, not a link.')
    }
    $avmDirectory = Get-Item -LiteralPath (Join-Path $root.FullName 'avm') -ErrorAction Stop
    if (-not $avmDirectory.PSIsContainer -or ($avmDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw [System.IO.InvalidDataException]::new('The Bicep module inventory must not be a directory link.')
    }
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($kind in @('res', 'ptn', 'utl')) {
        $kindPath = Join-Path $avmDirectory.FullName $kind
        $kindDirectory = Get-Item -LiteralPath $kindPath -ErrorAction Stop
        if (-not $kindDirectory.PSIsContainer -or ($kindDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw [System.IO.InvalidDataException]::new('The Bicep source inventory is incomplete or contains directory links.')
        }
        foreach ($namespace in @(Get-ChildItem -LiteralPath $kindPath -Directory -Force -ErrorAction Stop)) {
            if ($namespace.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw [System.IO.InvalidDataException]::new('Bicep namespaces must not be directory links.')
            }
            foreach ($module in @(Get-ChildItem -LiteralPath $namespace.FullName -Directory -Force -ErrorAction Stop)) {
                if ($module.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw [System.IO.InvalidDataException]::new('Bicep modules must not be directory links.')
                }
                $main = Join-Path $module.FullName 'main.bicep'
                if (-not (Test-Path -LiteralPath $main -PathType Leaf)) { continue }
                if ((Get-Item -LiteralPath $main).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw [System.IO.InvalidDataException]::new('Bicep module entry points must not be links.')
                }
                $path = "avm/$kind/$($namespace.Name)/$($module.Name)"
                Assert-AvmBicepModulePath -Path $path
                $paths.Add($path)
            }
        }
    }
    if ($paths.Count -eq 0) {
        throw [System.IO.InvalidDataException]::new('Bicep identity discovery returned no source-backed root modules.')
    }
    return ,([string[]]@($paths | Sort-Object -CaseSensitive))
}

function Resolve-AvmBicepModuleSettings {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $ModulePaths,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Configuration
    )

    if ($ModulePaths.Count -eq 0 -or $Configuration.Count -ne 1 -or
        $Configuration['moduleGroups'] -isnot [System.Collections.IList] -or $Configuration['moduleGroups'].Count -eq 0) {
        throw [System.ArgumentException]::new('Bicep configuration requires moduleGroups and a nonempty module inventory.')
    }
    $groups = @($Configuration['moduleGroups'])
    foreach ($entry in $groups) {
        $group = ConvertTo-AvmSettingDictionary -Value $entry
        if (@($group.Keys | Where-Object { $_ -cnotin @('name', 'order', 'modules', 'entraGroups', 'testTenant') }).Count -gt 0) {
            throw [System.ArgumentException]::new('Bicep module groups contain unsupported settings.')
        }
        foreach ($selector in @($group['modules'])) {
            if ($selector -ceq '*') { continue }
            Assert-AvmBicepModulePath -Path $selector
        }
    }
    $result = [ordered]@{}
    $identityNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($ModulePaths | Sort-Object -CaseSensitive)) {
        Assert-AvmBicepModulePath -Path $path
        if ($result.Contains($path) -or -not $identityNames.Add((Get-AvmBicepModuleIdentityName -ModulePath $path))) {
            throw [System.ArgumentException]::new('Bicep module paths and generated identity names must be unique.')
        }
        if ((Resolve-AvmGroupTestTenant -Groups $groups -SelectorProperty 'modules' -Item $path) -cne 'bami') {
            throw [System.ArgumentException]::new('Every Bicep module identity must select the BAMI test tenant.')
        }
        $result[$path] = Resolve-AvmGroupEntraGroups -Groups $groups -SelectorProperty 'modules' -Item $path
    }
    return $result
}

function ConvertTo-AvmBicepModuleClientIdJson {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.IDictionary] $ClientIds,
        [string[]] $ForbiddenClientIds = @()
    )

    if ($ClientIds.Count -eq 0) {
        throw [System.ArgumentException]::new('The module client-ID mapping must not be empty.')
    }
    $normalized = [ordered]@{}
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($ClientIds.Keys | Sort-Object -CaseSensitive)) {
        if ($path -isnot [string]) { throw [System.ArgumentException]::new('Module mapping keys must be canonical path strings.') }
        Assert-AvmBicepModulePath -Path $path
        $id = [guid]::Empty
        if ($ClientIds[$path] -isnot [string] -or -not [guid]::TryParseExact($ClientIds[$path], 'D', [ref]$id) -or
            $id -eq [guid]::Empty -or $id.ToString() -in $ForbiddenClientIds -or -not $seen.Add($id.ToString())) {
            throw [System.ArgumentException]::new('Each module must have its own nonempty client ID, never a shared or controller identity.')
        }
        $normalized[$path] = $id.ToString()
    }
    $json = ConvertTo-Json -InputObject $normalized -Compress -Depth 3
    if ([System.Text.Encoding]::UTF8.GetByteCount($json) -gt 48KB) {
        throw [System.InvalidOperationException]::new('The compact module client-ID mapping exceeds the 48 KB Actions variable limit; publication requires a different storage contract.')
    }
    return $json
}

function Assert-AvmBicepModuleMappingExtension {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ExistingJson,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $ClientIds,
        [string[]] $ForbiddenClientIds = @()
    )

    $existing = ConvertFrom-AvmTestTenantJson -Json $ExistingJson
    if ($existing -isnot [System.Collections.IDictionary]) {
        throw [System.IO.InvalidDataException]::new('The existing module client-ID mapping must be a JSON object.')
    }
    $null = ConvertTo-AvmBicepModuleClientIdJson -ClientIds $existing -ForbiddenClientIds $ForbiddenClientIds
    foreach ($path in $existing.Keys) {
        if (-not $ClientIds.Contains($path) -or $ClientIds[$path] -ine $existing[$path]) {
            throw [System.InvalidOperationException]::new("The existing client ID for '$path' cannot be removed or retargeted by routine synchronization.")
        }
    }
}
