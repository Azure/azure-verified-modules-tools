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
    $plans = [System.Collections.Generic.List[object]]::new()
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
        $hasEmptyModtm = $after.test.mock_providers.Contains('modtm') -and
        $after.test.mock_providers.modtm.mptf.is_empty
        $hasEmptyAzapi = $after.test.mock_providers.Contains('azapi') -and
        $after.test.mock_providers.azapi.mptf.is_empty
        $instrumentedTargets = @($ModuleTargets |
                Where-Object { $targetPaths.Contains($_.Path) -and $_.Profiles -contains 'root' })
        $migratesTelemetry = $scope.Owner.Profiles -contains 'root' -or $instrumentedTargets.Count -gt 0
        if ($newLocations.Count -gt 0 -or ($migratesTelemetry -and ($hasEmptyModtm -or $hasEmptyAzapi))) {
            $requiresAzapiMock = @($instrumentedTargets | Where-Object { $newLocations.Contains($_.Path) }).Count -gt 0
            $hasAzureMock = $after.test.mock_providers.Contains('azapi') -or
            (-not $requiresAzapiMock -and $after.test.mock_providers.Contains('azurerm')) -or
            ($migratesTelemetry -and $hasEmptyModtm)
            $realProviders = @($after.test.providers.Keys | Where-Object { $_ -cmatch '^(azapi|azurerm)(\.|$)' })
            $aliasedMocks = @($after.test.mock_providers.Keys | Where-Object { $_ -cmatch '^(azapi|azurerm|modtm)\.' })
            $mappedRuns = @($after.test.runs.Values |
                    Where-Object { $_.mptf.attributes.Contains('providers') })
            if (-not $hasAzureMock -or $realProviders.Count -gt 0 -or
                $aliasedMocks.Count -gt 0 -or $mappedRuns.Count -gt 0) {
                throw [AvmConfigurationException]::new(
                    "Cannot automatically migrate unit test '$($scope.File.FullName)': use an unaliased mock for each introduced Azure provider, without real-provider declarations or run provider mappings.")
            }
        }
        $plans.Add([pscustomobject]@{
                Path             = $scope.File.FullName
                Scope            = $scope
                TargetPaths      = @($targetPaths)
                NewLocationPaths = @($newLocations)
            })
    }

    if (-not $PSCmdlet.ShouldProcess($Root, 'migrate scoped Terraform unit tests')) {
        return
    }
    Remove-AvmLegacyTelemetryTestMock -Root $Root -ModuleTargets $ModuleTargets -UnitTestPlans $plans.ToArray()
    foreach ($plan in $plans | Where-Object { $_.NewLocationPaths.Count -gt 0 }) {
        $encoded = (ConvertTo-Json -InputObject @($plan.NewLocationPaths) -Compress).Replace('${', '$${').Replace('%{', '%%{')
        try {
            $null = Invoke-AvmProcess -FilePath $Options.ToolPath -ArgumentList @(
                'transform', '--tf-dir', $plan.Scope.Owner.Path, '--test-file', $plan.Scope.RelativePath,
                '--mptf-dir', $Options.ProfileDirs['unit-test'],
                '--mptf-var', ("new_location_modules=$encoded")
            ) -WorkingDirectory $plan.Scope.Owner.Path -EnvVars $Options.EnvVars
        }
        finally {
            $null = Invoke-AvmProcess -FilePath $Options.ToolPath -ArgumentList @(
                'clean-backup', '--tf-dir', $plan.Scope.Owner.Path, '--test-file', $plan.Scope.RelativePath
            ) -WorkingDirectory $plan.Scope.Owner.Path -EnvVars $Options.EnvVars
        }
    }
}
