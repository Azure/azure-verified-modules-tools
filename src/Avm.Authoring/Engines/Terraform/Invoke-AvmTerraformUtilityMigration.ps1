function Get-AvmTerraformUtilityInspection {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object] $Options
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $expression = '{ calls = data.module.utility.result, variables = data.variable.utility.result, ' +
    'requirements = data.terraform.utility.required_providers, resources = data.resource.utility.result, ' +
    'data_sources = data.data.utility.result, ephemeral = data.ephemeral.utility.result }'
    $result = Invoke-AvmProcess -FilePath $Options.ToolPath -ArgumentList @(
        'debug', '--tf-dir', $Path, '--mptf-dir', $Options.ProfileDirs['utility-module'], '--eval', $expression
    ) -WorkingDirectory $Path -EnvVars $Options.EnvVars
    try {
        $inspection = ConvertFrom-Json -InputObject $result.StdOut -AsHashtable -ErrorAction Stop
    }
    catch {
        throw [AvmConfigurationException]::new("Cannot inspect utility module calls in '$Path': invalid native JSON. $($_.Exception.Message)")
    }
    foreach ($key in @('calls', 'variables', 'requirements', 'resources', 'data_sources', 'ephemeral')) {
        if ($inspection -isnot [System.Collections.IDictionary] -or
            $inspection[$key] -isnot [System.Collections.IDictionary]) {
            throw [AvmConfigurationException]::new("Cannot inspect utility module calls in '$Path': update the utility-module profile to expose '$key'.")
        }
    }
    foreach ($name in $inspection.calls.Keys) {
        $call = $inspection.calls[$name]
        if ($call -isnot [System.Collections.IDictionary] -or $call['source'] -isnot [string] -or
            $call['mptf'] -isnot [System.Collections.IDictionary] -or
            $call.mptf['block_address'] -cne "module.$name") {
            throw [AvmConfigurationException]::new("Cannot inspect utility module call '$name' in '$Path': missing native source metadata.")
        }
    }
    return $inspection
}

function Get-AvmTerraformUtilityMigrationPlan {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [object[]] $Targets,
        [Parameter(Mandatory)] [object] $Options
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $versions = @{
        'azure/avm-utl-regions/azurerm'  = '0.13.0'
        'azure/avm-utl-interfaces/azure' = '0.9.0'
        'azure/naming/azurerm'           = '0.2.0'
    }
    $scopes = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($target in $Targets) {
        $inspection = Get-AvmTerraformUtilityInspection -Path $target.Path -Options $Options
        $calls = @{}
        foreach ($name in $inspection.calls.Keys) {
            $call = $inspection.calls[$name]
            $source = $call.source.ToLowerInvariant() -creplace '^registry[.]terraform[.]io/', ''
            if (-not $versions.ContainsKey($source)) { continue }
            $pin = [regex]::Match([string]$call['version'], '\A(?:=\s*)?(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)\z')
            if (-not $pin.Success) {
                throw [AvmConfigurationException]::new(
                    "Utility module '$name' in '$($target.Path)' requires review: use a literal exact version pin before automatic migration; ranges, missing versions and expressions are not rewritten.")
            }
            $version = $pin.Value -creplace '^=\s*', ''
            $parsedVersion = $null
            if (-not [version]::TryParse($version, [ref]$parsedVersion)) {
                throw [AvmConfigurationException]::new("Utility module '$name' in '$($target.Path)' has an unsupported version pin that requires review.")
            }
            $legacyNaming = $source -ceq 'azure/naming/azurerm'
            if (-not $legacyNaming -and $parsedVersion -gt [version]$versions[$source]) { continue }
            $upgrade = $legacyNaming -or $parsedVersion -lt [version]$versions[$source]
            if ($legacyNaming -and $call.Contains('legacy_mode') -and
                ($call.legacy_mode -isnot [bool] -or -not $call.legacy_mode)) {
                throw [AvmConfigurationException]::new(
                    "Legacy naming module '$name' in '$($target.Path)' has a conflicting legacy_mode; preserving existing names requires legacy_mode = true.")
            }
            $calls[$name] = [pscustomobject]@{
                Source       = if ($legacyNaming) { 'Azure/avm-utl-naming/azure' } else { $call.source }
                Version      = if ($upgrade) { $versions[$source] } else { $version }
                Upgrade      = $upgrade
                LegacyNaming = $legacyNaming
                Telemetry    = -not $legacyNaming
            }
        }
        $scopes[$target.Path] = [pscustomobject]@{
            Target       = $target
            Before       = $inspection
            Calls        = $calls
            Dependencies = @{}
            Affected     = $calls.Count -gt 0
            Telemetry    = @($calls.Values | Where-Object Telemetry).Count -gt 0
        }
    }
    foreach ($scope in $scopes.Values) {
        foreach ($name in $scope.Before.calls.Keys) {
            $source = $scope.Before.calls[$name].source
            if ($source.StartsWith('./', [System.StringComparison]::Ordinal) -or
                $source.StartsWith('../', [System.StringComparison]::Ordinal)) {
                $path = [System.IO.Path]::TrimEndingDirectorySeparator(
                    [System.IO.Path]::GetFullPath($source, $scope.Target.Path))
                if ($scopes.ContainsKey($path)) { $scope.Dependencies[$name] = $path }
            }
        }
    }
    do {
        $changed = $false
        foreach ($scope in $scopes.Values) {
            foreach ($path in $scope.Dependencies.Values) {
                if ($scopes[$path].Affected -and -not $scope.Affected) {
                    $scope.Affected = $true
                    $changed = $true
                }
                if ($scopes[$path].Telemetry -and -not $scope.Telemetry) {
                    $scope.Telemetry = $true
                    $changed = $true
                }
            }
        }
    } while ($changed)

    $ordered = [System.Collections.Generic.List[object]]::new()
    $visiting = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $visit = {
        param([string] $Path)
        if ($visited.Contains($Path)) { return }
        if (-not $visiting.Add($Path)) {
            throw [AvmConfigurationException]::new("Cannot migrate utility modules in '$Path': cyclic local module calls require review.")
        }
        foreach ($dependency in @($scopes[$Path].Dependencies.Values | Sort-Object)) { & $visit $dependency }
        $null = $visiting.Remove($Path)
        $null = $visited.Add($Path)
        $ordered.Add($scopes[$Path])
    }
    foreach ($target in $Targets) {
        if ($scopes[$target.Path].Affected) { & $visit $target.Path }
    }
    foreach ($scope in $ordered) {
        foreach ($file in Get-ChildItem -LiteralPath $scope.Target.Path -File -Filter '*.tf.json') {
            Assert-AvmTerraformLocalsOnlyJson -Path $file.FullName `
                -ReviewMessage 'Utility module migration requires review of JSON configuration'
        }
    }
    return $ordered.ToArray()
}

function Invoke-AvmTerraformUtilityPatch {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object] $Options,
        [hashtable] $Updates = @{},
        [hashtable] $Mappings = @{},
        [string[]] $RemoveMaps = @(),
        [hashtable] $Inputs = @{},
        [string] $Requirement = '',
        [string[]] $RemoveRequirements = @()
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ($Updates.Count + $Mappings.Count + $RemoveMaps.Count + $Inputs.Count + $Requirement.Length + $RemoveRequirements.Count -eq 0) {
        return
    }
    $variables = [ordered]@{
        module_updates       = $Updates
        provider_mappings    = $Mappings
        remove_provider_maps = @($RemoveMaps)
        new_inputs           = $Inputs
        provider_requirement = $Requirement
        remove_requirements  = @($RemoveRequirements)
    }
    $arguments = @('transform', '--tf-dir', $Path, '--mptf-dir', $Options.ProfileDirs['utility-module'])
    foreach ($entry in $variables.GetEnumerator()) {
        $json = (ConvertTo-Json -InputObject $entry.Value -Depth 10 -Compress).Replace('${', '$${').Replace('%{', '%%{')
        $arguments += @('--mptf-var', "$($entry.Key)=$json")
    }
    $capabilities = @'
alltrue(concat(
  [for name, body in var.module_updates : try(transform.update_in_place.utility_calls[name].target_block_address == "module.${name}" && transform.update_in_place.utility_calls[name].dynamic_block_body == body, false)],
  [for name, mapping in var.provider_mappings : try(!transform.update_in_place.utility_provider_mappings[name].merge_object_attributes && transform.update_in_place.utility_provider_mappings[name].target_block_address == "module.${name}" && transform.update_in_place.utility_provider_mappings[name].dynamic_block_body == "providers = ${mapping}\n", false)],
  [for name in var.remove_provider_maps : try(transform.remove_block_element.utility_provider_maps[name].target_block_address == "module.${name}" && jsonencode(transform.remove_block_element.utility_provider_maps[name].paths) == jsonencode(["providers"]), false)],
  [for name, mode in var.new_inputs : try(transform.new_block[name == "location" ? "utility_location_${mode}" : "utility_enable_telemetry"][name].new_block_type == "variable" && jsonencode(transform.new_block[name == "location" ? "utility_location_${mode}" : "utility_enable_telemetry"][name].labels) == jsonencode([name]) && transform.new_block[name == "location" ? "utility_location_${mode}" : "utility_enable_telemetry"][name].filename == "variables.tf", false)],
  [for name in var.remove_requirements : try(transform.remove_block_element.utility_requirements[name].target_block_address == "terraform" && jsonencode(transform.remove_block_element.utility_requirements[name].paths) == jsonencode(["required_providers.${name}"]), false)],
  [length(var.provider_requirement) == 0 || try(transform.update_in_place.utility_requirement["1"].merge_object_attributes && transform.update_in_place.utility_requirement["1"].dynamic_block_body == var.provider_requirement, try(transform.new_block.utility_requirement["1"].body == "\n${var.provider_requirement}", false))]
))
'@
    $check = Invoke-AvmProcess -FilePath $Options.ToolPath -ArgumentList (@('debug') + $arguments[1..($arguments.Count - 1)] + @('--eval', $capabilities)) `
        -WorkingDirectory $Path -EnvVars $Options.EnvVars
    if ($check.StdOut.Trim() -cne 'true') {
        throw [AvmConfigurationException]::new("Cannot safely migrate utility modules in '$Path': update MaPoTF and the utility-module profile to support the exact native patches.")
    }
    if ($PSCmdlet.ShouldProcess($Path, 'migrate authored utility module calls and proven unused provider requirements')) {
        $null = Invoke-AvmProcess -FilePath $Options.ToolPath -ArgumentList $arguments `
            -WorkingDirectory $Path -EnvVars $Options.EnvVars
    }
}

function Get-AvmTerraformUtilityProviderSource {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [object] $Call,
        [Parameter(Mandatory)] [object] $Options,
        [Parameter(Mandatory)] [hashtable] $Cache
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $key = "$($Call.Source)|$($Call.Version)"
    if (-not $Cache.ContainsKey($key)) {
        $path = Join-Path $Options.InspectionRoot ('utility-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop
        $source = ConvertTo-Json -InputObject $Call.Source -Compress
        $version = ConvertTo-Json -InputObject $Call.Version -Compress
        $inputs = if ($Call.Telemetry) { "  location = `"eastus`"`n  enable_telemetry = false`n" } else { '' }
        [System.IO.File]::WriteAllText((Join-Path $path 'main.tf'),
            "module `"utility`" {`n  source = $source`n  version = $version`n$inputs}`n", [System.Text.UTF8Encoding]::new($false))
        $Cache[$key] = @(Get-AvmTerraformUnitTestProviderSource -Path $path `
                -ModuleTargets @([pscustomobject]@{ Path = $path }) -Options $Options)
    }
    return $Cache[$key]
}

function Get-AvmTerraformUtilityProviderMapping {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [object] $Call,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $ProviderSources,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Name
    )

    Set-StrictMode -Version 3.0
    if (@($ProviderSources | Where-Object { $_ -match '/modtm$' -and $_ -ine 'registry.terraform.io/azure/modtm' }).Count -gt 0) {
        throw [AvmConfigurationException]::new("Cannot migrate utility module '$Name' in '$Path': an unexpected ModTM provider source requires review.")
    }
    if (-not $Call.Contains('providers') -or $ProviderSources -contains 'registry.terraform.io/azure/modtm') { return $null }
    $mapping = ConvertFrom-AvmTerraformUnitTestProviderMapping -Expression $Call.providers `
        -ProviderNames @() -AllowUnlistedProviders -RetiredProviderNames modtm
    if ($null -eq $mapping) {
        throw [AvmConfigurationException]::new(
            "Cannot migrate utility module '$Name' in '$Path': computed, aliased target keys or cross-provider module bindings require review.")
    }
    if (-not $mapping.Changed) { return $null }
    $remainingCount = $mapping.Bindings.Count - 1
    $expression = $mapping.Expression
    if ($ProviderSources -contains 'registry.terraform.io/azure/azapi' -and -not $mapping.Bindings.ContainsKey('azapi')) {
        $expression = $expression.Insert($expression.LastIndexOf('}'), "`n  azapi = azapi`n")
        $remainingCount++
    }
    return [pscustomobject]@{ Expression = $expression; Changed = $true; RemoveMap = $remainingCount -eq 0 }
}

function Invoke-AvmTerraformUtilityMigration {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Plans,
        [Parameter(Mandatory)] [object] $Options
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $cache = @{}
    $telemetryPaths = @($Plans | Where-Object Telemetry | ForEach-Object { $_.Target.Path })
    foreach ($scope in $Plans | Where-Object Affected) {
        $updates = @{}
        $mappings = @{}
        $removeMaps = [System.Collections.Generic.List[string]]::new()
        $inputs = @{}
        $requiresAzapi = $scope.Telemetry -and -not $scope.Before.requirements.Contains('azapi') -and
        $scope.Target.Profiles -notcontains 'root'
        foreach ($name in $scope.Calls.Keys) {
            $plan = $scope.Calls[$name]
            $call = $scope.Before.calls[$name]
            $body = [System.Collections.Generic.List[string]]::new()
            if ($plan.Upgrade) { $body.Add('version = "' + $plan.Version + '"') }
            if ($plan.LegacyNaming) {
                $body.Add('source = "' + $plan.Source + '"')
                $body.Add('legacy_mode = true')
            }
            if ($plan.Telemetry) {
                if (-not $call.Contains('location')) {
                    $body.Add('location = var.location')
                    if (-not $scope.Before.variables.Contains('location')) {
                        $inputs.location = if ($scope.Target.Scope -ceq 'example') { 'example' } else { 'required' }
                    }
                }
                if ($scope.Target.Scope -cne 'test' -and -not $call.Contains('enable_telemetry')) {
                    $body.Add('enable_telemetry = var.enable_telemetry')
                    if (-not $scope.Before.variables.Contains('enable_telemetry')) {
                        $inputs.enable_telemetry = 'default'
                    }
                }
            }
            if ($call.Contains('providers')) {
                $bindings = ConvertFrom-AvmTerraformUnitTestProviderMapping -Expression $call.providers -ProviderNames @() -AllowUnlistedProviders
                if ($null -eq $bindings) {
                    throw [AvmConfigurationException]::new("Cannot migrate utility module '$name' in '$($scope.Target.Path)': its provider mapping requires review.")
                }
                if ($bindings.Bindings.ContainsKey('modtm')) {
                    $sources = @(Get-AvmTerraformUtilityProviderSource -Call $plan -Options $Options -Cache $cache)
                    $mapping = Get-AvmTerraformUtilityProviderMapping -Call $call -ProviderSources $sources -Path $scope.Target.Path -Name $name
                    if ($null -ne $mapping) {
                        if ($mapping.RemoveMap) { $removeMaps.Add($name) }
                        else { $mappings[$name] = $mapping.Expression }
                    }
                }
            }
            if ($body.Count -gt 0) { $updates[$name] = ($body -join "`n") + "`n" }
        }
        $requirement = ''
        $localTelemetryCalls = @($scope.Dependencies.Keys | Where-Object { $scope.Dependencies[$_] -cin $telemetryPaths })
        if ($requiresAzapi -or $localTelemetryCalls.Count -gt 0) {
            if ($requiresAzapi) {
                $requirement = "required_providers {`n  azapi = {`n    source = `"Azure/azapi`"`n    version = `"~> 2.12`"`n  }`n}`n"
            }
            $azapiCalls = @($scope.Before.calls.Keys | Where-Object {
                    ($requiresAzapi -and $scope.Calls.ContainsKey($_) -and $scope.Calls[$_].Telemetry) -or
                    $_ -cin $localTelemetryCalls
                })
            foreach ($name in $azapiCalls) {
                $call = $scope.Before.calls[$name]
                $expression = if ($mappings.ContainsKey($name)) { $mappings[$name] }
                elseif ($call.Contains('providers') -and -not $removeMaps.Contains($name)) { $call.providers }
                else { '{}' }
                $mapping = ConvertFrom-AvmTerraformUnitTestProviderMapping -Expression $expression -ProviderNames @() -AllowUnlistedProviders
                if ($null -eq $mapping) {
                    throw [AvmConfigurationException]::new("Cannot introduce AzAPI for utility module '$name' in '$($scope.Target.Path)': review its provider mapping.")
                }
                if (-not $mapping.Bindings.ContainsKey('azapi')) {
                    $mappings[$name] = $expression.Insert($expression.LastIndexOf('}'), "`n  azapi = azapi`n")
                }
                $null = $removeMaps.Remove($name)
            }
        }
        if ($PSCmdlet.ShouldProcess($scope.Target.Path, 'upgrade utility modules before telemetry transformation')) {
            Invoke-AvmTerraformUtilityPatch -Path $scope.Target.Path -Options $Options -Updates $updates `
                -Mappings $mappings -RemoveMaps $removeMaps.ToArray() -Inputs $inputs -Requirement $requirement
        }
    }
}

function Invoke-AvmTerraformUtilityProviderCleanup {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Plans,
        [Parameter(Mandatory)] [object[]] $ModuleTargets,
        [Parameter(Mandatory)] [object] $Options
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $requirements = @{}
    $sources = $Options.UtilityProviderSources
    $moduleSources = @{}
    $manifests = @{}
    $providerWarnings = @{}
    $originalRequirements = @{}
    $requirementPlans = @{}
    $appliedRequirements = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $planningPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($scope in $Plans) { $originalRequirements[$scope.Target.Path] = $scope.Before.requirements }
    foreach ($scope in $Plans) {
        $path = $scope.Target.Path
        if (-not $PSCmdlet.ShouldProcess($path, 'retire utility-only provider references using fresh dependency evidence')) { continue }
        $inspection = Get-AvmTerraformUtilityInspection -Path $path -Options $Options
        $mappings = @{}
        $removeMaps = [System.Collections.Generic.List[string]]::new()
        $requiresAzapi = $false
        foreach ($name in $scope.Dependencies.Keys) {
            $dependency = $scope.Dependencies[$name]
            if (-not $sources.ContainsKey($dependency)) { continue }
            $mapping = Get-AvmTerraformUtilityProviderMapping -Call $inspection.calls[$name] `
                -ProviderSources $sources[$dependency] -Path $path -Name $name
            if ($null -ne $mapping) {
                if ($mapping.RemoveMap) { $removeMaps.Add($name) }
                else { $mappings[$name] = $mapping.Expression }
                if ($sources[$dependency] -contains 'registry.terraform.io/azure/azapi') { $requiresAzapi = $true }
            }
        }
        $requirement = ''
        if ($requiresAzapi -and -not $inspection.requirements.Contains('azapi')) {
            $requirement = "required_providers {`n  azapi = {`n    source = `"Azure/azapi`"`n    version = `"~> 2.12`"`n  }`n}`n"
        }
        Invoke-AvmTerraformUtilityPatch -Path $path -Options $Options -Mappings $mappings `
            -RemoveMaps $removeMaps.ToArray() -Requirement $requirement
        $inspection = Get-AvmTerraformUtilityInspection -Path $path -Options $Options
        $moduleSources[$path] = @{}
        $sources[$path] = @(Get-AvmTerraformUnitTestProviderSource -Path $path -ModuleTargets $ModuleTargets -Options $Options `
                -ModuleProviderSources $moduleSources[$path] -ModuleManifests $manifests `
                -AllowMissingProviderConfiguration -ProviderWarnings $providerWarnings)
        $requirements[$path] = $inspection.requirements
        $retire = @(
            foreach ($provider in @('modtm', 'random')) {
                $source = if ($provider -ceq 'modtm') { 'registry.terraform.io/azure/modtm' } else { 'registry.terraform.io/hashicorp/random' }
                if (-not $inspection.requirements.Contains($provider)) { continue }
                $declared = [string]$inspection.requirements[$provider]['source']
                if ($declared.ToLowerInvariant() -cnotin @($source, $source.Substring('registry.terraform.io/'.Length))) { continue }
                $used = @(
                    foreach ($kind in @('resources', 'data_sources', 'ephemeral')) {
                        $inspection[$kind].Keys | Where-Object { $_.StartsWith("$($provider)_", [System.StringComparison]::Ordinal) }
                    }
                    foreach ($providers in $moduleSources[$path].Values) {
                        $providers | Where-Object { $_ -ceq $source }
                    }
                    foreach ($call in $inspection.calls.Values) {
                        if ($call.Contains('providers') -and $call.providers -cmatch "\b$provider\b") { $provider }
                    }
                    foreach ($file in Get-ChildItem -LiteralPath $path -File -Filter '*.tf') {
                        $text = [System.IO.File]::ReadAllText($file.FullName)
                        if ($text -cmatch ('\bprovider\s+"' + $provider + '"') -or $text -cmatch '\bconfiguration_aliases\s*=') { $provider }
                    }
                )
                if ($used.Count -eq 0) { $provider }
            }
        )
        if ($retire.Count -gt 0) {
            Invoke-AvmTerraformUtilityPatch -Path $path -Options $Options -RemoveRequirements $retire
            $requirements[$path] = Get-AvmTerraformUnitTestRequiredProvider -Path $path -Options $Options
            $sources[$path] = @(Get-AvmTerraformUnitTestProviderSource -Path $path -ModuleTargets $ModuleTargets -Options $Options `
                    -ModuleProviderSources $moduleSources[$path] -ModuleManifests $manifests `
                    -AllowMissingProviderConfiguration -ProviderWarnings $providerWarnings)
        }
        if ($sources[$path] -contains 'registry.terraform.io/azure/modtm') {
            $null = Get-AvmTerraformUnitTestModtmRequirementPlan -Path $path -ModuleTargets $ModuleTargets `
                -Options $Options -RequiredProviders $requirements -ProviderSources $sources `
                -ModuleProviderSources $moduleSources -ModuleManifests $manifests -OriginalRequirements $originalRequirements `
                -Plans $requirementPlans -PlanningPaths $planningPaths -BindDependencies
            foreach ($plan in @($requirementPlans.Values | Where-Object { -not $appliedRequirements.Contains($_.Path) })) {
                $check = Invoke-AvmProcess -FilePath $Options.ToolPath `
                    -ArgumentList (@('debug') + $plan.Arguments[1..($plan.Arguments.Count - 1)] + @('--eval', $plan.Capabilities)) `
                    -WorkingDirectory $plan.Path -EnvVars $Options.EnvVars
                if ($check.StdOut.Trim() -cne 'true') {
                    throw [AvmConfigurationException]::new("Cannot retain required ModTM bindings in '$($plan.Path)': update the native module profile.")
                }
                $null = Invoke-AvmProcess -FilePath $Options.ToolPath -ArgumentList $plan.Arguments -WorkingDirectory $plan.Path -EnvVars $Options.EnvVars
                $null = $appliedRequirements.Add($plan.Path)
                if ($plan.Path -cne $path) {
                    Invoke-AvmMapotfTransformTarget -Target ([pscustomobject]@{
                            Path = $plan.Path; Scope = 'module'; Profiles = @('variable-order', 'common')
                        }) -Options $Options
                }
            }
        }
        if ($providerWarnings.ContainsKey($path)) {
            $sources[$path] = @(Get-AvmTerraformUnitTestProviderSource -Path $path -ModuleTargets $ModuleTargets -Options $Options `
                    -ModuleProviderSources $moduleSources[$path] -ModuleManifests $manifests)
        }
        Invoke-AvmMapotfTransformTarget -Target ([pscustomobject]@{
                Path = $path; Scope = $scope.Target.Scope; Profiles = @('variable-order', 'common')
            }) -Options $Options
    }
}
