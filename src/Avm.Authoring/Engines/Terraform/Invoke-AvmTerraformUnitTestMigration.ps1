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
    $requirements = @{}
    $originalProviderSources = @{}
    $providerUse = @{}
    $localProviderSources = @(
        'registry.terraform.io/azure/alz'
        'registry.terraform.io/hashicorp/random'
        'registry.terraform.io/hashicorp/time'
    )
    foreach ($scope in Get-AvmTerraformTestFileScope -Root $Root -ModuleTargets $ModuleTargets |
            Where-Object IsUnitTest) {
        $inspection = Get-AvmTerraformUnitTestInspection -Scope $scope -ModuleTargets $ModuleTargets -Options $Options
        if (@($inspection.test.mock_providers.Keys | Where-Object { $_ -cmatch '^modtm(\.|$)' }).Count -gt 0 -or
            ($inspection.test['runs'] -is [System.Collections.IDictionary] -and $inspection.test.runs.Count -gt 0)) {
            foreach ($path in @($scope.Owner.Path) + @($ModuleTargets.Path)) {
                if (-not $requirements.ContainsKey($path)) {
                    $requirements[$path] = Get-AvmTerraformUnitTestRequiredProvider -Path $path -Options $Options
                }
            }
            $mockedNames = @($inspection.test.mock_providers.Keys | ForEach-Object { ($_ -split '\.', 2)[0] })
            $preservationProof = $inspection.test.providers.Count -gt 0
            foreach ($provider in @('random', 'time')) {
                if ($preservationProof) { break }
                if ($provider -cnotin $mockedNames) {
                    $preservationProof = Test-AvmTerraformScopedProviderInUse -Scope $scope -ModuleTargets $ModuleTargets `
                        -TargetPaths @($inspection.test.run_modules.Values | ForEach-Object { $_.dir }) `
                        -Cache $providerUse -Provider $provider -IncludeSelectedExamples
                }
            }
            foreach ($name in $inspection.test.run_modules.Keys) {
                $targetPath = $inspection.test.run_modules[$name].dir
                $unmockedNames = @($requirements[$targetPath].Keys | Where-Object { $_ -cnotin $mockedNames })
                $localNames = @(Get-AvmTerraformUnitTestMockProviderName -ProviderNames $unmockedNames `
                        -RequiredProviders $requirements[$targetPath] -ProviderSources $localProviderSources)
                $introducesMapping = $inspection.test.runs[$name].mptf.attributes.Contains('providers') -and
                -not $requirements[$targetPath].Contains('azapi') -and
                @($ModuleTargets | Where-Object { $_.Path -ceq $targetPath -and $_.Profiles -contains 'root' }).Count -gt 0
                if (($preservationProof -or $localNames.Count -gt 0 -or $introducesMapping) -and
                    -not $originalProviderSources.ContainsKey($targetPath)) {
                    $originalProviderSources[$targetPath] = @(Get-AvmTerraformUnitTestProviderSource `
                            -Path $targetPath -ModuleTargets $ModuleTargets -Options $Options)
                }
            }
        }
        [pscustomobject]@{
            Scope                = $scope
            Hash                 = (Get-FileHash -LiteralPath $scope.File.FullName -Algorithm SHA256).Hash
            Before               = $inspection
            ProviderRequirements = $requirements
            ProviderSources      = $originalProviderSources
        }
    }
}

function Get-AvmTerraformUnitTestMockAlias {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Test,
        [Parameter(Mandatory)] [string] $Path
    )

    Set-StrictMode -Version 3.0
    $aliases = @{}
    foreach ($name in @($Test.mock_providers.Keys | Where-Object { $_ -cmatch '\.' })) {
        $identity = [regex]::Match($name, '\A(?<provider>[A-Za-z_][A-Za-z0-9_-]*)\.(?<alias>[A-Za-z_][A-Za-z0-9_-]*)\z')
        $mock = $Test.mock_providers[$name]
        if (-not $identity.Success -or
            $mock -isnot [System.Collections.IDictionary] -or
            $mock['mptf'] -isnot [System.Collections.IDictionary] -or
            $mock.mptf['is_empty'] -isnot [bool] -or $mock.mptf.is_empty -ne $false -or
            $mock.mptf['attributes'] -isnot [System.Collections.IDictionary] -or
            $mock.mptf.attributes['alias'] -cne $identity.Groups['alias'].Value -or
            $mock.mptf['block_address'] -cne "mock_provider.$name" -or
            $mock.mptf['block_type'] -cne 'mock_provider' -or
            $mock.mptf['block_labels'] -isnot [System.Collections.IList] -or
            @($mock.mptf.block_labels).Count -ne 1 -or
            $mock.mptf.block_labels[0] -cne $identity.Groups['provider'].Value) {
            throw [AvmConfigurationException]::new(
                "Cannot automatically migrate unit test '$Path': alias '$name' requires literal native mock metadata with consistent labels and address.")
        }
        if ($mock.mptf.attributes.Contains('source') -and
            ($mock.mptf.attributes.source -isnot [string] -or
            [string]::IsNullOrWhiteSpace($mock.mptf.attributes.source) -or
            $mock.mptf.attributes.source -match '\$\{|%\{')) {
            throw [AvmConfigurationException]::new(
                "Cannot automatically migrate unit test '$Path': alias '$name' has an unproven mock source.")
        }
        $nested = @($mock.Keys | Where-Object { $_ -cnotin @('mptf', 'alias', 'source') })
        $aliases[$name] = $mock.mptf.attributes.Count -eq 1 -and $nested.Count -eq 0
    }
    return $aliases
}

function Get-AvmTerraformTelemetryMockResourceId {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Test,
        [Parameter(Mandatory)] [string] $Path,
        [string] $ProviderName = 'azapi',
        [string] $ModuleRoot,
        [object] $Options,
        [hashtable] $SourceClientDefaults
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if (-not $Test.mock_providers.Contains($ProviderName)) {
        return $null
    }
    $mock = $Test.mock_providers[$ProviderName]
    if ($ProviderName -cne 'azapi') {
        $alias = [regex]::Match($ProviderName, '\Aazapi\.(?<alias>[A-Za-z_][A-Za-z0-9_-]*)\z')
        if (-not $alias.Success -or
            $mock -isnot [System.Collections.IDictionary] -or
            $mock['mptf'] -isnot [System.Collections.IDictionary] -or
            $mock.mptf['is_empty'] -isnot [bool] -or $mock.mptf.is_empty -ne $false -or
            $mock.mptf['attributes'] -isnot [System.Collections.IDictionary] -or
            $mock.mptf.attributes['alias'] -cne $alias.Groups['alias'].Value -or
            $mock.mptf['block_address'] -cne "mock_provider.$ProviderName" -or
            $mock.mptf['block_type'] -cne 'mock_provider' -or
            $mock.mptf['block_labels'] -isnot [System.Collections.IList] -or
            @($mock.mptf.block_labels).Count -ne 1 -or
            $mock.mptf.block_labels[0] -cne 'azapi') {
            throw [AvmConfigurationException]::new(
                "Cannot automatically migrate unit test '$Path': AzAPI alias '$ProviderName' requires literal native mock metadata.")
        }
    }
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
    if ($mock.mptf.attributes.Contains('source')) {
        if ([string]::IsNullOrWhiteSpace($ModuleRoot) -or $null -eq $Options) {
            throw [AvmConfigurationException]::new(
                "Cannot automatically migrate unit test '$Path': source-based AzAPI mocks require native source inspection.")
        }
        $sourceDefaults = Get-AvmTerraformSourceMockClientDefault -Source $mock.mptf.attributes.source `
            -ModuleRoot $ModuleRoot -Path $Path -Options $Options
        if ($clientConfigs.Count -eq 0) {
            $defaults = $sourceDefaults
            if ($null -ne $SourceClientDefaults -and -not $defaults.Contains('subscription_resource_id')) {
                $SourceClientDefaults[$ProviderName] = $defaults
            }
        }
    }
    if ($defaults.Contains('subscription_resource_id')) {
        return $null
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

function Get-AvmTerraformSourceMockClientDefault {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [object] $Source,
        [Parameter(Mandatory)] [string] $ModuleRoot,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object] $Options
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ($Source -isnot [string] -or [string]::IsNullOrWhiteSpace($Source) -or
        [System.IO.Path]::IsPathRooted($Source) -or $Source -match '[:$%]') {
        throw [AvmConfigurationException]::new(
            "Cannot automatically migrate unit test '$Path': the mock source must be a literal local directory within its owning module.")
    }
    $root = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($ModuleRoot))
    $directory = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($Source, $root))
    if (-not $directory.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::Ordinal) -or
        -not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw [AvmConfigurationException]::new(
            "Cannot automatically migrate unit test '$Path': the mock source must be an existing local directory within its owning module.")
    }
    $parent = Get-Item -LiteralPath $directory -Force
    while ($null -ne $parent -and $parent.FullName -cne $root) {
        if ($parent.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw [AvmConfigurationException]::new("Cannot migrate source-based mock in '$Path': linked mock directories require review.")
        }
        $parent = $parent.Parent
    }
    if ($null -eq $parent) {
        throw [AvmConfigurationException]::new("Cannot migrate source-based mock in '$Path': the owning module boundary could not be verified.")
    }
    $files = @(Get-ChildItem -LiteralPath $directory -File -Force)
    if (@($files | Where-Object { $_.Name.EndsWith('.tfmock.json', [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
        throw [AvmConfigurationException]::new("Cannot migrate source-based mock in '$Path': JSON mock data requires review.")
    }
    $sourceFiles = @($files | Where-Object { $_.Name.EndsWith('.tfmock.hcl', [System.StringComparison]::Ordinal) } | Sort-Object Name)
    $stage = Join-Path (Get-AvmFolder -Kind Temp) ('avm-mock-source-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    $null = New-Item -ItemType Directory -Path $stage -ErrorAction Stop
    $testPath = Join-Path $stage 'source.tftest.hcl'
    try {
        $body = @(
            foreach ($file in $sourceFiles) {
                if ($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    throw [AvmConfigurationException]::new("Cannot migrate source-based mock in '$Path': linked mock files require review.")
                }
                [System.IO.File]::ReadAllText($file.FullName)
            }
        ) -join "`n"
        $stagedText = "mock_provider `"azapi`" {`n$body`n}`n"
        [System.IO.File]::WriteAllText($testPath, $stagedText, [System.Text.UTF8Encoding]::new($false))
        $result = Invoke-AvmProcess -FilePath $Options.ToolPath -ArgumentList @(
            'debug', '--tf-dir', $stage, '--test-file', 'source.tftest.hcl',
            '--mptf-dir', $Options.ProfileDirs['unit-test-inspect'],
            '--eval', 'data.test_file.this.result.mock_providers.azapi'
        ) -WorkingDirectory $stage -EnvVars $Options.EnvVars
        try {
            $mock = ConvertFrom-Json -InputObject $result.StdOut -AsHashtable -ErrorAction Stop
        }
        catch {
            throw [AvmConfigurationException]::new("Cannot inspect source-based mock in '$Path': invalid native JSON. $($_.Exception.Message)")
        }
        if ($mock -isnot [System.Collections.IDictionary] -or
            $mock['mptf'] -isnot [System.Collections.IDictionary] -or
            $mock.mptf['attributes'] -isnot [System.Collections.IDictionary] -or $mock.mptf.attributes.Count -ne 0 -or
            $mock.mptf['range'] -isnot [System.Collections.IDictionary] -or
            $mock.mptf.range['start_line'] -ne 1 -or
            $mock.mptf.range['end_line'] -ne @($stagedText.TrimEnd() -split '\r?\n').Count -or
            @($mock.Keys | Where-Object { $_ -cnotin @('mptf', 'mock_data', 'mock_resource') }).Count -gt 0) {
            throw [AvmConfigurationException]::new("Cannot migrate source-based mock in '$Path': source overrides or unknown mock metadata require review.")
        }
        $configs = @(
            foreach ($data in @($mock['mock_data'])) {
                if ($null -eq $data) { continue }
                if ($data -isnot [System.Collections.IDictionary] -or
                    $data['mptf'] -isnot [System.Collections.IDictionary] -or
                    $data.mptf['block_labels'] -isnot [System.Collections.IList] -or
                    @($data.mptf.block_labels).Count -ne 1 -or
                    $data.mptf['attributes'] -isnot [System.Collections.IDictionary]) {
                    throw [AvmConfigurationException]::new("Cannot inspect source-based mock in '$Path': invalid native mock-data metadata.")
                }
                if ($data.mptf.block_labels[0] -ceq 'azapi_client_config') { $data }
            }
        )
        if ($configs.Count -gt 1) {
            throw [AvmConfigurationException]::new("Cannot migrate source-based mock in '$Path': duplicate client-config defaults require review.")
        }
        $defaults = @{}
        if ($configs.Count -eq 1 -and $configs[0].mptf.attributes.Contains('defaults')) {
            $defaults = $configs[0].mptf.attributes.defaults
        }
        if ($defaults -isnot [System.Collections.IDictionary] -or
            (ConvertTo-Json -InputObject $defaults -Depth 50 -Compress) -match '\$\{|%\{') {
            throw [AvmConfigurationException]::new("Cannot migrate source-based mock in '$Path': client-config defaults must be literal values.")
        }
        return $defaults
    }
    finally {
        if (Test-Path -LiteralPath $testPath -PathType Leaf) { Remove-Item -LiteralPath $testPath -Force }
        Remove-Item -LiteralPath $stage -ErrorAction Stop
    }
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

function Get-AvmTerraformRetiredTestProviderReferenceCount {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text,
        [Parameter(Mandatory)] [ValidateSet('modtm', 'random')] [string] $Provider
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $trivia = '(?>(?:\s|#[^\r\n]*|//[^\r\n]*|/\*[\s\S]*?\*/)*)'
    $resource = if ($Provider -ceq 'random') { '(?:_[A-Za-z0-9_]+)?' } else { '' }
    $pattern = '(?<![A-Za-z0-9_])' + $Provider + $resource + '\.|=' +
    $trivia + $Provider + '(?=[ \t\r\n,}.]|$)'
    return [regex]::Matches($Text, $pattern,
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant, [TimeSpan]::FromSeconds(1)).Count
}

function ConvertFrom-AvmTerraformUnitTestProviderMapping {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [object] $Expression,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $ProviderNames,
        [AllowEmptyCollection()] [string[]] $MockProviderNames = $ProviderNames,
        [AllowEmptyCollection()] [string[]] $RetiredProviderNames = @(),
        [switch] $AllowUnlistedProviders
    )

    Set-StrictMode -Version 3.0
    if ($Expression -isnot [string]) {
        return $null
    }
    $trivia = '(?>(?:\s|#[^\r\n]*|//[^\r\n]*|/\*[\s\S]*?\*/)*)'
    $identifier = '[A-Za-z_][A-Za-z0-9_-]*'
    $entry = '(?<entry>(?:"(?<name>' + $identifier + ')"|(?<name>' + $identifier + '))' +
    '(?<before_equals>' + $trivia + ')=(?<after_equals>' + $trivia + ')' +
    '(?<reference>' + $identifier + '(?:\.' + $identifier + ')?)' +
    '(?<after_reference>' + $trivia + ')(?:,)?(?<after_separator>' + $trivia + '))'
    $pattern = '\A' + $trivia + '\{' + $trivia + '(?:' + $entry + ')*\}' + $trivia + '\z'
    $match = [regex]::Match($Expression, $pattern,
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant, [TimeSpan]::FromSeconds(1))
    if (-not $match.Success) {
        return $null
    }
    $bindings = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    $retained = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $retiredEntries = [System.Collections.Generic.List[int]]::new()
    for ($index = 0; $index -lt $match.Groups['name'].Captures.Count; $index++) {
        $name = $match.Groups['name'].Captures[$index].Value
        $reference = $match.Groups['reference'].Captures[$index].Value
        if (-not $bindings.TryAdd($name, $reference) -or
            (-not $AllowUnlistedProviders -and $reference -cnotin $MockProviderNames) -or
            ($reference -cne $name -and -not $reference.StartsWith("$name.", [System.StringComparison]::Ordinal))) {
            return $null
        }
        if ($name -cin $RetiredProviderNames) {
            $retiredEntries.Add($index)
        }
        else {
            $null = $retained.Add($name)
        }
    }
    if (-not $AllowUnlistedProviders -and -not $retained.SetEquals($ProviderNames)) { return $null }

    $updated = $Expression
    foreach ($index in @($retiredEntries | Sort-Object -Descending)) {
        $capture = $match.Groups['entry'].Captures[$index]
        $remainingTrivia = foreach ($group in @('before_equals', 'after_equals', 'after_reference', 'after_separator')) {
            $match.Groups[$group].Captures[$index].Value
        }
        $updated = $updated.Remove($capture.Index, $capture.Length).Insert($capture.Index, ($remainingTrivia -join ''))
    }
    $retiredReferences = @{ modtm = 0; random = 0 }
    foreach ($provider in $RetiredProviderNames) {
        $retiredReferences[$provider] = Get-AvmTerraformRetiredTestProviderReferenceCount -Text $Expression -Provider $provider
    }
    return [pscustomobject]@{
        Expression        = $updated
        Changed           = $updated -cne $Expression
        Bindings          = $bindings
        RetiredReferences = $retiredReferences
    }
}

function ConvertFrom-AvmTerraformProviderTree {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text,
        [Parameter(Mandatory)] [string] $Path,
        [hashtable] $ModuleProviderSources
    )

    Set-StrictMode -Version 3.0
    $sources = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $inConfiguration = $false
    $rootSeen = $false
    $testDepth = -1
    $moduleName = $null
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
        if ($depth -eq 1) { $moduleName = $null }
        $kind = $node.Groups['kind'].Value
        $value = $node.Groups['value'].Value
        if ($kind -ceq 'test' -and $value.StartsWith('.')) {
            $testDepth = $depth
            continue
        }
        if ($kind -ceq 'module' -and $value.StartsWith('.')) {
            if ($depth -eq 1 -and $null -ne $ModuleProviderSources) {
                $moduleName = $value.Substring(1)
                $ModuleProviderSources[$moduleName] = [System.Collections.Generic.HashSet[string]]::new(
                    [System.StringComparer]::OrdinalIgnoreCase)
            }
            continue
        }
        $provider = [regex]::Match($value,
            '\A\[(?<source>[A-Za-z0-9._:-]+/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+)\](?:\s+.*)?\z')
        if ($kind -cne 'provider' -or -not $provider.Success) {
            throw [AvmConfigurationException]::new(
                "Cannot inspect provider dependencies for '$Path': unexpected Terraform provider node.")
        }
        $null = $sources.Add($provider.Groups['source'].Value)
        if ($null -ne $moduleName) {
            $null = $ModuleProviderSources[$moduleName].Add($provider.Groups['source'].Value)
        }
    }
    if (-not $inConfiguration -or -not $rootSeen) {
        throw [AvmConfigurationException]::new(
            "Cannot inspect provider dependencies for '$Path': missing Terraform configuration tree.")
    }
    return [string[]]@($sources)
}

function Assert-AvmTerraformLocalsOnlyJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $ReviewMessage
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $jsonDocument = $null
    $jsonReview = "$ReviewMessage; '$Path'"
    try {
        $jsonOptions = [System.Text.Json.JsonDocumentOptions]::new()
        $jsonOptions.MaxDepth = 100
        $jsonDocument = [System.Text.Json.JsonDocument]::Parse(
            [System.IO.File]::ReadAllText($Path), $jsonOptions)
        if ($jsonDocument.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
            throw [AvmConfigurationException]::new("$jsonReview must be an object containing only locals blocks.")
        }
        foreach ($property in $jsonDocument.RootElement.EnumerateObject()) {
            $localBlocks = if ($property.Value.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
                @($property.Value.EnumerateArray())
            }
            else { @($property.Value) }
            if ($property.Name -cne 'locals' -or
                @($localBlocks | Where-Object { $_.ValueKind -ne [System.Text.Json.JsonValueKind]::Object }).Count -gt 0) {
                throw [AvmConfigurationException]::new("$jsonReview must contain only locals blocks.")
            }
        }
    }
    catch [System.Text.Json.JsonException] {
        throw [AvmConfigurationException]::new("$jsonReview is not valid JSON.")
    }
    finally {
        if ($null -ne $jsonDocument) { $jsonDocument.Dispose() }
    }
}

function Get-AvmTerraformUnitTestProviderSource {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object[]] $ModuleTargets,
        [Parameter(Mandatory)] [object] $Options,
        [hashtable] $ModuleProviderSources,
        [hashtable] $ModuleManifests
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $inspectionRoot = $Options.PSObject.Properties['InspectionRoot']
    if ($null -eq $inspectionRoot -or [string]::IsNullOrWhiteSpace($inspectionRoot.Value)) {
        throw [AvmConfigurationException]::new('Dependency inspection requires an owned temporary InspectionRoot.')
    }
    $files = @(Get-ChildItem -LiteralPath $Path -File)
    $trivia = '(?:\s|#[^\r\n]*|//[^\r\n]*|/\*[\s\S]*?\*/)'
    $stateDeclaration = '\b(?:backend|state_store|state_store_provider)' + $trivia + '+"' +
    '|\bcloud' + $trivia + '*\{'
    foreach ($file in $files) {
        if ($file.Name.EndsWith('.tf.json', [System.StringComparison]::OrdinalIgnoreCase)) {
            Assert-AvmTerraformLocalsOnlyJson -Path $file.FullName `
                -ReviewMessage "Cannot inspect provider dependencies for '$Path': JSON configuration requires review"
        }
        elseif ($file.Name.EndsWith('.tf', [System.StringComparison]::OrdinalIgnoreCase) -and
            [regex]::IsMatch([System.IO.File]::ReadAllText($file.FullName), $stateDeclaration,
                [System.Text.RegularExpressions.RegexOptions]::CultureInvariant, [TimeSpan]::FromSeconds(1))) {
            throw [AvmConfigurationException]::new(
                "Cannot inspect provider dependencies for '$Path': review possible backend/cloud declarations before running dependency inspection.")
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
    foreach ($name in @('TF_DATA_DIR', 'TF_CLI_ARGS', 'TF_CLI_ARGS_init', 'TF_CLI_ARGS_get', 'TF_CLI_ARGS_providers')) {
        $environment[$name] = $null
    }
    $environment.TF_DATA_DIR = Join-Path $Options.InspectionRoot ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $environment.TF_DATA_DIR -Force -ErrorAction Stop
    $lockPath = Join-Path $Path '.terraform.lock.hcl'
    $lockExists = Test-Path -LiteralPath $lockPath -PathType Leaf
    [byte[]]$lockContent = @()
    if ($lockExists) {
        $lockContent = [System.IO.File]::ReadAllBytes($lockPath)
    }
    $manifestPath = Join-Path -Path $environment.TF_DATA_DIR -ChildPath 'modules' -AdditionalChildPath 'modules.json'
    $inspectionCache = $Options.PSObject.Properties['InspectionModuleCache']
    if ($null -ne $inspectionCache -and $inspectionCache.Value -isnot [hashtable]) {
        throw [AvmConfigurationException]::new('InspectionModuleCache must be an invocation-owned hashtable.')
    }
    try {
        if ($null -ne $inspectionCache) {
            $null = Initialize-AvmTerraformInspectionModule -Path $Path -DataDirectory $environment.TF_DATA_DIR `
                -ModuleTargets $ModuleTargets -Options $Options -Cache $inspectionCache.Value -Confirm:$false
        }
        $providerDirectory = Join-Path -Path $Path -ChildPath '.terraform' -AdditionalChildPath 'providers'
        if ($lockExists -and -not (Test-Path -LiteralPath $providerDirectory -PathType Container)) {
            $null = Invoke-AvmTerraformInit -TerraformPath $Options.TerraformPath -WorkingDirectory $Path `
                -EnvVars $environment -BackendFalse -NoColor -PreserveDependencySelections `
                -Label 'terraform init (unit-test provider dependencies)'
        }
        else {
            if ($lockExists) {
                $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
                $null = New-Item -ItemType $linkType -Path (Join-Path $environment.TF_DATA_DIR 'providers') `
                    -Target $providerDirectory -ErrorAction Stop
            }
            $null = Invoke-AvmProcess -FilePath $Options.TerraformPath -ArgumentList @('get', '-no-color') `
                -WorkingDirectory $Path -EnvVars $environment -RetryNetworkFailure `
                -Label 'terraform get (unit-test provider dependencies)'
        }
        $result = Invoke-AvmProcess -FilePath $Options.TerraformPath `
            -ArgumentList @('providers', '-no-color', '-test-directory=tests') `
            -WorkingDirectory $Path -EnvVars $environment
        $sources = @(ConvertFrom-AvmTerraformProviderTree -Text $result.StdOut -Path $Path -ModuleProviderSources $ModuleProviderSources)
        if (($null -ne $ModuleManifests -or $null -ne $inspectionCache) -and
            (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            $payload = [System.IO.File]::ReadAllText($manifestPath)
            $null = ConvertFrom-AvmTerraformModuleManifest -Payload $payload -WorkingDirectory $Path
            if ($null -ne $ModuleManifests) { $ModuleManifests[$Path] = $payload }
            if ($null -ne $inspectionCache) {
                Register-AvmTerraformInspectionModule -Manifest (ConvertFrom-Json -InputObject $payload -AsHashtable) `
                    -WorkingDirectory $Path -DataDirectory $environment.TF_DATA_DIR `
                    -InspectionRoot $Options.InspectionRoot -Cache $inspectionCache.Value
            }
        }
        return $sources
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
        $baseName = ($name -split '\.', 2)[0]
        $source = if ($RequiredProviders.Contains($baseName)) { $RequiredProviders[$baseName]['source'] } else { $null }
        if ($baseName -ceq 'modtm' -and [string]::IsNullOrWhiteSpace($source)) {
            if ($ProviderSources -contains 'registry.terraform.io/azure/modtm') {
                throw [AvmConfigurationException]::new(
                    'Cannot bind a ModTM mock without its proven explicit Azure/modtm source requirement.')
            }
            continue
        }
        if ([string]::IsNullOrWhiteSpace($source)) {
            $source = "hashicorp/$baseName"
        }
        if (@($source -split '/').Count -eq 2) {
            $source = "registry.terraform.io/$source"
        }
        if ($source -in $ProviderSources) {
            $name
        }
    }
}

function Get-AvmTerraformUnitTestPreservedProviderBinding {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [object] $Snapshot,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Test,
        [Parameter(Mandatory)] [string] $RunName,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $RequiredProviders,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $ProviderSources
    )

    Set-StrictMode -Version 3.0
    $bindings = @{}
    $path = $Snapshot.Before.test.run_modules[$RunName].dir
    if ($null -eq $Snapshot.PSObject.Properties['ProviderRequirements'] -or
        $null -eq $Snapshot.PSObject.Properties['ProviderSources'] -or
        -not $Snapshot.ProviderRequirements.Contains($path) -or
        -not $Snapshot.ProviderSources.Contains($path)) {
        return $bindings
    }
    $original = $Snapshot.Before.test
    $originalMapping = $null
    if ($original.runs[$RunName].mptf.attributes.Contains('providers')) {
        $originalMapping = ConvertFrom-AvmTerraformUnitTestProviderMapping `
            -Expression $original.runs[$RunName].mptf.attributes.providers -ProviderNames @() -AllowUnlistedProviders
        if ($null -eq $originalMapping) { return $bindings }
    }
    $originalRequirements = $Snapshot.ProviderRequirements[$path]
    $providerNames = @($originalRequirements.Keys) + @(
        foreach ($source in $Snapshot.ProviderSources[$path]) {
            if ($source -in @('registry.terraform.io/hashicorp/random', 'registry.terraform.io/hashicorp/time')) {
                ($source -split '/')[-1]
            }
        }
    ) | Sort-Object -Unique
    foreach ($name in $providerNames) {
        $requirement = if ($originalRequirements.Contains($name)) { $originalRequirements[$name] } else { @{} }
        $source = $requirement['source']
        if ([string]::IsNullOrWhiteSpace($source)) { $source = "hashicorp/$name" }
        if (@($source -split '/').Count -eq 2) { $source = "registry.terraform.io/$source" }
        if ($source -notin @('registry.terraform.io/azure/alz',
                'registry.terraform.io/hashicorp/random', 'registry.terraform.io/hashicorp/time') -or
            $source -notin $Snapshot.ProviderSources[$path] -or $source -notin $ProviderSources) {
            continue
        }
        $currentSource = if ($RequiredProviders.Contains($name)) { $RequiredProviders[$name]['source'] } else { $null }
        if ([string]::IsNullOrWhiteSpace($currentSource)) { $currentSource = "hashicorp/$name" }
        if (@($currentSource -split '/').Count -eq 2) { $currentSource = "registry.terraform.io/$currentSource" }
        if ($currentSource -ine $source -or
            ($originalRequirements.Contains($name) -and $RequiredProviders.Contains($name) -and
            $RequiredProviders[$name]['version'] -cne $requirement['version']) -or
            ($null -ne $requirement['configuration_aliases'] -and @($requirement.configuration_aliases).Count -gt 0) -or
            ($RequiredProviders.Contains($name) -and $null -ne $RequiredProviders[$name]['configuration_aliases'] -and
            @($RequiredProviders[$name].configuration_aliases).Count -gt 0) -or
            @($original.mock_providers.Keys | Where-Object { ($_ -split '\.', 2)[0] -ceq $name }).Count -gt 0 -or
            @($Test.mock_providers.Keys | Where-Object { ($_ -split '\.', 2)[0] -ceq $name }).Count -gt 0) {
            continue
        }
        $reference = $null
        if ($null -ne $originalMapping) {
            if ($originalMapping.Bindings.ContainsKey($name)) { $reference = $originalMapping.Bindings[$name] }
        }
        elseif ($original.providers.Contains($name)) {
            $reference = $name
        }
        if ($null -eq $reference) {
            if ($source -ieq 'registry.terraform.io/azure/alz' -or
                @($original.providers.Keys | Where-Object { ($_ -split '\.', 2)[0] -ceq $name }).Count -gt 0) {
                continue
            }
        }
        else {
            $alias = if ($reference -cne $name) { $reference.Substring($name.Length + 1) } else { $null }
            $unproven = @(
                foreach ($providers in @($original.providers, $Test.providers)) {
                    $provider = $providers[$reference]
                    if ($provider -isnot [System.Collections.IDictionary] -or
                        $provider['mptf'] -isnot [System.Collections.IDictionary] -or
                        $provider.mptf['attributes'] -isnot [System.Collections.IDictionary] -or
                        $provider.mptf['is_empty'] -isnot [bool] -or
                        $provider.mptf['block_type'] -cne 'provider' -or
                        $provider.mptf['block_address'] -cne "provider.$reference" -or
                        $provider.mptf['block_labels'] -isnot [System.Collections.IList] -or
                        @($provider.mptf.block_labels).Count -ne 1 -or $provider.mptf.block_labels[0] -cne $name -or
                        ($null -ne $alias -and $provider.mptf.attributes['alias'] -cne $alias) -or
                        ($null -eq $alias -and $provider.mptf.attributes.Contains('alias'))) {
                        $reference
                        continue
                    }
                    if ($source -ieq 'registry.terraform.io/azure/alz') {
                        $libraries = $provider.mptf.attributes['library_references']
                        if ($libraries -isnot [System.Collections.IList] -or $libraries.Count -eq 0 -or
                            @($libraries | Where-Object {
                                    $_ -isnot [System.Collections.IDictionary] -or
                                    $_['custom_url'] -isnot [string] -or
                                    -not $_.custom_url.StartsWith('./', [System.StringComparison]::Ordinal) -or
                                    $_.custom_url -match '\$\{|%\{' -or
                                    @($_.custom_url -split '[\\/]' | Where-Object { $_ -ceq '..' }).Count -gt 0
                                }).Count -gt 0) {
                            $reference
                        }
                    }
                }
            )
            if ($unproven.Count -gt 0) { continue }
        }
        $bindings[$name] = $reference
    }
    return $bindings
}

function Get-AvmTerraformUnitTestModtmRequirementPlan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object[]] $ModuleTargets,
        [Parameter(Mandatory)] [object] $Options,
        [Parameter(Mandatory)] [hashtable] $RequiredProviders,
        [Parameter(Mandatory)] [hashtable] $ProviderSources,
        [Parameter(Mandatory)] [hashtable] $ModuleProviderSources,
        [Parameter(Mandatory)] [hashtable] $ModuleManifests,
        [Parameter(Mandatory)] [hashtable] $OriginalRequirements,
        [Parameter(Mandatory)] [hashtable] $Plans,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.HashSet[string]] $PlanningPaths,
        [switch] $BindDependencies
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ($Plans.ContainsKey($Path)) { return $Plans[$Path] }
    $source = 'registry.terraform.io/azure/modtm'
    if ($RequiredProviders[$Path].Contains('modtm')) {
        $declared = $RequiredProviders[$Path].modtm['source']
        if ($declared -notin @('Azure/modtm', $source)) {
            throw [AvmConfigurationException]::new(
                "Cannot preserve ModTM mocks for '$Path': the provider must explicitly declare the proven Azure/modtm source.")
        }
        if (-not $BindDependencies) { return $null }
    }
    if (-not $PlanningPaths.Add($Path)) {
        throw [AvmConfigurationException]::new("Cannot preserve ModTM mocks for '$Path': cyclic local provider dependencies require review.")
    }
    try {
        if (-not $ModuleManifests.ContainsKey($Path) -or $ModuleManifests[$Path] -isnot [string]) {
            throw [AvmConfigurationException]::new("Cannot preserve ModTM mocks for '$Path': the freshly inspected dependency manifest is missing.")
        }
        $payload = $ModuleManifests[$Path]
        $null = ConvertFrom-AvmTerraformModuleManifest -Payload $payload -WorkingDirectory $Path
        $manifest = ConvertFrom-Json -InputObject $payload -AsHashtable
        $result = Invoke-AvmProcess -FilePath $Options.ToolPath -ArgumentList @(
            'debug', '--tf-dir', $Path, '--mptf-dir', $Options.ProfileDirs['provider-restore'],
            '--eval', 'data.module.unit_test_modtm_calls.result'
        ) -WorkingDirectory $Path -EnvVars $Options.EnvVars
        try {
            $calls = ConvertFrom-Json -InputObject $result.StdOut -AsHashtable -ErrorAction Stop
        }
        catch {
            throw [AvmConfigurationException]::new(
                "Cannot preserve ModTM mocks for '$Path': invalid native module-call inspection. $($_.Exception.Message)")
        }
        if ($calls -isnot [System.Collections.IDictionary]) {
            throw [AvmConfigurationException]::new(
                "Cannot preserve ModTM mocks for '$Path': update the module profile to expose native ModTM module-call inspection.")
        }
        $bindings = @{}
        $dependencyVersions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($name in $ModuleProviderSources[$Path].Keys) {
            if (-not $ModuleProviderSources[$Path][$name].Contains($source)) { continue }
            $record = @($manifest.Modules | Where-Object { $_.Key -ceq $name })
            if ($record.Count -ne 1 -or -not $calls.Contains($name)) {
                throw [AvmConfigurationException]::new(
                    "Cannot preserve ModTM mocks for '$Path': dependency '$name' has no exact installed module-call match.")
            }
            $dependency = [System.IO.Path]::TrimEndingDirectorySeparator(
                [System.IO.Path]::GetFullPath($record[0].Dir, $Path))
            foreach ($jsonFile in @(Get-ChildItem -LiteralPath $dependency -File |
                        Where-Object { $_.Name.EndsWith('.tf.json', [System.StringComparison]::OrdinalIgnoreCase) })) {
                Assert-AvmTerraformLocalsOnlyJson -Path $jsonFile.FullName `
                    -ReviewMessage "Cannot preserve ModTM mocks for '$Path': JSON dependency '$name' requires review"
            }
            if (-not $RequiredProviders.ContainsKey($dependency)) {
                $RequiredProviders[$dependency] = Get-AvmTerraformUnitTestRequiredProvider -Path $dependency -Options $Options
            }
            if (-not $RequiredProviders[$dependency].Contains('modtm')) {
                if ($dependency -cnotin $ModuleTargets.Path) {
                    throw [AvmConfigurationException]::new(
                        "Cannot preserve ModTM mocks for '$Path': unchanged dependency '$name' does not declare a ModTM source; review its provider inheritance.")
                }
                if (-not $ModuleProviderSources.ContainsKey($dependency)) {
                    $ModuleProviderSources[$dependency] = @{}
                    $ProviderSources[$dependency] = @(Get-AvmTerraformUnitTestProviderSource -Path $dependency `
                            -ModuleTargets $ModuleTargets -Options $Options -ModuleProviderSources $ModuleProviderSources[$dependency] `
                            -ModuleManifests $ModuleManifests)
                }
                $null = Get-AvmTerraformUnitTestModtmRequirementPlan -Path $dependency -ModuleTargets $ModuleTargets `
                    -Options $Options -RequiredProviders $RequiredProviders -ProviderSources $ProviderSources `
                    -ModuleProviderSources $ModuleProviderSources -ModuleManifests $ModuleManifests -OriginalRequirements $OriginalRequirements `
                    -Plans $Plans -PlanningPaths $PlanningPaths
            }
            if ($RequiredProviders[$dependency].modtm['source'] -notin @('Azure/modtm', $source)) {
                throw [AvmConfigurationException]::new(
                    "Cannot preserve ModTM mocks for '$Path': dependency '$name' has a different ModTM provider source.")
            }
            $version = $RequiredProviders[$dependency].modtm['version']
            if ($null -ne $version) {
                if ($version -isnot [string] -or $version.Contains('${') -or $version.Contains('%{')) {
                    throw [AvmConfigurationException]::new(
                        "Cannot preserve ModTM mocks for '$Path': dependency '$name' has a nonliteral version constraint that requires review.")
                }
                if (-not [string]::IsNullOrWhiteSpace($version)) {
                    $null = $dependencyVersions.Add($version)
                }
            }
            $call = $calls[$name]
            if ($call -isnot [System.Collections.IDictionary] -or
                $call['mptf'] -isnot [System.Collections.IDictionary]) {
                throw [AvmConfigurationException]::new("Cannot inspect ModTM provider bindings for '$Path' module '$name'.")
            }
            if ($call.Contains('providers')) {
                $mapping = ConvertFrom-AvmTerraformUnitTestProviderMapping -Expression $call.providers `
                    -ProviderNames @() -MockProviderNames @() -AllowUnlistedProviders
                if ($null -eq $mapping -or
                    ($mapping.Bindings.ContainsKey('modtm') -and $mapping.Bindings['modtm'] -cne 'modtm')) {
                    throw [AvmConfigurationException]::new(
                        "Cannot preserve ModTM mocks for '$Path': module '$name' has computed, aliased, or cross-provider bindings that require review.")
                }
                if ($mapping.Bindings.ContainsKey('modtm')) { continue }
            }
            $bindings[$name] = '{ modtm = modtm }'
        }
        if ($ModuleProviderSources[$Path].Count -eq 0) {
            throw [AvmConfigurationException]::new(
                "Cannot preserve ModTM mocks for '$Path': no configuration dependency proves the missing source requirement.")
        }
        $existingRequirement = $RequiredProviders[$Path].Contains('modtm')
        if ($existingRequirement -and $bindings.Count -eq 0) { return $null }
        $requirement = [ordered]@{ source = $source }
        if ($existingRequirement -or
            ($OriginalRequirements.ContainsKey($Path) -and $OriginalRequirements[$Path].Contains('modtm'))) {
            $original = if ($existingRequirement) { $RequiredProviders[$Path].modtm } else { $OriginalRequirements[$Path].modtm }
            if ($original['source'] -notin @('Azure/modtm', $source) -or
                ($null -ne $original['version'] -and $original['version'] -isnot [string]) -or
                ($null -ne $original['configuration_aliases'] -and @($original.configuration_aliases).Count -gt 0)) {
                throw [AvmConfigurationException]::new(
                    "Cannot preserve ModTM mocks for '$Path': the original provider source, version, or aliases require review.")
            }
            $requirement.source = $original.source
            if (-not [string]::IsNullOrWhiteSpace($original['version'])) { $requirement.version = $original.version }
        }
        if (-not $existingRequirement -and -not $requirement.Contains('version')) {
            if ($dependencyVersions.Count -eq 0) {
                throw [AvmConfigurationException]::new(
                    "Cannot preserve ModTM mocks for '$Path': no required dependency proves a version constraint; synthesizing the requirement requires review.")
            }
            $versions = [string[]]@($dependencyVersions)
            [Array]::Sort($versions, [System.StringComparer]::Ordinal)
            $requirement.version = $versions -join ', '
        }
        $requirementAttributes = foreach ($attribute in $requirement.GetEnumerator()) {
            $value = ConvertTo-Json -InputObject $attribute.Value -Compress
            "    $($attribute.Key) = $value"
        }
        $requirementBody = "required_providers {`n  modtm = {`n$($requirementAttributes -join "`n")`n  }`n}`n"
        $bodyJson = ConvertTo-Json -InputObject $requirementBody -Compress
        $bindingsJson = ConvertTo-Json -InputObject $bindings -Compress
        $arguments = @(
            'transform', '--tf-dir', $Path, '--mptf-dir', $Options.ProfileDirs['provider-restore'],
            '--mptf-var', "unit_test_modtm_requirement=$bodyJson",
            '--mptf-var', "unit_test_modtm_bindings=$bindingsJson"
        )
        $capabilities = [System.Collections.Generic.List[string]]::new()
        $capabilities.Add(
            "try(length(transform.update_in_place.unit_test_modtm_requirement), 0) + " +
            "try(length(transform.new_block.unit_test_modtm_requirement), 0) == 1")
        $capabilities.Add(
            "try(transform.update_in_place.unit_test_modtm_requirement[`"1`"].merge_object_attributes && " +
            "transform.update_in_place.unit_test_modtm_requirement[`"1`"].dynamic_block_body == $bodyJson, " +
            "try(transform.new_block.unit_test_modtm_requirement[`"1`"].body == $bodyJson, false))")
        foreach ($name in $bindings.Keys) {
            $nameJson = ConvertTo-Json -InputObject $name -Compress
            $bindingJson = ConvertTo-Json -InputObject "providers = $($bindings[$name])`n" -Compress
            $capabilities.Add(
                "try(transform.update_in_place.unit_test_modtm_bindings[$nameJson].merge_object_attributes && " +
                "transform.update_in_place.unit_test_modtm_bindings[$nameJson].dynamic_block_body == $bindingJson, false)")
        }
        $plan = [pscustomobject]@{
            Path         = $Path
            Arguments    = $arguments
            Capabilities = 'alltrue([' + ($capabilities -join ', ') + '])'
        }
        $Plans[$Path] = $plan
        $RequiredProviders[$Path].modtm = $requirement
        return $plan
    }
    finally {
        $null = $PlanningPaths.Remove($Path)
    }
}

function Get-AvmTerraformTelemetryTestCountMigration {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Test,
        [Parameter(Mandatory)] [object[]] $ModuleTargets
    )

    Set-StrictMode -Version 3.0
    $telemetryCount = 'length[ \t\r\n]*[(][ \t\r\n]*(?:modtm_telemetry|azapi_resource)[.]telemetry[ \t\r\n]*[)][ \t\r\n]*==[ \t\r\n]*[01]'
    $pattern = '^((?:' + $telemetryCount + '[ \t\r\n]*&&[ \t\r\n]*)?length[ \t\r\n]*[(][ \t\r\n]*)random_uuid[.]telemetry([ \t\r\n]*[)][ \t\r\n]*==[ \t\r\n]*[01])$'
    $instrumentedPaths = @($ModuleTargets | Where-Object { $_.Profiles -contains 'root' } |
            ForEach-Object { $_.Path })
    $count = 0
    foreach ($name in $Test.runs.Keys) {
        if ($Test.run_modules[$name].dir -cnotin $instrumentedPaths) { continue }
        $run = $Test.runs[$name]
        if (-not $run.Contains('assert')) { continue }
        foreach ($assertion in $run.assert) {
            if ($assertion -isnot [System.Collections.IDictionary] -or
                $assertion['mptf'] -isnot [System.Collections.IDictionary] -or
                $assertion.mptf['attributes'] -isnot [System.Collections.IDictionary]) {
                throw [AvmConfigurationException]::new("Cannot inspect telemetry assertions in unit-test run '$name'.")
            }
            $condition = $assertion.mptf.attributes['condition']
            if ($condition -is [string] -and
                [regex]::IsMatch($condition.Trim(), $pattern,
                    [System.Text.RegularExpressions.RegexOptions]::CultureInvariant, [TimeSpan]::FromSeconds(1))) {
                $count++
            }
        }
    }
    return [pscustomobject]@{
        ReferenceCount = $count
        Pattern        = $pattern
        Replacement    = '${1}terraform_data.telemetry${2}'
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
    $moduleProviderSources = @{}
    $moduleManifests = @{}
    $modtmRequirementPlans = @{}
    $planningPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
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
        $telemetryCounts = Get-AvmTerraformTelemetryTestCountMigration -Test $after.test -ModuleTargets $ModuleTargets
        $telemetryResourceIds = @{}
        $sourceClientDefaults = @{}
        if ($migratesTelemetry) {
            foreach ($name in @($after.test.mock_providers.Keys | Where-Object { $_ -cmatch '^azapi(\.|$)' })) {
                $resourceId = Get-AvmTerraformTelemetryMockResourceId `
                    -Test $after.test -Path $scope.File.FullName -ProviderName $name `
                    -ModuleRoot $scope.Owner.Path -Options $Options -SourceClientDefaults $sourceClientDefaults
                if ($null -ne $resourceId) {
                    $telemetryResourceIds[$name] = $resourceId
                }
            }
        }
        $hasEmptyModtm = $after.test.mock_providers.Contains('modtm') -and
        $after.test.mock_providers.modtm.mptf.is_empty
        $mockAliases = Get-AvmTerraformUnitTestMockAlias -Test $after.test -Path $scope.File.FullName
        $hasModtmMock = @($after.test.mock_providers.Keys | Where-Object { $_ -cmatch '^modtm(\.|$)' }).Count -gt 0
        $modtmMockRetained = $false
        $missingModtmRequirements = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        if ($migratesTelemetry -and $hasModtmMock) {
            $originalRequirements = if ($null -ne $snapshot.PSObject.Properties['ProviderRequirements']) {
                $snapshot.ProviderRequirements
            }
            else { @{} }
            foreach ($targetPath in $targetPaths) {
                if (-not $requiredProviders.ContainsKey($targetPath)) {
                    $requiredProviders[$targetPath] = Get-AvmTerraformUnitTestRequiredProvider -Path $targetPath -Options $Options
                }
                if (-not $moduleProviderSources.ContainsKey($targetPath)) {
                    $moduleProviderSources[$targetPath] = @{}
                    $providerSources[$targetPath] = @(Get-AvmTerraformUnitTestProviderSource -Path $targetPath `
                            -ModuleTargets $ModuleTargets -Options $Options -ModuleProviderSources $moduleProviderSources[$targetPath] `
                            -ModuleManifests $moduleManifests)
                }
                if (@($providerSources[$targetPath] | Where-Object {
                            $_ -match '/modtm$' -and $_ -ine 'registry.terraform.io/azure/modtm'
                        }).Count -gt 0) {
                    throw [AvmConfigurationException]::new(
                        "Cannot preserve ModTM mocks for '$targetPath': an unexpected ModTM provider source requires review.")
                }
                if ($providerSources[$targetPath] -notcontains 'registry.terraform.io/azure/modtm') { continue }
                $modtmMockRetained = $true
                if (-not $requiredProviders[$targetPath].Contains('modtm') -or $modtmRequirementPlans.ContainsKey($targetPath)) {
                    $null = $missingModtmRequirements.Add($targetPath)
                }
                $null = Get-AvmTerraformUnitTestModtmRequirementPlan -Path $targetPath -ModuleTargets $ModuleTargets `
                    -Options $Options -RequiredProviders $requiredProviders -ProviderSources $providerSources `
                    -ModuleProviderSources $moduleProviderSources -ModuleManifests $moduleManifests -OriginalRequirements $originalRequirements `
                    -Plans $modtmRequirementPlans -PlanningPaths $planningPaths
            }
        }
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
        $retiredAliasNames = @(
            foreach ($name in $mockAliases.Keys) {
                $provider = ($name -split '\.', 2)[0]
                if ($migratesTelemetry -and $mockAliases[$name] -and
                    (($provider -ceq 'modtm' -and -not $modtmMockRetained) -or
                    ($provider -ceq 'random' -and -not $randomMockRetained))) {
                    $name
                }
            }
        )
        $providerNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($name in $after.test.mock_providers.Keys) {
            $provider = ($name -split '\.', 2)[0]
            if (($migratesTelemetry -and $provider -ceq 'modtm' -and -not $modtmMockRetained) -or
                ($provider -ceq 'random' -and -not $randomMockRetained)) {
                continue
            }
            $null = $providerNames.Add($name)
        }
        $addDefaultAzapiMock = $migratesTelemetry -and -not $after.test.mock_providers.Contains('azapi') -and
        ($hasEmptyModtm -or
        ($hasModtmMock -and
        @($mockAliases.Keys | Where-Object { $_ -cmatch '^azapi\.' }).Count -eq 0))
        if ($addDefaultAzapiMock) {
            $null = $providerNames.Add('azapi')
        }
        [string[]]$mockProviderNames = @($providerNames)
        [Array]::Sort($mockProviderNames, [System.StringComparer]::Ordinal)
        [string[]]$defaultMockProviderNames = @($mockProviderNames | Where-Object { $_ -cnotmatch '\.' })
        $providerMockBindings = @{}
        $retiredProviderReferences = @{ modtm = 0; random = $telemetryCounts.ReferenceCount }
        $retainedProviderReferences = @{ modtm = 0 }
        $validateMocks = $migratesTelemetry -or $newLocations.Count -gt 0
        if ($validateMocks) {
            $requiresAzapiMock = $missingRandomRequirements.Count -gt 0 -or
            @($instrumentedTargets | Where-Object { $newLocations.Contains($_.Path) }).Count -gt 0
            $hasAzureMock = $after.test.mock_providers.Contains('azapi') -or
            (-not $requiresAzapiMock -and $after.test.mock_providers.Contains('azurerm')) -or
            $addDefaultAzapiMock -or ($migratesTelemetry -and $hasEmptyModtm)
            $realProviders = @($after.test.providers.Keys | Where-Object {
                    $missingRandomRequirements.Count -gt 0 -or $missingModtmRequirements.Count -gt 0 -or
                    $_ -cmatch '^(azapi|azurerm)(\.|$)' -or ($modtmMockRetained -and $_ -cmatch '^modtm(\.|$)')
                })
            $mappedAzapiRuns = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            $preservedRealProviders = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            $unsafeMappings = @(
                foreach ($name in $after.test.runs.Keys) {
                    $run = $after.test.runs[$name]
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
                    $preservedBindings = Get-AvmTerraformUnitTestPreservedProviderBinding -Snapshot $snapshot `
                        -Test $after.test -RunName $name -RequiredProviders $requiredProviders[$targetPath] `
                        -ProviderSources $providerSources[$targetPath]
                    $preservedNames = @($preservedBindings.Keys | Where-Object { $null -ne $preservedBindings[$_] })
                    $preservedReferences = @($preservedNames | ForEach-Object { $preservedBindings[$_] })
                    $knownProviderNames = @($after.test.mock_providers.Keys) + @($defaultMockProviderNames) + $preservedReferences
                    foreach ($reference in $preservedReferences) { $null = $preservedRealProviders.Add($reference) }
                    $baseNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
                    foreach ($provider in @($names) + $preservedNames) { $null = $baseNames.Add(($provider -split '\.', 2)[0]) }
                    $names = @($baseNames)
                    $expression = if ($run.mptf.attributes.Contains('providers')) {
                        $run.mptf.attributes.providers
                    }
                    else {
                        $implicitNames = @(Get-AvmTerraformUnitTestMockProviderName -ProviderNames $defaultMockProviderNames `
                                -RequiredProviders $requiredProviders[$targetPath] -ProviderSources $providerSources[$targetPath])
                        $defaultBindings = @{}
                        foreach ($provider in $implicitNames) { $defaultBindings[$provider] = $provider }
                        foreach ($provider in $preservedNames) { $defaultBindings[$provider] = $preservedBindings[$provider] }
                        $bindingNames = [string[]]@($defaultBindings.Keys)
                        [Array]::Sort($bindingNames, [System.StringComparer]::Ordinal)
                        $implicitExpression = "{`n" +
                        (($bindingNames | ForEach-Object { "  $_ = $($defaultBindings[$_])" }) -join "`n") + "`n}"
                        if ($missingRandomRequirements.Contains($targetPath) -or $missingModtmRequirements.Contains($targetPath)) {
                            $providerMockBindings[$name] = $implicitExpression
                        }
                        $implicitExpression
                    }
                    $retiredNames = @(
                        if ($migratesTelemetry -and $names -cnotcontains 'modtm' -and
                            ($hasEmptyModtm -or @($retiredAliasNames | Where-Object { $_ -cmatch '^modtm\.' }).Count -gt 0)) { 'modtm' }
                        if ($migratesTelemetry -and $names -cnotcontains 'random' -and
                            (($after.test.mock_providers.Contains('random') -and $after.test.mock_providers.random.mptf.is_empty) -or
                            @($retiredAliasNames | Where-Object { $_ -cmatch '^random\.' }).Count -gt 0)) { 'random' }
                    )
                    $mapping = ConvertFrom-AvmTerraformUnitTestProviderMapping `
                        -Expression $expression -ProviderNames $names `
                        -MockProviderNames $knownProviderNames -RetiredProviderNames $retiredNames
                    if ($null -eq $mapping -and $names -ccontains 'azapi' -and
                        ($after.test.mock_providers.Contains('azapi') -or $addDefaultAzapiMock) -and
                        $null -ne $snapshot.PSObject.Properties['ProviderSources'] -and
                        $snapshot.ProviderSources.ContainsKey($targetPath) -and
                        $null -ne $snapshot.PSObject.Properties['ProviderRequirements'] -and
                        -not $snapshot.ProviderRequirements[$targetPath].Contains('azapi')) {
                        $originalNames = @(Get-AvmTerraformUnitTestMockProviderName `
                                -ProviderNames @($snapshot.Before.test.mock_providers.Keys) `
                                -RequiredProviders $snapshot.ProviderRequirements[$targetPath] `
                                -ProviderSources $snapshot.ProviderSources[$targetPath] |
                                ForEach-Object { ($_ -split '\.', 2)[0] } | Sort-Object -Unique)
                        $originalNames = @($originalNames) + $preservedNames
                        $originalProviderNames = @($snapshot.Before.test.mock_providers.Keys) + $preservedReferences
                        $originalMapping = ConvertFrom-AvmTerraformUnitTestProviderMapping `
                            -Expression $expression -ProviderNames $originalNames `
                            -MockProviderNames $originalProviderNames
                        if ($null -ne $originalMapping -and -not $originalMapping.Bindings.ContainsKey('azapi')) {
                            $uncovered = @(
                                foreach ($source in $snapshot.ProviderSources[$targetPath] | Where-Object { $_ -notmatch '/builtin/' }) {
                                    if (@(Get-AvmTerraformUnitTestMockProviderName -ProviderNames @(@($originalMapping.Bindings.Keys) + @($preservedBindings.Keys)) `
                                                -RequiredProviders $snapshot.ProviderRequirements[$targetPath] -ProviderSources @($source)).Count -eq 0) {
                                        $source
                                    }
                                }
                            )
                            if ($uncovered.Count -eq 0) {
                                $expression = $originalMapping.Expression.Insert($originalMapping.Expression.LastIndexOf('}'),
                                    "`n  azapi = azapi`n")
                                $candidateMapping = ConvertFrom-AvmTerraformUnitTestProviderMapping `
                                    -Expression $expression -ProviderNames $names `
                                    -MockProviderNames $knownProviderNames -RetiredProviderNames $retiredNames
                                if ($null -ne $candidateMapping) {
                                    $uncovered = @(
                                        foreach ($source in $providerSources[$targetPath] | Where-Object { $_ -notmatch '/builtin/' }) {
                                            if (@(Get-AvmTerraformUnitTestMockProviderName -ProviderNames @(@($candidateMapping.Bindings.Keys) + @($preservedBindings.Keys)) `
                                                        -RequiredProviders $requiredProviders[$targetPath] -ProviderSources @($source)).Count -eq 0) {
                                                $source
                                            }
                                        }
                                    )
                                    if ($uncovered.Count -eq 0) {
                                        $mapping = $candidateMapping
                                        $providerMockBindings[$name] = $mapping.Expression
                                    }
                                }
                            }
                        }
                    }
                    if ($null -eq $mapping) {
                        $name
                    }
                    else {
                        $uncovered = @(
                            foreach ($source in $providerSources[$targetPath] | Where-Object { $_ -notmatch '/builtin/' }) {
                                if (@(Get-AvmTerraformUnitTestMockProviderName -ProviderNames @(@($mapping.Bindings.Keys) + @($preservedBindings.Keys)) `
                                            -RequiredProviders $requiredProviders[$targetPath] -ProviderSources @($source)).Count -eq 0) {
                                    $source
                                }
                            }
                        )
                        if ($uncovered.Count -gt 0) {
                            $name
                            continue
                        }
                        if ($mapping.Bindings.ContainsKey('azapi')) {
                            $null = $mappedAzapiRuns.Add($name)
                        }
                        if ($mapping.Changed) {
                            $providerMockBindings[$name] = $mapping.Expression
                        }
                        foreach ($provider in @('modtm', 'random')) {
                            $retiredProviderReferences[$provider] += $mapping.RetiredReferences[$provider]
                        }
                        if ($run.mptf.attributes.Contains('providers')) {
                            $retainedProviderReferences.modtm +=
                            (Get-AvmTerraformRetiredTestProviderReferenceCount -Text $run.mptf.attributes.providers -Provider modtm) -
                            $mapping.RetiredReferences.modtm
                        }
                    }
                }
            )
            $realProviders = @($realProviders | Where-Object { -not $preservedRealProviders.Contains($_) })
            $hasAzureMock = $hasAzureMock -or
            ($after.test.runs.Count -gt 0 -and $mappedAzapiRuns.Count -eq $after.test.runs.Count)
            if (($after.test.runs.Count -gt 0 -and -not $hasAzureMock) -or $realProviders.Count -gt 0 -or
                $unsafeMappings.Count -gt 0) {
                throw [AvmConfigurationException]::new(
                    "Cannot automatically migrate unit test '$($scope.File.FullName)': introduced providers need default mocks or complete known alias bindings; run provider mappings must use the same provider, without real providers, unknown aliases, or aliased target keys.")
            }
        }
        $encoded = (ConvertTo-Json -InputObject @($newLocations) -Compress).Replace('${', '$${').Replace('%{', '%%{')
        $arguments = @(
            'transform', '--tf-dir', $scope.Owner.Path, '--test-file', $scope.RelativePath,
            '--mptf-dir', $Options.ProfileDirs['unit-test'],
            '--mptf-var', ("new_location_modules=$encoded")
        )
        if ($telemetryResourceIds.Count -gt 0) {
            $resourceIdsJson = ConvertTo-Json -InputObject $telemetryResourceIds -Compress
            $arguments += @('--mptf-var', "telemetry_subscription_resource_ids=$resourceIdsJson")
        }
        if ($sourceClientDefaults.Count -gt 0) {
            $encodedDefaults = @{}
            foreach ($name in $sourceClientDefaults.Keys) {
                $encodedDefaults[$name] = ConvertTo-Json -InputObject $sourceClientDefaults[$name] -Depth 50 -Compress -EscapeHandling EscapeHtml
            }
            $defaultsJson = (ConvertTo-Json -InputObject $encodedDefaults -Compress -EscapeHandling EscapeHtml).Replace('${', '$${').Replace('%{', '%%{')
            $arguments += @('--mptf-var', "telemetry_source_client_defaults=$defaultsJson")
        }
        if ($providerMockBindings.Count -gt 0) {
            $bindingsJson = (ConvertTo-Json -InputObject $providerMockBindings -Depth 5 -Compress).Replace('${', '$${').Replace('%{', '%%{')
            $arguments += @('--mptf-var', "provider_mock_bindings=$bindingsJson")
        }
        if ($telemetryCounts.ReferenceCount -gt 0) {
            $arguments += @('--mptf-var', 'migrate_telemetry_counts=true')
        }
        if ($retiredAliasNames.Count -gt 0) {
            $retiredJson = ConvertTo-Json -InputObject @($retiredAliasNames) -Compress
            $arguments += @('--mptf-var', "retired_mock_provider_names=$retiredJson")
        }
        $plans.Add([pscustomobject]@{
                Path                             = $scope.File.FullName
                Scope                            = $scope
                TargetPaths                      = @($targetPaths)
                NewLocationPaths                 = @($newLocations)
                TelemetrySubscriptionResourceIds = $telemetryResourceIds
                SourceClientDefaults             = $sourceClientDefaults
                TelemetryCountMigration          = $telemetryCounts
                ProviderMockBindings             = $providerMockBindings
                MockMigrationValidated           = $validateMocks
                AddDefaultAzapiMock              = $addDefaultAzapiMock
                RetainModtmMock                  = $modtmMockRetained
                RetiredAliasNames                = $retiredAliasNames
                RetiredProviderReferences        = $retiredProviderReferences
                RetainedProviderReferences       = $retainedProviderReferences
                Arguments                        = $arguments
            })
    }

    $allOriginalRequirements = @{}
    foreach ($snapshot in $Snapshots) {
        if ($null -ne $snapshot.PSObject.Properties['ProviderRequirements']) {
            foreach ($path in $snapshot.ProviderRequirements.Keys) {
                $allOriginalRequirements[$path] = $snapshot.ProviderRequirements[$path]
            }
        }
    }
    $callerInspections = @{}
    $retainedPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($path in @($requiredProviders.Keys)) {
        if ($requiredProviders[$path].Contains('modtm') -and $providerSources.ContainsKey($path) -and
            $providerSources[$path] -contains 'registry.terraform.io/azure/modtm') {
            $null = $retainedPaths.Add($path)
        }
    }
    $addedCaller = $true
    while ($retainedPaths.Count -gt 0 -and $addedCaller) {
        $addedCaller = $false
        foreach ($target in $ModuleTargets) {
            if ($retainedPaths.Contains($target.Path)) { continue }
            if ($providerSources.ContainsKey($target.Path) -and
                $providerSources[$target.Path] -notcontains 'registry.terraform.io/azure/modtm') { continue }
            if (-not $callerInspections.ContainsKey($target.Path)) {
                $result = Invoke-AvmProcess -FilePath $Options.ToolPath -ArgumentList @(
                    'debug', '--tf-dir', $target.Path, '--mptf-dir', $Options.ProfileDirs['provider-restore'],
                    '--eval', 'data.module.unit_test_modtm_calls.result'
                ) -WorkingDirectory $target.Path -EnvVars $Options.EnvVars
                try {
                    $callerInspections[$target.Path] = ConvertFrom-Json -InputObject $result.StdOut -AsHashtable -ErrorAction Stop
                }
                catch {
                    throw [AvmConfigurationException]::new("Cannot inspect retained ModTM callers in '$($target.Path)': invalid native JSON. $($_.Exception.Message)")
                }
                if ($callerInspections[$target.Path] -isnot [System.Collections.IDictionary]) {
                    throw [AvmConfigurationException]::new("Cannot inspect retained ModTM callers in '$($target.Path)': the module profile must expose native module calls.")
                }
            }
            $requiresModtm = @($callerInspections[$target.Path].Values | Where-Object {
                    $_ -is [System.Collections.IDictionary] -and $_['source'] -is [string] -and
                    ($_.source.StartsWith('./', [System.StringComparison]::Ordinal) -or
                    $_.source.StartsWith('../', [System.StringComparison]::Ordinal)) -and
                    $retainedPaths.Contains([System.IO.Path]::TrimEndingDirectorySeparator(
                            [System.IO.Path]::GetFullPath($_.source, $target.Path)))
                }).Count -gt 0
            if (-not $requiresModtm) { continue }
            if (-not $requiredProviders.ContainsKey($target.Path)) {
                $requiredProviders[$target.Path] = Get-AvmTerraformUnitTestRequiredProvider -Path $target.Path -Options $Options
            }
            if (-not $moduleProviderSources.ContainsKey($target.Path)) {
                $moduleProviderSources[$target.Path] = @{}
                $providerSources[$target.Path] = @(Get-AvmTerraformUnitTestProviderSource -Path $target.Path `
                        -ModuleTargets $ModuleTargets -Options $Options -ModuleProviderSources $moduleProviderSources[$target.Path] `
                        -ModuleManifests $moduleManifests)
            }
            $null = Get-AvmTerraformUnitTestModtmRequirementPlan -Path $target.Path -ModuleTargets $ModuleTargets `
                -Options $Options -RequiredProviders $requiredProviders -ProviderSources $providerSources `
                -ModuleProviderSources $moduleProviderSources -ModuleManifests $moduleManifests `
                -OriginalRequirements $allOriginalRequirements -Plans $modtmRequirementPlans -PlanningPaths $planningPaths -BindDependencies
            $null = $retainedPaths.Add($target.Path)
            $addedCaller = $true
        }
    }

    foreach ($plan in $modtmRequirementPlans.Values) {
        if ([string]::IsNullOrWhiteSpace($Options.ProfileDirs['common'])) {
            throw [AvmConfigurationException]::new("Cannot preserve ModTM mocks for '$($plan.Path)': the common ordering profile is required.")
        }
        $result = Invoke-AvmProcess -FilePath $Options.ToolPath `
            -ArgumentList (@('debug') + $plan.Arguments[1..($plan.Arguments.Count - 1)] + @('--eval', $plan.Capabilities)) `
            -WorkingDirectory $plan.Path -EnvVars $Options.EnvVars
        try {
            $supported = ConvertFrom-Json -InputObject $result.StdOut -ErrorAction Stop
        }
        catch {
            throw [AvmConfigurationException]::new(
                "Cannot verify native ModTM source preservation for '$($plan.Path)': invalid capability response. $($_.Exception.Message)")
        }
        if ($supported -isnot [bool] -or -not $supported) {
            throw [AvmConfigurationException]::new(
                "Cannot preserve ModTM mocks for '$($plan.Path)': update MaPoTF and the module profile to support exact source requirements and lossless dependency provider bindings.")
        }
    }
    foreach ($plan in $plans | Where-Object {
            $_.TelemetrySubscriptionResourceIds.Count -gt 0 -or $_.ProviderMockBindings.Count -gt 0 -or
            $_.TelemetryCountMigration.ReferenceCount -gt 0 -or $_.RetiredAliasNames.Count -gt 0
        }) {
        $capabilities = [System.Collections.Generic.List[string]]::new()
        $capabilityName = 'label-safe object merging'
        foreach ($name in $plan.TelemetrySubscriptionResourceIds.Keys) {
            $nameJson = ConvertTo-Json -InputObject $name -Compress
            $addressJson = ConvertTo-Json -InputObject "mock_provider.$name" -Compress
            $idJson = ConvertTo-Json -InputObject $plan.TelemetrySubscriptionResourceIds[$name] -Compress
            $body = "mock_data `"azapi_client_config`" {`n  defaults = {`n    subscription_resource_id = $idJson`n  }`n}"
            if ($plan.SourceClientDefaults.ContainsKey($name)) {
                $defaults = [ordered]@{}
                $keys = [string[]]@($plan.SourceClientDefaults[$name].Keys) + @('subscription_resource_id')
                [Array]::Sort($keys, [System.StringComparer]::Ordinal)
                foreach ($key in $keys) {
                    $defaults[$key] = if ($key -ceq 'subscription_resource_id') {
                        $plan.TelemetrySubscriptionResourceIds[$name]
                    }
                    else { $plan.SourceClientDefaults[$name][$key] }
                }
                $defaultsJson = ConvertTo-Json -InputObject $defaults -Depth 50 -Compress -EscapeHandling EscapeHtml
                $body = "mock_data `"azapi_client_config`" {`n  defaults = $defaultsJson`n}"
            }
            $bodyJson = ConvertTo-Json -InputObject $body -Compress
            $capabilities.Add(
                "try(transform.update_in_place.telemetry_mock[$nameJson].match_nested_block_labels, false) && " +
                "try(transform.update_in_place.telemetry_mock[$nameJson].merge_object_attributes, false) && " +
                "try(transform.update_in_place.telemetry_mock[$nameJson].target_block_address == $addressJson, false) && " +
                "try(trimspace(transform.update_in_place.telemetry_mock[$nameJson].dynamic_block_body) == $bodyJson, false)")
        }
        if ($plan.ProviderMockBindings.Count -gt 0) {
            $capabilityName = 'label-safe object merging and explicit mock provider bindings'
            foreach ($name in $plan.ProviderMockBindings.Keys) {
                $body = "providers = $($plan.ProviderMockBindings[$name])`n"
                $bodyJson = (ConvertTo-Json -InputObject $body -Compress).Replace('${', '$${').Replace('%{', '%%{')
                $nameJson = (ConvertTo-Json -InputObject $name -Compress).Replace('${', '$${').Replace('%{', '%%{')
                $capabilities.Add("try(transform.update_in_place.provider_mocks[$nameJson].dynamic_block_body == $bodyJson, false)")
            }
        }
        if ($plan.TelemetryCountMigration.ReferenceCount -gt 0) {
            $capabilityName += ' and telemetry count assertions'
            $patternJson = ConvertTo-Json -InputObject $plan.TelemetryCountMigration.Pattern -Compress
            $replacementJson = (ConvertTo-Json -InputObject $plan.TelemetryCountMigration.Replacement -Compress).Replace('${', '$${')
            $capabilities.Add(
                "try(transform.regex_replace_expression.telemetry_counts[`"counts`"].regex == $patternJson, false) && " +
                "try(transform.regex_replace_expression.telemetry_counts[`"counts`"].replacement == $replacementJson, false)")
        }
        foreach ($name in $plan.RetiredAliasNames) {
            $nameJson = ConvertTo-Json -InputObject $name -Compress
            $addressJson = ConvertTo-Json -InputObject "mock_provider.$name" -Compress
            $capabilities.Add("try(transform.remove_block.retired_mocks[$nameJson].target_block_address == $addressJson, false)")
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
    $trivia = '(?:\s|/\*[\s\S]*?\*/|//[^\r\n]*|#[^\r\n]*)*'
    $identifierReference = '(?<![A-Za-z0-9_-])random_uuid' + $trivia + '\.' + $trivia + 'telemetry(?![A-Za-z0-9_-])'
    $testScopes = @(Get-AvmTerraformTestFileScope -Root $Root -ModuleTargets $ModuleTargets)
    foreach ($scope in $testScopes) {
        $plan = $plans | Where-Object { $_.Path -ceq $scope.File.FullName } | Select-Object -First 1
        $instrumentedTargets = @($ModuleTargets |
                Where-Object { $null -ne $plan -and $_.Path -cin $plan.TargetPaths -and $_.Profiles -contains 'root' })
        if ($scope.Owner.Profiles -notcontains 'root' -and $instrumentedTargets.Count -eq 0) { continue }
        $text = [System.IO.File]::ReadAllText($scope.File.FullName)
        $references = [regex]::Matches($text, $identifierReference,
            [System.Text.RegularExpressions.RegexOptions]::CultureInvariant, [TimeSpan]::FromSeconds(1)).Count
        $validatedReferences = if ($null -ne $plan) { $plan.TelemetryCountMigration.ReferenceCount } else { 0 }
        if ($references -ne $validatedReferences) {
            throw [AvmConfigurationException]::new(
                "Test file '$($scope.File.FullName)' still references retired random_uuid.telemetry; unsupported references require review before any mock retirement.")
        }
    }
    $testPaths = @($testScopes | ForEach-Object { $_.File.FullName })
    $testSnapshot = Get-AvmFileSnapshot -Path $testPaths
    try {
        foreach ($plan in $plans | Where-Object { $_.RetiredAliasNames.Count -gt 0 }) {
            $retiredJson = ConvertTo-Json -InputObject @($plan.RetiredAliasNames) -Compress
            try {
                $null = Invoke-AvmProcess -FilePath $Options.ToolPath -ArgumentList @(
                    'transform', '--tf-dir', $plan.Scope.Owner.Path, '--test-file', $plan.Scope.RelativePath,
                    '--mptf-dir', $Options.ProfileDirs['unit-test'],
                    '--mptf-var', "retired_mock_provider_names=$retiredJson"
                ) -WorkingDirectory $plan.Scope.Owner.Path -EnvVars $Options.EnvVars
            }
            finally {
                $null = Invoke-AvmProcess -FilePath $Options.ToolPath -ArgumentList @(
                    'clean-backup', '--tf-dir', $plan.Scope.Owner.Path, '--test-file', $plan.Scope.RelativePath
                ) -WorkingDirectory $plan.Scope.Owner.Path -EnvVars $Options.EnvVars
            }
        }
        foreach ($plan in $modtmRequirementPlans.Values | Sort-Object { $_.Path.Length } -Descending) {
            try {
                $arguments = $plan.Arguments + @('--mptf-dir', $Options.ProfileDirs['common'])
                $null = Invoke-AvmProcess -FilePath $Options.ToolPath -ArgumentList $arguments `
                    -WorkingDirectory $plan.Path -EnvVars $Options.EnvVars
            }
            finally {
                $null = Invoke-AvmProcess -FilePath $Options.ToolPath -ArgumentList @('clean-backup', '--tf-dir', $plan.Path) `
                    -WorkingDirectory $plan.Path -EnvVars $Options.EnvVars
            }
        }
        Remove-AvmLegacyTelemetryTestMock -Root $Root -ModuleTargets $ModuleTargets -UnitTestPlans $plans.ToArray()
        foreach ($plan in $plans |
                Where-Object {
                    $_.NewLocationPaths.Count -gt 0 -or $_.TelemetrySubscriptionResourceIds.Count -gt 0 -or
                    $_.ProviderMockBindings.Count -gt 0 -or $_.TelemetryCountMigration.ReferenceCount -gt 0
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
    catch {
        Restore-AvmFileSnapshot -Snapshot $testSnapshot -CurrentPath $testPaths
        foreach ($path in $testPaths) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
                -not [System.Linq.Enumerable]::SequenceEqual(
                    [byte[]][System.IO.File]::ReadAllBytes($path), [byte[]]$testSnapshot[$path])) {
                throw [System.IO.IOException]::new(
                    "Terraform unit-test migration failed and could not restore the original test bytes for '$path'.", $_.Exception)
            }
        }
        throw
    }
}
