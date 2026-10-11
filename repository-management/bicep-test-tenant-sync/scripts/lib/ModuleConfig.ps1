function Get-AvmBicepModuleIdentityName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $ModulePath)

    return Get-AvmTestIdentityName -ModulePath $ModulePath
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

function ConvertTo-AvmBicepIdentityMapping {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Identities,
        [Parameter(Mandatory)] [string[]] $ModulePaths,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Settings,
        [switch] $Legacy
    )

    $settings = Get-AvmBamiSettings -Values $Settings
    if ($Identities.Count -ne $ModulePaths.Count -or
        @($Identities.Keys | Where-Object { $_ -cnotin $ModulePaths }).Count -gt 0) {
        throw [System.IO.InvalidDataException]::new('Applied identity output must cover exactly the discovered root modules.')
    }
    $mapping = [ordered]@{}
    foreach ($path in $ModulePaths) {
        $identity = $Identities[$path]
        $name = Get-AvmTestIdentityName -ModulePath $path -Legacy:$Legacy
        $expectedId = "/subscriptions/$($settings.TEST_BAMI_ADMIN_SUBSCRIPTION_ID)/resourceGroups/$($settings.TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME)/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$name"
        if ($identity -isnot [System.Collections.IDictionary] -or $identity.Count -ne 3 -or
            $identity['tenant_id'] -ine $settings.TEST_BAMI_TENANT_ID -or
            $identity['identity_resource_id'] -ine $expectedId) {
            throw [System.IO.InvalidDataException]::new('Applied identity output does not belong to its expected module and BAMI resource group.')
        }
        $mapping[$path] = $identity['client_id']
    }
    $null = ConvertTo-AvmBicepModuleClientIdJson -ClientIds $mapping `
        -ForbiddenClientIds @($settings.TEST_BAMI_CONTROLLER_CLIENT_ID, $settings.TEST_BAMI_BICEP_CLIENT_ID)
    return $mapping
}

function Get-AvmBicepIdentityPublicationContext {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param()

    $workflow = 'Azure/azure-verified-modules-tools/.github/workflows/repository-management-bicep-sync.yml@refs/heads/main'
    if ($env:GITHUB_ACTIONS -cne 'true' -or $env:GITHUB_REPOSITORY -cne 'Azure/azure-verified-modules-tools' -or
        $env:GITHUB_REF -cne 'refs/heads/main' -or $env:GITHUB_WORKFLOW_REF -cne $workflow -or
        $env:GITHUB_REPOSITORY_ID -cnotmatch '^[1-9][0-9]*$' -or
        $env:GITHUB_RUN_ID -cnotmatch '^[1-9][0-9]*$' -or $env:GITHUB_RUN_ATTEMPT -cnotmatch '^[1-9][0-9]*$' -or
        $env:GITHUB_SHA -cnotmatch '^[0-9a-f]{40}$') {
        throw [System.InvalidOperationException]::new('Identity rename publication requires the current trusted Bicep Sync run and attempt.')
    }
    return [ordered]@{
        repositoryId = $env:GITHUB_REPOSITORY_ID
        workflowRef = $workflow
        commit = $env:GITHUB_SHA
        runId = $env:GITHUB_RUN_ID
        runAttempt = $env:GITHUB_RUN_ATTEMPT
    }
}

function ConvertFrom-AvmBicepIdentityMigration {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Migration,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $ClientIds,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Settings
    )

    $context = Get-AvmBicepIdentityPublicationContext
    if ($Migration.Count -ne 4 -or ($Migration['schemaVersion'] -isnot [int] -and $Migration['schemaVersion'] -isnot [long]) -or
        $Migration['schemaVersion'] -ne 1 -or
        $Migration['context'] -isnot [System.Collections.IDictionary] -or $Migration['context'].Count -ne $context.Count -or
        $Migration['before'] -isnot [System.Collections.IDictionary] -or
        $Migration['after'] -isnot [System.Collections.IDictionary] -or $Migration['before'].Count -ne $Migration['after'].Count) {
        throw [System.IO.InvalidDataException]::new('Identity rename evidence must contain the complete current-run before and after identity records.')
    }
    foreach ($key in $context.Keys) {
        if ($Migration['context'][$key] -isnot [string] -or $Migration['context'][$key] -cne $context[$key]) {
            throw [System.InvalidOperationException]::new('Identity rename evidence belongs to a different run, attempt, repository or commit.')
        }
    }
    if ($Migration['before'].Count -eq 0) { return [ordered]@{} }
    $paths = @($Migration['before'].Keys)
    $previous = ConvertTo-AvmBicepIdentityMapping -Identities $Migration['before'] -ModulePaths $paths -Settings $Settings -Legacy
    $current = ConvertTo-AvmBicepIdentityMapping -Identities $Migration['after'] -ModulePaths $paths -Settings $Settings
    foreach ($path in $paths) {
        if (-not $ClientIds.Contains($path) -or $ClientIds[$path] -ine $current[$path] -or
            $previous[$path] -in @($ClientIds.Values)) {
            throw [System.InvalidOperationException]::new('Identity rename evidence must bind each old module client to its new applied client, without stale or reused IDs.')
        }
    }
    return $previous
}

function Assert-AvmBicepModuleMappingExtension {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ExistingJson,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $ClientIds,
        [string[]] $ForbiddenClientIds = @(),
        [System.Collections.IDictionary] $IdentityMigration,
        [System.Collections.IDictionary] $Settings
    )

    $existing = ConvertFrom-AvmTestTenantJson -Json $ExistingJson
    if ($existing -isnot [System.Collections.IDictionary]) {
        throw [System.IO.InvalidDataException]::new('The existing module client-ID mapping must be a JSON object.')
    }
    $null = ConvertTo-AvmBicepModuleClientIdJson -ClientIds $existing -ForbiddenClientIds $ForbiddenClientIds
    $previous = if ($null -ne $IdentityMigration) {
        ConvertFrom-AvmBicepIdentityMigration -Migration $IdentityMigration -ClientIds $ClientIds -Settings $Settings
    }
    else { @{} }
    foreach ($path in $existing.Keys) {
        if (-not $ClientIds.Contains($path) -or ($ClientIds[$path] -ine $existing[$path] -and
            (-not $previous.Contains($path) -or $previous[$path] -ine $existing[$path]))) {
            throw [System.InvalidOperationException]::new("The existing client ID for '$path' cannot be removed or retargeted by routine synchronization.")
        }
    }
}
