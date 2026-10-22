function Get-AvmTerraformUtilityInspection {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object] $Options,
        [ValidateSet('root', 'module', 'example', 'test')] [string] $Scope = 'module',
        [switch] $PreserveSelections
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $expression = '{ calls = data.module.utility.result, variables = data.variable.utility.result, ' +
    'requirements = data.terraform.utility.required_providers, resources = data.resource.utility.result, ' +
    'data_sources = data.data.utility.result, ephemeral = data.ephemeral.utility.result, migration = { ' +
    'review = local.utility_review_calls, calls = { for name, call in local.utility_selected_calls : name => { telemetry = !call.legacy_naming, provider_source = call.legacy_naming ? "Azure/avm-utl-naming/azure" : call.source, provider_version = call.target_version } } } }'
    $result = Invoke-AvmProcess -FilePath $Options.ToolPath -ArgumentList @(
        'debug', '--tf-dir', $Path, '--mptf-dir', $Options.ProfileDirs['utility-module'],
        '--mptf-var', ('target_scope="{0}"' -f $Scope),
        '--mptf-var', ('preserve_selections={0}' -f $PreserveSelections.ToString().ToLowerInvariant()),
        '--eval', $expression
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
    if ($inspection['migration'] -isnot [System.Collections.IDictionary] -or
        $inspection.migration['review'] -isnot [System.Collections.IDictionary] -or
        $inspection.migration['calls'] -isnot [System.Collections.IDictionary]) {
        throw [AvmConfigurationException]::new("Cannot inspect utility module calls in '$Path': update the utility-module profile to expose native migration decisions.")
    }
    return $inspection
}

function Get-AvmTerraformUtilityMigrationPlan {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [object[]] $Targets,
        [Parameter(Mandatory)] [object] $Options,
        [switch] $PreserveSelections
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $scopes = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($target in $Targets) {
        $inspection = Get-AvmTerraformUtilityInspection -Path $target.Path -Options $Options -Scope $target.Scope `
            -PreserveSelections:$PreserveSelections
        if ($inspection.migration.review.Count -gt 0) {
            $names = @($inspection.migration.review.Keys | Sort-Object) -join "', '"
            throw [AvmConfigurationException]::new(
                "Utility module '$names' in '$($target.Path)' requires review: use a literal exact version pin before automatic migration; ranges, missing versions and expressions are not rewritten.")
        }
        $calls = @{}
        foreach ($name in $inspection.migration.calls.Keys) {
            $migrationCall = $inspection.migration.calls[$name]
            if ($migrationCall -isnot [System.Collections.IDictionary] -or
                $migrationCall['provider_source'] -isnot [string] -or
                [string]::IsNullOrWhiteSpace($migrationCall.provider_source) -or
                $migrationCall['provider_version'] -isnot [string] -or
                [string]::IsNullOrWhiteSpace($migrationCall.provider_version)) {
                throw [AvmConfigurationException]::new(
                    "Cannot inspect utility module call '$name' in '$($target.Path)': missing native provider dependency metadata.")
            }
            $calls[$name] = [pscustomobject]@{
                Telemetry       = [bool]$migrationCall.telemetry
                ProviderSource  = [string]$migrationCall.provider_source
                ProviderVersion = [string]$migrationCall.provider_version
            }
        }
        $scopes[$target.Path] = [pscustomobject]@{
            Target       = $target
            Before       = $inspection
            Calls        = $calls
            Dependencies = @{}
            Affected     = $calls.Count -gt 0 -or ($inspection.requirements.Count -gt 0 -and $inspection.calls.Count -gt 0)
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
    do {
        $previousCount = $visited.Count
        foreach ($target in $Targets) {
            if (-not $visited.Contains($target.Path) -and
                @($scopes[$target.Path].Dependencies.Values | Where-Object { $visited.Contains($_) }).Count -gt 0) {
                & $visit $target.Path
            }
        }
    } while ($visited.Count -gt $previousCount)
    foreach ($scope in $ordered) {
        foreach ($file in Get-ChildItem -LiteralPath $scope.Target.Path -File -Filter '*.tf.json') {
            Assert-AvmTerraformLocalsOnlyJson -Path $file.FullName `
                -ReviewMessage 'Utility module migration requires review of JSON configuration'
        }
    }
    return $ordered.ToArray()
}

function Invoke-AvmTerraformUtilityNativeMigration {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [ValidateSet('root', 'module', 'example', 'test')] [string] $Scope,
        [Parameter(Mandatory)] [object] $Options,
        [hashtable] $ProviderSourceFacts = @{},
        [string[]] $ProviderConfigurationFacts = @(),
        [string[]] $ProviderAliasFacts = @(),
        [AllowEmptyCollection()] [string[]] $CallsRequiringAzapi = @(),
        [switch] $ProviderFactsComplete,
        [bool] $ApplyUtilityMigration = $true
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $variables = [ordered]@{
        provider_source_facts        = $ProviderSourceFacts
        provider_configuration_facts = @($ProviderConfigurationFacts)
        provider_alias_facts         = @($ProviderAliasFacts)
        calls_requiring_azapi        = @($CallsRequiringAzapi)
        provider_facts_complete      = [bool]$ProviderFactsComplete
        apply_utility_migration      = [bool]$ApplyUtilityMigration
    }
    $arguments = @(
        'transform', '--tf-dir', $Path, '--mptf-dir', $Options.ProfileDirs['utility-module'],
        '--mptf-var', ('target_scope="{0}"' -f $Scope)
    )
    foreach ($entry in $variables.GetEnumerator()) {
        $json = (ConvertTo-Json -InputObject $entry.Value -Depth 10 -Compress).Replace('${', '$${').Replace('%{', '%%{')
        $arguments += @('--mptf-var', "$($entry.Key)=$json")
    }
    if ($PSCmdlet.ShouldProcess($Path, 'apply native utility source, version, and input migration')) {
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

function Get-AvmTerraformUtilityProviderConfigurationFact {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    Set-StrictMode -Version 3.0
    $facts = @{
        Configurations = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        Aliases        = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    }
    foreach ($file in Get-ChildItem -LiteralPath $Path -File -Filter '*.tf') {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        foreach ($match in [regex]::Matches($text, '(?m)^\s*provider\s+"(?<name>modtm|random)"\s*\{')) {
            $null = $facts.Configurations.Add($match.Groups['name'].Value)
        }
        if ($text -match '(?m)^\s*configuration_aliases\s*=') {
            $null = $facts.Aliases.Add('modtm')
            $null = $facts.Aliases.Add('random')
        }
    }
    return $facts
}

function Assert-AvmTerraformUtilityProviderMappingReview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object] $Options,
        [Parameter(Mandatory)] [hashtable] $ProviderSourceFacts,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $CallsRequiringAzapi
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $facts = Get-AvmTerraformUtilityProviderConfigurationFact -Path $Path
    $arguments = @(
        'debug', '--tf-dir', $Path, '--mptf-dir', $Options.ProfileDirs['utility-module'],
        '--mptf-var', ('provider_source_facts={0}' -f (ConvertTo-Json -InputObject $ProviderSourceFacts -Depth 10 -Compress)),
        '--mptf-var', ('provider_configuration_facts={0}' -f (ConvertTo-Json -InputObject @($facts.Configurations) -Compress)),
        '--mptf-var', ('provider_alias_facts={0}' -f (ConvertTo-Json -InputObject @($facts.Aliases) -Compress)),
        '--mptf-var', ('calls_requiring_azapi={0}' -f (ConvertTo-Json -InputObject @($CallsRequiringAzapi) -Compress)),
        '--eval', 'local.provider_mapping_review'
    )
    $result = Invoke-AvmProcess -FilePath $Options.ToolPath -ArgumentList $arguments `
        -WorkingDirectory $Path -EnvVars $Options.EnvVars
    try {
        $review = ConvertFrom-Json -InputObject $result.StdOut -AsHashtable -ErrorAction Stop
    }
    catch {
        throw [AvmConfigurationException]::new(
            "Cannot inspect utility provider mappings in '$Path': invalid native JSON. $($_.Exception.Message)")
    }
    if ($review.Count -gt 0) {
        $names = @($review.Keys | Sort-Object) -join "', '"
        throw [AvmConfigurationException]::new(
            "Utility module '$names' in '$Path' has a provider mapping that requires review: use literal provider keys before automatic migration.")
    }
    return $facts
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
        if (-not $PSCmdlet.ShouldProcess($scope.Target.Path, 'reconcile utility modules and provider contracts before telemetry transformation')) {
            continue
        }
        $inspection = Get-AvmTerraformUtilityInspection -Path $scope.Target.Path -Options $Options -Scope $scope.Target.Scope
        $providerSourceFacts = @{}
        foreach ($name in $scope.Calls.Keys) {
            $plan = $scope.Calls[$name]
            $call = $inspection.calls[$name]
            if (-not $call.Contains('providers')) { continue }
            $providerCall = [pscustomobject]@{
                Source = $plan.ProviderSource; Version = $plan.ProviderVersion; Telemetry = $plan.Telemetry
            }
            $sources = @(Get-AvmTerraformUtilityProviderSource -Call $providerCall -Options $Options -Cache $cache)
            if (@($sources | Where-Object { $_ -match '/modtm$' -and $_ -ine 'registry.terraform.io/azure/modtm' }).Count -gt 0) {
                throw [AvmConfigurationException]::new(
                    "Cannot migrate utility module '$name' in '$($scope.Target.Path)': an unexpected ModTM provider source requires review.")
            }
            $providerSourceFacts[$name] = $sources
        }
        $localTelemetryCalls = @($scope.Dependencies.Keys | Where-Object { $scope.Dependencies[$_] -cin $telemetryPaths })
        $azapiCalls = @($scope.Calls.Keys | Where-Object { $scope.Calls[$_].Telemetry }) + $localTelemetryCalls
        $facts = Assert-AvmTerraformUtilityProviderMappingReview -Path $scope.Target.Path -Options $Options `
            -ProviderSourceFacts $providerSourceFacts -CallsRequiringAzapi $azapiCalls
        Invoke-AvmTerraformUtilityNativeMigration -Path $scope.Target.Path -Scope $scope.Target.Scope -Options $Options `
            -ProviderSourceFacts $providerSourceFacts -ProviderConfigurationFacts @($facts.Configurations) `
            -ProviderAliasFacts @($facts.Aliases) -CallsRequiringAzapi $azapiCalls -ApplyUtilityMigration:($scope.Calls.Count -gt 0)
    }
}

function Sync-AvmTerraformLocalProviderMapping {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Plans,
        [Parameter(Mandatory)] [object] $Options,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $DependencyPaths
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $requirements = @{}
    foreach ($scope in $Plans) {
        $providerSourceFacts = @{}
        foreach ($name in $scope.Dependencies.Keys) {
            $dependency = $scope.Dependencies[$name]
            if ($dependency -cnotin $DependencyPaths) { continue }
            if (-not $requirements.ContainsKey($dependency)) {
                $requirements[$dependency] = Get-AvmTerraformUnitTestRequiredProvider -Path $dependency -Options $Options
            }
            if (-not $requirements[$dependency].Contains('modtm')) {
                $providerSourceFacts[$name] = @()
            }
        }
        if ($providerSourceFacts.Count -eq 0 -or
            -not $PSCmdlet.ShouldProcess($scope.Target.Path, 'retire unsupported default ModTM mappings before dependency inspection')) {
            continue
        }
        $facts = Assert-AvmTerraformUtilityProviderMappingReview -Path $scope.Target.Path -Options $Options `
            -ProviderSourceFacts $providerSourceFacts -CallsRequiringAzapi @()
        Invoke-AvmTerraformUtilityNativeMigration -Path $scope.Target.Path -Scope $scope.Target.Scope -Options $Options `
            -ProviderSourceFacts $providerSourceFacts -ProviderConfigurationFacts @($facts.Configurations) `
            -ProviderAliasFacts @($facts.Aliases) -ApplyUtilityMigration:$false
    }
}

function Invoke-AvmTerraformUtilityProviderCleanup {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Plans,
        [Parameter(Mandatory)] [object[]] $ModuleTargets,
        [Parameter(Mandatory)] [object] $Options,
        [hashtable] $RetainedProviderSources
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
    Sync-AvmTerraformLocalProviderMapping -Plans $Plans -Options $Options `
        -DependencyPaths @($Plans | ForEach-Object { $_.Target.Path })
    foreach ($scope in $Plans) {
        $path = $scope.Target.Path
        if (-not $PSCmdlet.ShouldProcess($path, 'retire utility-only provider references using fresh dependency evidence')) { continue }
        $inspection = Get-AvmTerraformUtilityInspection -Path $path -Options $Options
        $providerSourceFacts = @{}
        foreach ($name in $scope.Dependencies.Keys) {
            $dependency = $scope.Dependencies[$name]
            if (-not $sources.ContainsKey($dependency)) { continue }
            $unexpectedModtmSources = @($sources[$dependency] | Where-Object {
                    $_ -match '/modtm$' -and $_ -ine 'registry.terraform.io/azure/modtm'
                })
            if ($unexpectedModtmSources.Count -gt 0) {
                throw [AvmConfigurationException]::new(
                    "Cannot migrate local utility module '$name' in '$path': an unexpected ModTM provider source requires review.")
            }
            $providerSourceFacts[$name] = @($sources[$dependency])
        }
        $azapiCalls = @($providerSourceFacts.Keys | Where-Object {
                $providerSourceFacts[$_] -contains 'registry.terraform.io/azure/azapi'
            })
        $facts = Assert-AvmTerraformUtilityProviderMappingReview -Path $path -Options $Options `
            -ProviderSourceFacts $providerSourceFacts -CallsRequiringAzapi $azapiCalls
        Invoke-AvmTerraformUtilityNativeMigration -Path $path -Scope $scope.Target.Scope -Options $Options `
            -ProviderSourceFacts $providerSourceFacts -ProviderConfigurationFacts @($facts.Configurations) `
            -ProviderAliasFacts @($facts.Aliases) -CallsRequiringAzapi $azapiCalls -ApplyUtilityMigration:$false
        $moduleSources[$path] = @{}
        $sources[$path] = @(Get-AvmTerraformUnitTestProviderSource -Path $path -ModuleTargets $ModuleTargets -Options $Options `
                -ModuleProviderSources $moduleSources[$path] -ModuleManifests $manifests `
                -AllowMissingProviderConfiguration -ProviderWarnings $providerWarnings)
        $facts = Get-AvmTerraformUtilityProviderConfigurationFact -Path $path
        Invoke-AvmTerraformUtilityNativeMigration -Path $path -Scope $scope.Target.Scope -Options $Options `
            -ProviderSourceFacts $moduleSources[$path] -ProviderConfigurationFacts @($facts.Configurations) `
            -ProviderAliasFacts @($facts.Aliases) -ProviderFactsComplete -ApplyUtilityMigration:$false
        Sync-AvmTerraformLocalProviderMapping -Plans $Plans -Options $Options -DependencyPaths @($path)
        $inspection = Get-AvmTerraformUtilityInspection -Path $path -Options $Options
        $requirements[$path] = $inspection.requirements
        $sources[$path] = @(Get-AvmTerraformUnitTestProviderSource -Path $path -ModuleTargets $ModuleTargets -Options $Options `
                -ModuleProviderSources $moduleSources[$path] -ModuleManifests $manifests `
                -AllowMissingProviderConfiguration -ProviderWarnings $providerWarnings)
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
        if ($null -ne $RetainedProviderSources) {
            $RetainedProviderSources[$path] = @($moduleSources[$path].Values | ForEach-Object { $_ } | Sort-Object -Unique)
        }
        Invoke-AvmMapotfTransformTarget -Target ([pscustomobject]@{
                Path = $path; Scope = $scope.Target.Scope; Profiles = @('variable-order', 'common')
            }) -Options $Options
    }
}
