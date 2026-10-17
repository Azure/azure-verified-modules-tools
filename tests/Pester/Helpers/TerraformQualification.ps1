function Invoke-MockedTerraformQualification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TerraformPath,
        [Parameter(Mandatory)] [string] $MapotfPath,
        [Parameter(Mandatory)] [string] $ProfilesRoot,
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string[]] $ArgumentList,
        [Parameter(Mandatory)] [hashtable] $Environment,
        [object[]] $ModuleTargets = @(),
        [switch] $InspectOnly
    )

    $directories = @($ArgumentList | Where-Object { $_ -clike '-test-directory*' })
    if ($ArgumentList[0] -cne 'test' -or $directories.Count -ne 1 -or
        $directories[0] -cne '-test-directory=tests/unit') {
        throw [System.InvalidOperationException]::new('Native qualification requires the inspected tests/unit directory.')
    }
    $inspectionEnvironment = [hashtable]::new([System.StringComparer]::Ordinal)
    foreach ($entry in $Environment.GetEnumerator()) { $inspectionEnvironment[$entry.Key] = $entry.Value }
    foreach ($name in @([Environment]::GetEnvironmentVariables('Process').Keys) + @($inspectionEnvironment.Keys)) {
        if ($name -match '^(ARM_|AZURE_|ACTIONS_ID_TOKEN_|TF_CLI_ARGS|SYSTEM_ACCESSTOKEN$|SYSTEM_OIDCREQUESTURI$)') {
            $inspectionEnvironment[$name] = $null
        }
    }
    foreach ($name in @('ARM_USE_CLI', 'ARM_USE_MSI', 'ARM_USE_OIDC', 'ARM_USE_AKS_WORKLOAD_IDENTITY')) {
        $inspectionEnvironment[$name] = 'false'
    }
    $inspectionEnvironment.MODTM_ENDPOINT = 'http://127.0.0.1:1/never-production'
    $inspectionEnvironment.CHECKPOINT_DISABLE = '1'
    $isolated = $inspectionEnvironment.Clone()
    foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy')) {
        $isolated[$name] = 'http://127.0.0.1:1'
    }
    foreach ($name in @('NO_PROXY', 'no_proxy')) { $isolated[$name] = '' }

    & (Get-Module Avm.Authoring) {
        param($Terraform, $Mapotf, $Profiles, $Root, $Arguments, $InspectionEnvironment, $RuntimeEnvironment, $Targets, $InspectOnly)
        $rootTests = @(Get-ChildItem -LiteralPath $Root -File -Force |
                Where-Object { $_.Name -like '*.tftest.hcl' -or $_.Name -like '*.tftest.json' })
        if ($rootTests.Count -gt 0) {
            throw [System.InvalidOperationException]::new('Native qualification rejects uninspected root test files.')
        }
        $files = @(Get-ChildItem -LiteralPath (Join-Path $Root 'tests' 'unit') -File -Force)
        if (@($files | Where-Object Name -Like '*.tftest.json').Count -gt 0) {
            throw [System.InvalidOperationException]::new('Native qualification cannot establish mock coverage for JSON tests.')
        }
        $files = @($files | Where-Object Name -Like '*.tftest.hcl')
        if ($files.Count -eq 0) {
            throw [System.InvalidOperationException]::new('Native qualification found no test files to inspect.')
        }
        $target = [pscustomobject]@{ Path = $Root; Scope = 'root'; Profiles = @('root', 'module', 'common') }
        if ($Targets.Count -eq 0) { $Targets = @($target) }
        $inspectionRoot = Join-Path ([IO.Path]::GetTempPath()) ('avm-mock-proof-' + [guid]::NewGuid().ToString('N'))
        $options = [pscustomobject]@{
            ToolPath = $Mapotf
            TerraformPath = $Terraform
            ProfileDirs = @{
                module = Join-Path $Profiles 'module'
                'unit-test-inspect' = Join-Path $Profiles 'unit-test-inspect'
            }
            EnvVars = $InspectionEnvironment
            InspectionRoot = $inspectionRoot
            InspectionModuleCache = @{}
        }
        try {
            $tree = Invoke-AvmProcess -FilePath $Terraform -WorkingDirectory $Root -EnvVars $InspectionEnvironment `
                -ArgumentList @('providers', '-no-color', '-test-directory=tests/unit')
            $sourcesByTarget = @{ $Root = @(ConvertFrom-AvmTerraformProviderTree -Text $tree.StdOut -Path $Root) }
            $requiredByTarget = @{ $Root = Get-AvmTerraformUnitTestRequiredProvider -Path $Root -Options $options }
            foreach ($file in $files) {
                $scope = [pscustomobject]@{
                    File = $file
                    Owner = $target
                    RelativePath = [IO.Path]::GetRelativePath($Root, $file.FullName).Replace('\', '/')
                }
                $inspection = Get-AvmTerraformUnitTestInspection -Scope $scope -ModuleTargets $Targets -Options $options
                $test = $inspection.test
                if ($test.providers.Count -gt 0) {
                    throw [System.InvalidOperationException]::new("Native qualification rejects real provider configurations in '$($file.Name)'.")
                }
                if ($test.runs.Count -eq 0) {
                    throw [System.InvalidOperationException]::new("Native qualification requires inspectable runs in '$($file.Name)'.")
                }
                $mocks = @($test.mock_providers.Keys)
                $defaults = @($mocks | Where-Object { $_ -notmatch '\.' })
                foreach ($runName in $test.runs.Keys) {
                    $run = $test.runs[$runName]
                    $runTarget = $test.run_modules[$runName]
                    if ($runTarget -isnot [Collections.IDictionary] -or $runTarget.kind -cnotin @('root', 'local') -or
                        $runTarget.dir -cnotin @($Targets.Path)) {
                        throw [System.InvalidOperationException]::new("Native qualification requires a known local target for '$runName'.")
                    }
                    $path = $runTarget.dir
                    if (-not $sourcesByTarget.ContainsKey($path)) {
                        $sourcesByTarget[$path] = @(Get-AvmTerraformUnitTestProviderSource -Path $path -ModuleTargets $Targets -Options $options)
                        $requiredByTarget[$path] = Get-AvmTerraformUnitTestRequiredProvider -Path $path -Options $options
                    }
                    $sources = @($sourcesByTarget[$path])
                    if ($sources -ccontains 'registry.terraform.io/azure/alz') {
                        throw [System.InvalidOperationException]::new('ALZ library fixtures are preservation-only; mocked outputs cannot qualify their runtime assertions.')
                    }
                    $provenDefaults = @(Get-AvmTerraformUnitTestMockProviderName -ProviderNames $defaults `
                            -RequiredProviders $requiredByTarget[$path] -ProviderSources $sources)
                    $requiredMocks = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                    foreach ($source in $sources) {
                        $matching = @(Get-AvmTerraformUnitTestMockProviderName -ProviderNames $provenDefaults `
                                -RequiredProviders $requiredByTarget[$path] -ProviderSources @($source))
                        if ($matching.Count -eq 0) {
                            throw [System.InvalidOperationException]::new("Native qualification requires a default mock for '$source' in '$($file.Name)' run '$runName'.")
                        }
                        foreach ($name in $matching) { $null = $requiredMocks.Add($name) }
                    }
                    if (-not $run.mptf.attributes.Contains('providers')) { continue }
                    $mapping = ConvertFrom-AvmTerraformUnitTestProviderMapping -Expression $run.mptf.attributes.providers `
                        -ProviderNames @($requiredMocks) -MockProviderNames $mocks
                    if ($null -eq $mapping) {
                        throw [System.InvalidOperationException]::new("Native qualification requires complete known same-provider mock mappings in '$($file.Name)' run '$runName'.")
                    }
                }
            }
            if ($InspectOnly) { return $RuntimeEnvironment }
            Invoke-AvmProcess -FilePath $Terraform -ArgumentList $Arguments -WorkingDirectory $Root -EnvVars $RuntimeEnvironment
        }
        finally {
            if (Test-Path -LiteralPath $inspectionRoot -PathType Container) {
                Remove-Item -LiteralPath $inspectionRoot -Recurse -Force -ErrorAction Stop
            }
        }
    } $TerraformPath $MapotfPath $ProfilesRoot $Root $ArgumentList $inspectionEnvironment $isolated $ModuleTargets ([bool]$InspectOnly)
}
