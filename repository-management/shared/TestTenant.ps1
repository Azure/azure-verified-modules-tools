#Requires -Version 7.4

. (Join-Path $PSScriptRoot 'GroupSettings.ps1')

function ConvertFrom-AvmTestTenantJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Json)

    $document = $null
    try {
        $document = [System.Text.Json.JsonDocument]::Parse($Json)
        $pending = [System.Collections.Generic.Stack[System.Text.Json.JsonElement]]::new()
        $pending.Push($document.RootElement)
        while ($pending.Count -gt 0) {
            $element = $pending.Pop()
            if ($element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
                $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($property in $element.EnumerateObject()) {
                    if (-not $names.Add($property.Name)) {
                        throw [System.ArgumentException]::new('Test tenant JSON contains duplicate property names.')
                    }
                    $pending.Push($property.Value)
                }
            }
            elseif ($element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
                foreach ($item in $element.EnumerateArray()) {
                    $pending.Push($item)
                }
            }
        }
        return ConvertFrom-Json -InputObject $Json -AsHashtable -NoEnumerate -Depth 30
    }
    catch {
        throw [System.ArgumentException]::new('Invalid test tenant JSON.', $_.Exception)
    }
    finally {
        if ($null -ne $document) {
            $document.Dispose()
        }
    }
}

function Get-AvmBicepModulePath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ModulePath,
        [switch] $Exact
    )

    $segments = $ModulePath.Split('/')
    if ($segments.Count -lt 4 -or ($Exact -and $segments.Count -ne 4) -or
        @($segments | Where-Object { $_ -in @('.', '..') -or $_ -cnotmatch '^[a-zA-Z0-9_.-]+$' }).Count -gt 0) {
        throw [System.ArgumentException]::new('Module paths must be canonical avm/{res,ptn,utl}/{provider}/{module} paths or safe descendants.')
    }
    $root = $segments[0..3] -join '/'
    if ($root -cnotmatch '^avm/(res|ptn|utl)/[a-z0-9]+(?:-[a-z0-9]+)*/[a-z0-9]+(?:-[a-z0-9]+)*$') {
        throw [System.ArgumentException]::new('Module paths must use canonical lowercase top-level AVM module names.')
    }
    return $root
}

function ConvertFrom-AvmTestTenantModuleConfig {
    [CmdletBinding()]
    param([AllowEmptyString()] [string] $Json = '')

    if ([string]::IsNullOrWhiteSpace($Json)) {
        return [ordered]@{ default = 'legacy'; modules = [ordered]@{} }
    }
    $config = ConvertTo-AvmSettingDictionary -Value (ConvertFrom-AvmTestTenantJson -Json $Json)
    if ($config.Count -ne 2 -or $config['default'] -isnot [string] -or $config['default'] -cne 'legacy' -or
        -not $config.Contains('modules')) {
        throw [System.ArgumentException]::new('Test tenant metadata must contain only default (legacy) and modules.')
    }
    $modules = ConvertTo-AvmSettingDictionary -Value $config['modules']
    foreach ($path in $modules.Keys) {
        $null = Get-AvmBicepModulePath -ModulePath $path -Exact
        if ($modules[$path] -isnot [string] -or $modules[$path] -cnotin @('legacy', 'bami')) {
            throw [System.ArgumentException]::new("Module '$path' testTenant must be exactly 'legacy' or 'bami'.")
        }
    }
    return [ordered]@{ default = 'legacy'; modules = $modules }
}

function ConvertTo-AvmBicepModuleConfig {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [object] $Configuration)

    $config = ConvertTo-AvmSettingDictionary -Value $Configuration
    if ($config.Count -ne 1 -or $config['moduleGroups'] -isnot [System.Collections.IList] -or
        $config['moduleGroups'].Count -eq 0) {
        throw [System.ArgumentException]::new('Bicep configuration must contain only a nonempty moduleGroups array.')
    }
    $groups = $config['moduleGroups']
    $paths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $hasDefault = $false
    foreach ($entry in $groups) {
        $group = ConvertTo-AvmSettingDictionary -Value $entry
        if (@($group.Keys | Where-Object { $_ -cnotin @('name', 'order', 'modules', 'testTenant') }).Count -gt 0) {
            throw [System.ArgumentException]::new('Bicep groups support only name, order, modules, and testTenant.')
        }
        if ($group['name'] -isnot [string] -or -not $names.Add($group['name'])) {
            throw [System.ArgumentException]::new('Bicep group names must be unique strings.')
        }
        if ($group['modules'] -isnot [System.Collections.IList] -or $group['modules'].Count -eq 0) {
            throw [System.ArgumentException]::new('Bicep group modules must be a nonempty array.')
        }
        if ($group['name'] -ceq 'default') {
            if ($group['modules'].Count -ne 1 -or $group['modules'][0] -cne '*' -or $group['testTenant'] -cne 'legacy') {
                throw [System.ArgumentException]::new('The default Bicep group must select only * with testTenant legacy.')
            }
            $hasDefault = $true
        }
        else {
            foreach ($path in $group['modules']) {
                if ($path -isnot [string]) {
                    throw [System.ArgumentException]::new('Bicep module selectors must be strings.')
                }
                $null = Get-AvmBicepModulePath -ModulePath $path -Exact
                $null = $paths.Add($path)
            }
        }
    }
    if (-not $hasDefault) {
        throw [System.ArgumentException]::new('Bicep configuration requires a default legacy group.')
    }
    $null = Resolve-AvmGroupTestTenant -Groups $groups -SelectorProperty 'modules' -Item '*'
    $modules = [ordered]@{}
    foreach ($path in @($paths | Sort-Object)) {
        $modules[$path] = Resolve-AvmGroupTestTenant -Groups $groups -SelectorProperty 'modules' -Item $path
    }
    return ConvertTo-Json -InputObject ([ordered]@{ default = 'legacy'; modules = $modules }) -Depth 5 -Compress
}

function Get-AvmBamiSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Values,
        [switch] $BicepOnly
    )

    $guidNames = @('TEST_BAMI_TENANT_ID', 'TEST_BAMI_BICEP_CLIENT_ID', 'TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID')
    if (-not $BicepOnly) {
        $guidNames += @('TEST_BAMI_CONTROLLER_CLIENT_ID', 'TEST_BAMI_ADMIN_SUBSCRIPTION_ID')
    }
    $result = [ordered]@{}
    foreach ($name in $guidNames) {
        $value = $Values[$name]
        $id = [guid]::Empty
        if ($value -isnot [string] -or -not [guid]::TryParseExact($value, 'D', [ref] $id) -or $id -eq [guid]::Empty) {
            throw [System.ArgumentException]::new("$name must be a nonempty GUID in a complete BAMI bundle.")
        }
        $result[$name] = $id.ToString()
    }
    $groupNames = @('TEST_BAMI_MANAGEMENT_GROUP_ID')
    if (-not $BicepOnly) {
        $groupNames += 'TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME'
    }
    foreach ($name in $groupNames) {
        $value = $Values[$name]
        if ($value -isnot [string] -or $value -cnotmatch '^[a-zA-Z0-9_().-]{1,90}$' -or $value.EndsWith('.')) {
            throw [System.ArgumentException]::new("$name must be a management-group or resource-group name, not a resource ID.")
        }
        $result[$name] = $value
    }
    $subscriptions = $Values['TEST_BAMI_SUBSCRIPTION_IDS']
    if ($subscriptions -is [string]) {
        $subscriptions = ConvertFrom-AvmTestTenantJson -Json $subscriptions
    }
    if ($subscriptions -isnot [System.Collections.IList] -or $subscriptions.Count -ne 28) {
        throw [System.ArgumentException]::new('TEST_BAMI_SUBSCRIPTION_IDS must contain exactly 28 {name,id} objects.')
    }
    $seenIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $seenNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $normalized = foreach ($subscription in $subscriptions) {
        $entry = ConvertTo-AvmSettingDictionary -Value $subscription
        $id = [guid]::Empty
        if ($entry.Count -ne 2 -or $entry['name'] -isnot [string] -or
            [string]::IsNullOrWhiteSpace($entry['name']) -or $entry['name'] -match '[\x00-\x1f\x7f]' -or
            $entry['name'] -cne $entry['name'].Trim() -or $entry['id'] -isnot [string] -or
            -not [guid]::TryParseExact($entry['id'], 'D', [ref] $id) -or $id -eq [guid]::Empty -or
            -not $seenIds.Add($id.ToString()) -or -not $seenNames.Add($entry['name'])) {
            throw [System.ArgumentException]::new('BAMI subscriptions must have unique nonempty names and GUID IDs, with no additional fields.')
        }
        [ordered]@{ name = $entry['name']; id = $id.ToString() }
    }
    $result['TEST_BAMI_SUBSCRIPTION_IDS'] = ConvertTo-Json -InputObject @($normalized) -Depth 4 -Compress
    if (-not $BicepOnly -and $result['TEST_BAMI_CONTROLLER_CLIENT_ID'] -ceq $result['TEST_BAMI_BICEP_CLIENT_ID']) {
        throw [System.ArgumentException]::new('BAMI controller and Bicep execution client IDs must be separate identities.')
    }
    return $result
}

function Resolve-AvmTestTenant {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $ModulePath,
        [AllowEmptyString()] [string] $ModuleConfigJson = '',
        [AllowEmptyString()] [string] $BamiSettingsJson = ''
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $path = Get-AvmBicepModulePath -ModulePath $ModulePath
    $config = ConvertFrom-AvmTestTenantModuleConfig -Json $ModuleConfigJson
    $tenant = if ($config.modules.Contains($path)) { $config.modules[$path] } else { $config.default }
    $settings = [ordered]@{}
    if ($tenant -ceq 'bami') {
        if ([string]::IsNullOrWhiteSpace($BamiSettingsJson)) {
            throw [System.ArgumentException]::new('An explicit BAMI selection requires the complete BAMI execution bundle.')
        }
        $values = ConvertTo-AvmSettingDictionary -Value (ConvertFrom-AvmTestTenantJson -Json $BamiSettingsJson)
        $settings = Get-AvmBamiSettings -Values $values -BicepOnly
    }
    return [pscustomobject]@{ TestTenant = $tenant; Settings = $settings }
}
