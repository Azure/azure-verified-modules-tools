function Get-AvmTerraformTestFileScope {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [object[]] $ModuleTargets
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    foreach ($file in Get-AvmTerraformFile -Root $Root |
            Where-Object { $_.Name.EndsWith('.tftest.hcl', [System.StringComparison]::OrdinalIgnoreCase) }) {
        $owner = $ModuleTargets |
            Where-Object {
                ($_.Profiles -contains 'root' -or $_.Profiles -contains 'module') -and
                $file.FullName.StartsWith(
                    ($_.Path + [System.IO.Path]::DirectorySeparatorChar),
                    [System.StringComparison]::Ordinal)
            } |
            Sort-Object { $_.Path.Length } -Descending |
            Select-Object -First 1
        if ($null -eq $owner) {
            throw [AvmConfigurationException]::new(
                "Cannot determine the Terraform module that owns test file '$($file.FullName)'.")
        }
        $relative = [System.IO.Path]::GetRelativePath($owner.Path, $file.FullName).Replace('\', '/')
        [pscustomobject]@{
            File         = $file
            Owner        = $owner
            RelativePath = $relative
            IsUnitTest   = $relative -cmatch '^tests/unit/[^/]+\.tftest\.hcl$'
        }
    }
}

function Get-AvmTerraformUnitTestInspection {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [object] $Scope,
        [Parameter(Mandatory)] [object[]] $ModuleTargets,
        [Parameter(Mandatory)] [object] $Options
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $directories = @($ModuleTargets | ForEach-Object { $_.Path })
    $encoded = (ConvertTo-Json -InputObject $directories -Compress).Replace('${', '$${').Replace('%{', '%%{')
    $result = Invoke-AvmProcess -FilePath $Options.ToolPath -ArgumentList @(
        'debug', '--tf-dir', $Scope.Owner.Path, '--test-file', $Scope.RelativePath,
        '--mptf-dir', $Options.ProfileDirs['unit-test-inspect'],
        '--mptf-var', ("allowed_module_directories=$encoded"),
        '--eval', '{ test = data.test_file.this.result, modules = { for directory in local.local_target_directories : directory => data.module_source.targets[directory] } }'
    ) -WorkingDirectory $Scope.Owner.Path -EnvVars $Options.EnvVars
    try {
        $inspection = ConvertFrom-Json -InputObject $result.StdOut -AsHashtable -ErrorAction Stop
    }
    catch {
        throw [AvmConfigurationException]::new(
            "Cannot inspect Terraform unit test '$($Scope.File.FullName)': invalid MaPoTF JSON. $($_.Exception.Message)")
    }
    if ($inspection -isnot [System.Collections.IDictionary] -or
        $inspection['test'] -isnot [System.Collections.IDictionary] -or
        $inspection['modules'] -isnot [System.Collections.IDictionary]) {
        throw [AvmConfigurationException]::new(
            "Cannot inspect Terraform unit test '$($Scope.File.FullName)': incomplete MaPoTF inspection.")
    }
    foreach ($name in @('runs', 'run_modules', 'mock_providers', 'providers')) {
        if ($inspection.test[$name] -isnot [System.Collections.IDictionary]) {
            throw [AvmConfigurationException]::new(
                "Cannot inspect Terraform unit test '$($Scope.File.FullName)': missing '$name' inspection.")
        }
    }
    if (-not $inspection.test.Contains('variables') -or
        ($null -ne $inspection.test.variables -and
        ($inspection.test.variables -isnot [System.Collections.IDictionary] -or
        $inspection.test.variables['mptf'] -isnot [System.Collections.IDictionary] -or
        $inspection.test.variables.mptf['attributes'] -isnot [System.Collections.IDictionary]))) {
        throw [AvmConfigurationException]::new(
            "Cannot inspect Terraform unit test '$($Scope.File.FullName)': invalid global variables inspection.")
    }
    foreach ($name in $inspection.test.run_modules.Keys) {
        $target = $inspection.test.run_modules[$name]
        if ($target -isnot [System.Collections.IDictionary] -or
            $target['kind'] -cnotin @('root', 'local') -or
            $target['dir'] -isnot [string] -or $target.dir -cnotin $directories -or
            -not $inspection.modules.Contains($target.dir) -or
            $inspection.modules[$target.dir] -isnot [System.Collections.IDictionary] -or
            $inspection.modules[$target.dir]['variables'] -isnot [System.Collections.IDictionary] -or
            -not $inspection.test.runs.Contains($name)) {
            throw [AvmConfigurationException]::new(
                "Cannot automatically migrate unit test '$($Scope.File.FullName)' run '$name': the target must be a known local module in this repository.")
        }
        $run = $inspection.test.runs[$name]
        if ($run -isnot [System.Collections.IDictionary] -or
            $run['mptf'] -isnot [System.Collections.IDictionary] -or
            $run.mptf['attributes'] -isnot [System.Collections.IDictionary] -or
            ($run.Contains('variables') -and
            (@($run.variables).Count -ne 1 -or
            $run.variables[0] -isnot [System.Collections.IDictionary] -or
            $run.variables[0]['mptf'] -isnot [System.Collections.IDictionary] -or
            $run.variables[0].mptf['attributes'] -isnot [System.Collections.IDictionary]))) {
            throw [AvmConfigurationException]::new(
                "Cannot inspect Terraform unit test '$($Scope.File.FullName)' run '$name': invalid run variables inspection.")
        }
        $variables = $inspection.modules[$target.dir].variables
        if ($variables.Contains('location') -and
            ($variables.location -isnot [System.Collections.IDictionary] -or
            $variables.location['required'] -isnot [bool])) {
            throw [AvmConfigurationException]::new(
                "Cannot inspect Terraform unit test '$($Scope.File.FullName)' run '$name': invalid location declaration inspection.")
        }
    }
    if ($inspection.test.runs.Count -ne $inspection.test.run_modules.Count) {
        throw [AvmConfigurationException]::new(
            "Cannot inspect Terraform unit test '$($Scope.File.FullName)': run targets are incomplete.")
    }
    return $inspection
}

function Get-AvmTerraformUnitTestSnapshot {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [object[]] $ModuleTargets,
        [Parameter(Mandatory)] [object] $Options
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    foreach ($scope in Get-AvmTerraformTestFileScope -Root $Root -ModuleTargets $ModuleTargets |
            Where-Object IsUnitTest) {
        [pscustomobject]@{
            Scope  = $scope
            Hash   = (Get-FileHash -LiteralPath $scope.File.FullName -Algorithm SHA256).Hash
            Before = Get-AvmTerraformUnitTestInspection -Scope $scope -ModuleTargets $ModuleTargets -Options $Options
        }
    }
}

function Get-AvmTerraformTelemetryMockResourceId {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Test,
        [Parameter(Mandatory)] [string] $Path
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if (-not $Test.mock_providers.Contains('azapi')) {
        return $null
    }
    $mock = $Test.mock_providers.azapi
    if ($mock -isnot [System.Collections.IDictionary] -or
        $mock['mptf'] -isnot [System.Collections.IDictionary] -or
        $mock.mptf['is_empty'] -isnot [bool]) {
        throw [AvmConfigurationException]::new(
            "Cannot inspect Terraform unit test '$Path': invalid AzAPI mock inspection.")
    }
    $subscriptionId = '00000000-0000-0000-0000-000000000000'
    if ($mock.mptf.is_empty) {
        return "/subscriptions/$subscriptionId"
    }
    if ($mock.mptf['attributes'] -isnot [System.Collections.IDictionary]) {
        throw [AvmConfigurationException]::new(
            "Cannot inspect Terraform unit test '$Path': invalid AzAPI mock attributes.")
    }
    $clientConfigs = @(
        foreach ($data in @($mock['mock_data'])) {
            if ($null -eq $data) { continue }
            if ($data -isnot [System.Collections.IDictionary] -or
                $data['mptf'] -isnot [System.Collections.IDictionary] -or
                $data.mptf['block_labels'] -isnot [System.Collections.IList] -or
                @($data.mptf['block_labels']).Count -ne 1 -or
                $data.mptf['attributes'] -isnot [System.Collections.IDictionary]) {
                throw [AvmConfigurationException]::new(
                    "Cannot inspect Terraform unit test '$Path': invalid AzAPI mock_data inspection.")
            }
            if ($data.mptf.block_labels[0] -ceq 'azapi_client_config') { $data }
        }
    )
    if ($clientConfigs.Count -gt 1) {
        throw [AvmConfigurationException]::new(
            "Cannot automatically migrate unit test '$Path': multiple azapi_client_config mocks require review.")
    }
    $defaults = @{}
    if ($clientConfigs.Count -eq 1 -and $clientConfigs[0].mptf.attributes.Contains('defaults')) {
        $defaults = $clientConfigs[0].mptf.attributes.defaults
        if ($defaults -isnot [System.Collections.IDictionary]) {
            throw [AvmConfigurationException]::new(
                "Cannot automatically migrate unit test '$Path': azapi_client_config defaults must be a statically inspectable object literal before adding subscription_resource_id.")
        }
    }
    if ($defaults.Contains('subscription_resource_id')) {
        return $null
    }
    if ($mock.mptf.attributes.Contains('source')) {
        throw [AvmConfigurationException]::new(
            "Cannot automatically migrate unit test '$Path': source-based AzAPI mocks require review before adding subscription_resource_id.")
    }
    if ($defaults.Contains('subscription_id')) {
        $subscriptionId = $defaults.subscription_id
        if ($subscriptionId -isnot [string] -or
            $subscriptionId -cnotmatch '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z') {
            throw [AvmConfigurationException]::new(
                "Cannot automatically migrate unit test '$Path': author a full subscription_resource_id when subscription_id is not a literal GUID.")
        }
    }
    return "/subscriptions/$subscriptionId"
}

function Get-AvmTerraformUnitTestRequiredProvider {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object] $Options
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $result = Invoke-AvmProcess -FilePath $Options.ToolPath -ArgumentList @(
        'debug', '--tf-dir', $Path, '--mptf-dir', $Options.ProfileDirs['module'],
        '--eval', 'data.terraform.this.required_providers'
    ) -WorkingDirectory $Path -EnvVars $Options.EnvVars
    try {
        $providers = ConvertFrom-Json -InputObject $result.StdOut -AsHashtable -ErrorAction Stop
    }
    catch {
        throw [AvmConfigurationException]::new(
            "Cannot inspect provider requirements for unit-test target '$Path': invalid MaPoTF JSON. $($_.Exception.Message)")
    }
    if ($providers -isnot [System.Collections.IDictionary]) {
        throw [AvmConfigurationException]::new(
            "Cannot inspect provider requirements for unit-test target '$Path': update MaPoTF and the module profile to expose native required_providers metadata.")
    }
    foreach ($provider in $providers.Values) {
        if ($provider -isnot [System.Collections.IDictionary] -or
            ($null -ne $provider['source'] -and $provider['source'] -isnot [string])) {
            throw [AvmConfigurationException]::new(
                "Cannot inspect provider requirements for unit-test target '$Path': invalid provider source metadata.")
        }
    }
    return $providers
}

function Test-AvmTerraformUnitTestProviderMapping {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [object] $Expression,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $ProviderNames
    )

    Set-StrictMode -Version 3.0
    if ($Expression -isnot [string]) {
        return $false
    }
    $trivia = '(?>(?:\s|#[^\r\n]*|//[^\r\n]*|/\*[\s\S]*?\*/)*)'
    $identifier = '[A-Za-z_][A-Za-z0-9_-]*'
    $entry = '(?:"(?<name>' + $identifier + ')"|(?<name>' + $identifier + '))' +
    $trivia + '=' + $trivia + '\k<name>'
    $pattern = '\A' + $trivia + '\{' + $trivia + '(?:' + $entry + $trivia +
    '(?:,' + $trivia + ')?)*\}' + $trivia + '\z'
    $match = [regex]::Match($Expression, $pattern,
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant, [TimeSpan]::FromSeconds(1))
    if (-not $match.Success) {
        return $false
    }
    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($capture in $match.Groups['name'].Captures) {
        if (-not $names.Add($capture.Value)) {
            return $false
        }
    }
    return $names.SetEquals($ProviderNames)
}

function ConvertFrom-AvmTerraformProviderTree {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text,
        [Parameter(Mandatory)] [string] $Path
    )

    Set-StrictMode -Version 3.0
    $sources = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $inConfiguration = $false
    $rootSeen = $false
    $testDepth = -1
    foreach ($line in $Text -split '\r?\n') {
        if (-not $inConfiguration) {
            if ($line -ceq 'Providers required by configuration:') {
                $inConfiguration = $true
            }
            continue
        }
        if ($line -ceq 'Providers required by state:') { break }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -ceq '.' -and -not $rootSeen) {
            $rootSeen = $true
            continue
        }
        $node = [regex]::Match($line,
            '\A(?<prefix>[\u2502\u251c\u2514\u2500 \u00a0]+)(?<kind>provider|module|test|run)(?<value>.*)\z')
        if (-not $rootSeen -or -not $node.Success -or $node.Groups['prefix'].Length % 4 -ne 0) {
            throw [AvmConfigurationException]::new(
                "Cannot inspect provider dependencies for '$Path': unexpected Terraform provider tree.")
        }
        $depth = $node.Groups['prefix'].Length / 4
        if ($testDepth -ge 0 -and $depth -gt $testDepth) { continue }
        $testDepth = -1
        $kind = $node.Groups['kind'].Value
        $value = $node.Groups['value'].Value
        if ($kind -ceq 'test' -and $value.StartsWith('.')) {
            $testDepth = $depth
            continue
        }
        if ($kind -ceq 'module' -and $value.StartsWith('.')) { continue }
        $provider = [regex]::Match($value,
            '\A\[(?<source>[A-Za-z0-9._:-]+/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+)\](?:\s+.*)?\z')
        if ($kind -cne 'provider' -or -not $provider.Success) {
            throw [AvmConfigurationException]::new(
                "Cannot inspect provider dependencies for '$Path': unexpected Terraform provider node.")
        }
        $null = $sources.Add($provider.Groups['source'].Value)
    }
    if (-not $inConfiguration -or -not $rootSeen) {
        throw [AvmConfigurationException]::new(
            "Cannot inspect provider dependencies for '$Path': missing Terraform configuration tree.")
    }
    return [string[]]@($sources)
}

function Get-AvmTerraformUnitTestProviderSource {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object[]] $ModuleTargets,
        [Parameter(Mandatory)] [object] $Options
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $files = @(Get-ChildItem -LiteralPath $Path -File)
    $trivia = '(?:\s|#[^\r\n]*|//[^\r\n]*|/\*[\s\S]*?\*/)'
    $stateDeclaration = '\b(?:backend|state_store|state_store_provider)' + $trivia + '+"' +
    '|\bcloud' + $trivia + '*\{'
    foreach ($file in $files) {
        if ($file.Name.EndsWith('.tf.json', [System.StringComparison]::OrdinalIgnoreCase) -or
            ($file.Name.EndsWith('.tf', [System.StringComparison]::OrdinalIgnoreCase) -and
            [regex]::IsMatch([System.IO.File]::ReadAllText($file.FullName), $stateDeclaration,
                [System.Text.RegularExpressions.RegexOptions]::CultureInvariant, [TimeSpan]::FromSeconds(1)))) {
            throw [AvmConfigurationException]::new(
                "Cannot inspect provider dependencies for '$Path': review JSON configuration or possible backend/cloud declarations before running dependency inspection.")
        }
    }
    if (Test-Path -LiteralPath (Join-Path -Path $Path -ChildPath '.terraform' -AdditionalChildPath 'terraform.tfstate')) {
        throw [AvmConfigurationException]::new(
            "Cannot inspect provider dependencies for '$Path': an initialized backend requires review; dependency inspection must not access remote state.")
    }
    $testFiles = @($files | Where-Object { $_.Name -like '*.tftest.hcl' -or $_.Name -like '*.tftest.json' })
    $testDirectory = Join-Path $Path 'tests'
    if (Test-Path -LiteralPath $testDirectory -PathType Container) {
        $testFiles += @(Get-ChildItem -LiteralPath $testDirectory -File |
                Where-Object { $_.Name -like '*.tftest.hcl' -or $_.Name -like '*.tftest.json' })
    }
    foreach ($file in $testFiles) {
        if ($file.Name.EndsWith('.json', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw [AvmConfigurationException]::new(
                "Cannot inspect provider dependencies for '$Path': review JSON test '$($file.FullName)' before installing module dependencies.")
        }
        $scope = [pscustomobject]@{
            File         = $file
            Owner        = [pscustomobject]@{ Path = $Path }
            RelativePath = [System.IO.Path]::GetRelativePath($Path, $file.FullName).Replace('\', '/')
        }
        $null = Get-AvmTerraformUnitTestInspection -Scope $scope -ModuleTargets $ModuleTargets -Options $Options
    }
    $environment = $Options.EnvVars.Clone()
    foreach ($name in @('TF_DATA_DIR', 'TF_CLI_ARGS', 'TF_CLI_ARGS_init', 'TF_CLI_ARGS_providers')) {
        $environment[$name] = $null
    }
    $lockPath = Join-Path $Path '.terraform.lock.hcl'
    $lockExists = Test-Path -LiteralPath $lockPath -PathType Leaf
    [byte[]]$lockContent = @()
    if ($lockExists) {
        $lockContent = [System.IO.File]::ReadAllBytes($lockPath)
    }
    try {
        $null = Invoke-AvmTerraformInit -TerraformPath $Options.TerraformPath -WorkingDirectory $Path `
            -EnvVars $environment -BackendFalse -NoColor -PreserveDependencySelections `
            -Label 'terraform init (unit-test provider dependencies)'
        $result = Invoke-AvmProcess -FilePath $Options.TerraformPath `
            -ArgumentList @('providers', '-no-color', '-test-directory=tests') `
            -WorkingDirectory $Path -EnvVars $environment
        ConvertFrom-AvmTerraformProviderTree -Text $result.StdOut -Path $Path
    }
    finally {
        if ($lockExists) {
            [System.IO.File]::WriteAllBytes($lockPath, $lockContent)
        }
        elseif (Test-Path -LiteralPath $lockPath -PathType Leaf) {
            Remove-Item -LiteralPath $lockPath -Force -ErrorAction Stop
        }
    }
}

function Get-AvmTerraformUnitTestMockProviderName {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $ProviderNames,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $RequiredProviders,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $ProviderSources
    )

    Set-StrictMode -Version 3.0
    foreach ($name in $ProviderNames) {
        $source = if ($RequiredProviders.Contains($name)) { $RequiredProviders[$name]['source'] } else { $null }
        if ([string]::IsNullOrWhiteSpace($source)) {
            $source = "hashicorp/$name"
        }
        if (@($source -split '/').Count -eq 2) {
            $source = "registry.terraform.io/$source"
        }
        if ($source -in $ProviderSources) {
            $name
        }
    }
}

function Invoke-AvmTerraformUnitTestMigration {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [object[]] $ModuleTargets,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Snapshots,
        [Parameter(Mandatory)] [object] $Options
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if (-not $PSCmdlet.ShouldProcess($Root, 'migrate scoped Terraform unit tests')) {
        return
    }
    $plans = [System.Collections.Generic.List[object]]::new()
    $randomUse = @{}
    $requiredProviders = @{}
    $providerSources = @{}
    foreach ($snapshot in $Snapshots) {
        $scope = $snapshot.Scope
        if ((Get-FileHash -LiteralPath $scope.File.FullName -Algorithm SHA256).Hash -cne $snapshot.Hash) {
            throw [AvmConfigurationException]::new(
                "Unit test '$($scope.File.FullName)' changed while its modules were transformed; review it before retrying.")
        }
        $after = Get-AvmTerraformUnitTestInspection -Scope $scope -ModuleTargets $ModuleTargets -Options $Options
        if ($after.test.run_modules.Count -ne $snapshot.Before.test.run_modules.Count) {
            throw [AvmConfigurationException]::new(
                "Unit test '$($scope.File.FullName)' changed its run targets during migration.")
        }
        $newLocations = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $targetPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $globalLocationAuthored = $null -ne $after.test.variables -and
        $after.test.variables.mptf.attributes.Contains('location')
        foreach ($name in $after.test.run_modules.Keys) {
            $target = $after.test.run_modules[$name]
            if (-not $snapshot.Before.test.run_modules.Contains($name) -or
                $snapshot.Before.test.run_modules[$name].dir -cne $target.dir) {
                throw [AvmConfigurationException]::new(
                    "Unit test '$($scope.File.FullName)' run '$name' changed its module target during migration.")
            }
            $null = $targetPaths.Add($target.dir)
            $beforeVariables = $snapshot.Before.modules[$target.dir].variables
            $afterVariables = $after.modules[$target.dir].variables
            $run = $after.test.runs[$name]
            $runLocationAuthored = $run.Contains('variables') -and
            $run.variables[0].mptf.attributes.Contains('location')
            if (-not $beforeVariables.Contains('location') -and $afterVariables.Contains('location') -and
                $afterVariables.location.required -eq $true -and
                -not $globalLocationAuthored -and -not $runLocationAuthored) {
                $null = $newLocations.Add($target.dir)
            }
        }
        $instrumentedTargets = @($ModuleTargets |
                Where-Object { $targetPaths.Contains($_.Path) -and $_.Profiles -contains 'root' })
        $migratesTelemetry = $scope.Owner.Profiles -contains 'root' -or $instrumentedTargets.Count -gt 0
        $telemetryResourceId = if ($migratesTelemetry) {
            Get-AvmTerraformTelemetryMockResourceId -Test $after.test -Path $scope.File.FullName
        }
        else { $null }
        $hasEmptyModtm = $after.test.mock_providers.Contains('modtm') -and
        $after.test.mock_providers.modtm.mptf.is_empty
        $hasEmptyAzapi = $after.test.mock_providers.Contains('azapi') -and
        $after.test.mock_providers.azapi.mptf.is_empty
        $hasRandomMock = @($after.test.mock_providers.Keys | Where-Object { $_ -cmatch '^random(\.|$)' }).Count -gt 0
        $randomMockRetained = $hasRandomMock -and (-not $migratesTelemetry -or
            (Test-AvmTerraformScopedRandomProviderInUse -Scope $scope -ModuleTargets $ModuleTargets `
                -TargetPaths @($targetPaths) -Cache $randomUse))
        $missingRandomRequirements = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        if ($migratesTelemetry -and $randomMockRetained) {
            foreach ($target in $instrumentedTargets) {
                if (-not $requiredProviders.ContainsKey($target.Path)) {
                    $requiredProviders[$target.Path] = Get-AvmTerraformUnitTestRequiredProvider `
                        -Path $target.Path -Options $Options
                }
                if (-not $requiredProviders[$target.Path].Contains('random')) {
                    if (-not $providerSources.ContainsKey($target.Path)) {
                        $providerSources[$target.Path] = @(Get-AvmTerraformUnitTestProviderSource `
                                -Path $target.Path -ModuleTargets $ModuleTargets -Options $Options)
                    }
                    if ($providerSources[$target.Path] -contains 'registry.terraform.io/hashicorp/random') {
                        $null = $missingRandomRequirements.Add($target.Path)
                    }
                }
            }
        }
        $providerNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($name in $after.test.mock_providers.Keys) {
            if (($migratesTelemetry -and $name -ceq 'modtm') -or
                ($name -ceq 'random' -and -not $randomMockRetained)) {
                continue
            }
            $null = $providerNames.Add($name)
        }
        if ($migratesTelemetry -and $hasEmptyModtm) {
            $null = $providerNames.Add('azapi')
        }
        [string[]]$mockProviderNames = @($providerNames)
        [Array]::Sort($mockProviderNames, [System.StringComparer]::Ordinal)
        $providerMockBindings = @{}
        foreach ($name in $after.test.run_modules.Keys) {
            $targetPath = $after.test.run_modules[$name].dir
            if ($missingRandomRequirements.Contains($targetPath) -and
                -not $after.test.runs[$name].mptf.attributes.Contains('providers')) {
                $providerMockBindings[$name] = @(Get-AvmTerraformUnitTestMockProviderName `
                        -ProviderNames $mockProviderNames -RequiredProviders $requiredProviders[$targetPath] `
                        -ProviderSources $providerSources[$targetPath])
            }
        }
        if ($newLocations.Count -gt 0 -or
            $missingRandomRequirements.Count -gt 0 -or
            ($migratesTelemetry -and ($hasEmptyModtm -or $hasEmptyAzapi -or $null -ne $telemetryResourceId))) {
            $requiresAzapiMock = $missingRandomRequirements.Count -gt 0 -or
            @($instrumentedTargets | Where-Object { $newLocations.Contains($_.Path) }).Count -gt 0
            $hasAzureMock = $after.test.mock_providers.Contains('azapi') -or
            (-not $requiresAzapiMock -and $after.test.mock_providers.Contains('azurerm')) -or
            ($migratesTelemetry -and $hasEmptyModtm)
            $realProviders = @($after.test.providers.Keys | Where-Object {
                    $missingRandomRequirements.Count -gt 0 -or $_ -cmatch '^(azapi|azurerm)(\.|$)'
                })
            $aliasedMocks = @($after.test.mock_providers.Keys | Where-Object {
                    $_ -cmatch '^(azapi|azurerm|modtm)\.' -or
                    ($missingRandomRequirements.Count -gt 0 -and $_ -cnotmatch '\A[A-Za-z_][A-Za-z0-9_-]*\z')
                })
            $unsafeMappings = @(
                foreach ($name in $after.test.runs.Keys) {
                    $run = $after.test.runs[$name]
                    if (-not $run.mptf.attributes.Contains('providers')) { continue }
                    $targetPath = $after.test.run_modules[$name].dir
                    if (-not $requiredProviders.ContainsKey($targetPath)) {
                        $requiredProviders[$targetPath] = Get-AvmTerraformUnitTestRequiredProvider `
                            -Path $targetPath -Options $Options
                    }
                    if (-not $providerSources.ContainsKey($targetPath)) {
                        $providerSources[$targetPath] = @(Get-AvmTerraformUnitTestProviderSource `
                                -Path $targetPath -ModuleTargets $ModuleTargets -Options $Options)
                    }
                    $names = @(Get-AvmTerraformUnitTestMockProviderName -ProviderNames $mockProviderNames `
                            -RequiredProviders $requiredProviders[$targetPath] -ProviderSources $providerSources[$targetPath])
                    if (-not (Test-AvmTerraformUnitTestProviderMapping -Expression $run.mptf.attributes.providers -ProviderNames $names)) {
                        $name
                    }
                }
            )
            if (-not $hasAzureMock -or $realProviders.Count -gt 0 -or
                $aliasedMocks.Count -gt 0 -or $unsafeMappings.Count -gt 0) {
                throw [AvmConfigurationException]::new(
                    "Cannot automatically migrate unit test '$($scope.File.FullName)': use unaliased mocks for introduced providers, without real-provider declarations or partial/remapped run provider mappings.")
            }
        }
        $encoded = (ConvertTo-Json -InputObject @($newLocations) -Compress).Replace('${', '$${').Replace('%{', '%%{')
        $arguments = @(
            'transform', '--tf-dir', $scope.Owner.Path, '--test-file', $scope.RelativePath,
            '--mptf-dir', $Options.ProfileDirs['unit-test'],
            '--mptf-var', ("new_location_modules=$encoded")
        )
        if ($null -ne $telemetryResourceId) {
            $resourceIdJson = ConvertTo-Json -InputObject $telemetryResourceId -Compress
            $arguments += @('--mptf-var', "telemetry_subscription_resource_id=$resourceIdJson")
        }
        if ($providerMockBindings.Count -gt 0) {
            $bindingsJson = (ConvertTo-Json -InputObject $providerMockBindings -Depth 5 -Compress).Replace('${', '$${').Replace('%{', '%%{')
            $arguments += @('--mptf-var', "provider_mock_bindings=$bindingsJson")
        }
        $plans.Add([pscustomobject]@{
                Path                            = $scope.File.FullName
                Scope                           = $scope
                TargetPaths                     = @($targetPaths)
                NewLocationPaths                = @($newLocations)
                TelemetrySubscriptionResourceId = $telemetryResourceId
                ProviderMockBindings            = $providerMockBindings
                Arguments                       = $arguments
            })
    }

    foreach ($plan in $plans | Where-Object {
            $null -ne $_.TelemetrySubscriptionResourceId -or $_.ProviderMockBindings.Count -gt 0
        }) {
        $capabilities = [System.Collections.Generic.List[string]]::new()
        $capabilityName = 'label-safe object merging'
        if ($null -ne $plan.TelemetrySubscriptionResourceId) {
            $capabilities.Add(
                'try(transform.update_in_place.telemetry_mock.azapi.match_nested_block_labels, false) && try(transform.update_in_place.telemetry_mock.azapi.merge_object_attributes, false)')
        }
        if ($plan.ProviderMockBindings.Count -gt 0) {
            $capabilityName = 'label-safe object merging and explicit mock provider bindings'
            foreach ($name in $plan.ProviderMockBindings.Keys) {
                $body = "providers = {`n" +
                (($plan.ProviderMockBindings[$name] | ForEach-Object { "  $_ = $_" }) -join "`n") + "`n}`n"
                $bodyJson = ConvertTo-Json -InputObject $body -Compress
                $nameJson = (ConvertTo-Json -InputObject $name -Compress).Replace('${', '$${').Replace('%{', '%%{')
                $capabilities.Add("try(transform.update_in_place.provider_mocks[$nameJson].dynamic_block_body == $bodyJson, false)")
            }
        }
        $arguments = @('debug') + $plan.Arguments[1..($plan.Arguments.Count - 1)] + @(
            '--eval',
            ('alltrue([' + ($capabilities -join ', ') + '])')
        )
        $result = Invoke-AvmProcess -FilePath $Options.ToolPath -ArgumentList $arguments `
            -WorkingDirectory $plan.Scope.Owner.Path -EnvVars $Options.EnvVars
        try {
            $supported = ConvertFrom-Json -InputObject $result.StdOut -ErrorAction Stop
        }
        catch {
            throw [AvmConfigurationException]::new(
                "Cannot verify $capabilityName MaPoTF support for '$($plan.Path)': invalid native capability response. $($_.Exception.Message)")
        }
        if ($supported -isnot [bool] -or -not $supported) {
            throw [AvmConfigurationException]::new(
                "Cannot migrate customized telemetry mocks in '$($plan.Path)': update MaPoTF and the unit-test profile to support $capabilityName; remove outdated tool or profile overrides.")
        }
    }
    Remove-AvmLegacyTelemetryTestMock -Root $Root -ModuleTargets $ModuleTargets -UnitTestPlans $plans.ToArray()
    foreach ($plan in $plans |
            Where-Object {
                $_.NewLocationPaths.Count -gt 0 -or $null -ne $_.TelemetrySubscriptionResourceId -or
                $_.ProviderMockBindings.Count -gt 0
            }) {
        try {
            $null = Invoke-AvmProcess -FilePath $Options.ToolPath -ArgumentList $plan.Arguments `
                -WorkingDirectory $plan.Scope.Owner.Path -EnvVars $Options.EnvVars
        }
        finally {
            $null = Invoke-AvmProcess -FilePath $Options.ToolPath -ArgumentList @(
                'clean-backup', '--tf-dir', $plan.Scope.Owner.Path, '--test-file', $plan.Scope.RelativePath
            ) -WorkingDirectory $plan.Scope.Owner.Path -EnvVars $Options.EnvVars
        }
    }
}
