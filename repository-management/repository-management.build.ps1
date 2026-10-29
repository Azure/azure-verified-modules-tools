#Requires -Version 7.4

task 'test-tenant-terraform' {
    Import-Module $script:manifestPath -Force
    . (Join-Path $script:repoRoot 'repository-management' 'repository-sync' 'scripts' 'lib' 'RetryHelpers.ps1')
    foreach ($directory in @(
        'terraform',
        [System.IO.Path]::Combine('terraform', 'modules', 'azure'),
        [System.IO.Path]::Combine('..', 'bicep-test-tenant-sync', 'terraform')
    )) {
        $directoryName = $directory.Replace([string][System.IO.Path]::DirectorySeparatorChar, '-')
        if ($directory.StartsWith('..')) { $directoryName = 'bicep-identities' }
        $root = Join-Path $script:repoRoot 'repository-management' 'repository-sync' $directory
        $formatPaths = @('main.tf', 'variables.tf', 'tests')
        if ($directory -eq 'terraform') {
            $formatPaths += @(
                'locals.tf', 'terraform.tf', 'outputs.tf', 'retired-identity.tf',
                'tests/fixtures/retired-identity/main.tf', 'tests/fixtures/retired-identity/azure/main.tf',
                'tests/fixtures/repository-template/main.tf'
            )
        }
        else {
            $formatPaths += @('locals.tf', 'terraform.tf', 'outputs.tf')
        }
        $environment = @{
            GH_TOKEN = $null; GITHUB_TOKEN = $null; TF_IN_AUTOMATION = 'true'; TF_INPUT = 'false'
            TF_CLI_ARGS = $null; TF_CLI_ARGS_init = $null; TF_CLI_ARGS_validate = $null
            TF_CLI_ARGS_test = $null; TF_CLI_ARGS_plan = $null; TF_CLI_ARGS_apply = $null
        }
        if ($env:TF_DATA_DIR) {
            $environment.TF_DATA_DIR = Join-Path $env:TF_DATA_DIR $directoryName
        }
        foreach ($arguments in @(
            (@('fmt', '-check', '-diff') + $formatPaths),
            @('init', '-backend=false', '-input=false', '-no-color'),
            @('validate', '-no-color'),
            @('test', '-json', '-verbose')
        )) {
            if ($directory -eq 'terraform' -and $arguments[0] -eq 'test') {
                $traceRoot = Join-Path $script:outRoot 'test-results'
                $null = [System.IO.Directory]::CreateDirectory($traceRoot)
                $environment.TF_LOG = 'TRACE'
                $environment.TF_LOG_PATH = Join-Path $traceRoot 'retired-identity.terraform.trace.log'
                [System.IO.File]::WriteAllText($environment.TF_LOG_PATH, '')
            }
            $result = Invoke-RepositorySyncProcess -Command terraform -Arguments $arguments -WorkingDirectory $root -TimeoutSec 600 `
                -EnvVars $environment
            if ($result.ExitCode -ne 0) {
                if ($arguments[0] -eq 'test') {
                    $events = @($result.StdOut -split '\r?\n' | Where-Object { $_ } | ForEach-Object { ConvertFrom-Json -InputObject $_ -AsHashtable -Depth 100 })
                    $resultDirectory = Join-Path $script:outRoot 'test-results'
                    $null = [System.IO.Directory]::CreateDirectory($resultDirectory)
                    [System.IO.File]::WriteAllText((Join-Path $resultDirectory "$directoryName.terraform.jsonl"), $result.StdOut)
                    $diagnostics = @($events | Where-Object { $_['@level'] -ceq 'error' } | ForEach-Object { $_['@message'] })
                    throw [System.InvalidOperationException]::new("Tenant Terraform $directory tests failed (exit $($result.ExitCode)).`n$($diagnostics -join "`n")`n$($result.StdErr)")
                }
                throw [System.InvalidOperationException]::new("Tenant Terraform $directory $($arguments[0]) failed: $($result.StdOut) $($result.StdErr)")
            }
            Write-Build Green "  $directory $($arguments[0]) OK"
            if ($arguments[0] -eq 'test') {
                $resultDirectory = Join-Path $script:outRoot 'test-results'
                $null = [System.IO.Directory]::CreateDirectory($resultDirectory)
                [System.IO.File]::WriteAllText(
                    (Join-Path $resultDirectory "$directoryName.terraform.jsonl"),
                    $result.StdOut,
                    [System.Text.UTF8Encoding]::new($false)
                )
                $events = @($result.StdOut -split '\r?\n' | Where-Object { $_ } | ForEach-Object { ConvertFrom-Json -InputObject $_ -AsHashtable -Depth 100 })
                $summary = @($events | Where-Object { $_['type'] -eq 'test_summary' })
                if ($summary.Count -ne 1) {
                    throw [System.IO.InvalidDataException]::new('Terraform did not return a complete mocked-test summary.')
                }
                Write-Host $summary[0]['@message']
                if ($directory -eq 'terraform') {
                    . (Join-Path $script:repoRoot 'repository-management' 'repository-sync' 'scripts' 'lib' 'TestTenant.ps1')
                    $seedStates = @($events | Where-Object {
                            $_['type'] -ceq 'test_state' -and $_['@testrun'] -ceq 'seed_only_disposable_mock_retired_state'
                        })
                    $retirementPlans = @($events | Where-Object {
                            $_['type'] -ceq 'test_plan' -and $_['@testrun'] -ceq 'forget_only_retired_state_without_refresh'
                        })
                    if ($seedStates.Count -ne 1 -or $retirementPlans.Count -ne 1) {
                        throw [System.IO.InvalidDataException]::new('Retirement requires one disposable mocked seed state and its actual forget-only plan.')
                    }
                    $seedResources = @(Get-AvmTerraformPlannedResource -Module $seedStates[0]['test_state']['root_module'])
                    $seedManaged = @($seedResources | Where-Object { $_['mode'] -ceq 'managed' })
                    $retirementChanges = @($retirementPlans[0]['test_plan']['resource_changes'])
                    $forgotten = @($retirementChanges | Where-Object { $_['change']['actions'] -contains 'forget' })
                    if ($seedManaged.Count -ne 7 -or $forgotten.Count -ne $seedManaged.Count -or
                        @($retirementChanges | Where-Object { $_['change']['actions'] -contains 'delete' }).Count -gt 0) {
                        throw [System.IO.InvalidDataException]::new('Retirement must forget exactly the seven retired fixture objects without any destruction.')
                    }
                    foreach ($change in $forgotten) {
                        $source = @($seedManaged | Where-Object { $_['address'] -ceq $change['address'] })
                        if (-not $change['address'].StartsWith('module.azure[0].') -or $source.Count -ne 1 -or
                            (@($change['change']['actions']) -join ',') -cne 'forget' -or
                            $null -ne $change['change']['after'] -or
                            (ConvertTo-Json -InputObject $source[0]['values'] -Depth 100 -Compress) -cne
                            (ConvertTo-Json -InputObject $change['change']['before'] -Depth 100 -Compress)) {
                            throw [System.IO.InvalidDataException]::new('Retired objects must retain their original mocked before-values and only forget within the old module.')
                        }
                    }
                    $trace = [System.IO.File]::ReadAllLines($environment.TF_LOG_PATH)
                    $start = [Array]::FindIndex($trace, [Predicate[string]]{ param($line)
                        $line.Contains('starting plan for forget_only_retired_state_without_refresh')
                    })
                    $end = [Array]::FindIndex($trace, [Predicate[string]]{ param($line)
                        $line.Contains('completed plan for forget_only_retired_state_without_refresh')
                    })
                    if ($start -lt 0 -or $end -le $start) {
                        throw [System.IO.InvalidDataException]::new('Retirement trace must identify the actual mocked plan execution.')
                    }
                    $planTrace = $trace[$start..$end]
                    if (@($planTrace | Where-Object {
                                $_.Contains('module.azure[0]') -and $_ -match 'NodeAbstractResourceInstance\.refresh:|readDataSource:|\bReadResource\b|\bReadDataSource\b'
                            }).Count -gt 0) {
                        throw [System.IO.InvalidDataException]::new('Retired-tenant resource refresh or data-source reads are forbidden.')
                    }
                    foreach ($data in @($seedResources | Where-Object { $_['mode'] -ceq 'data' })) {
                        if (@($planTrace | Where-Object {
                                    $_.Contains("NodePlannableResourceInstanceOrphan: removing state object for $($data['address'])")
                                }).Count -ne 1) {
                            throw [System.IO.InvalidDataException]::new('Retired data sources must be removed from disposable state without re-reading them.')
                        }
                    }
                    Write-Build Green '  retired fixture: seven unchanged forget actions, zero refresh/read/destroy'
                }
                if ($directory -eq 'terraform') {
                    . (Join-Path $script:repoRoot 'repository-management' 'repository-sync' 'scripts' 'lib' 'TestTenant.ps1')
                    . (Join-Path $script:repoRoot 'tests' 'fixtures' 'TestTenant.ps1')
                    $plans = @($events | Where-Object {
                            $_['type'] -eq 'test_plan' -and $_['@testrun'] -ceq 'unified_plan_binds_the_expected_tenant'
                        })
                    if ($plans.Count -ne 1) {
                        throw [System.IO.InvalidDataException]::new('Expected one actual mocked-provider unified plan.')
                    }
                    $candidatePlan = $plans[0]['test_plan']
                    if (-not $candidatePlan.Contains('planned_values')) {
                        $candidatePlan = ConvertFrom-AvmTestTerraformPlan -Plan $candidatePlan -GroupContracts @{
                            'module.bami[0]' = $candidatePlan['output_changes']['test_group_contract']['after']
                        }
                    }
                    . (Join-Path $script:repoRoot 'repository-management' 'repository-sync' 'scripts' 'lib' 'RepositoryConfig.ps1')
                    $repositoryConfig = Get-Content -LiteralPath (Join-Path $script:repoRoot 'repository-management' 'repository-config' 'config.json') -Raw | ConvertFrom-Json
                    $groupNames = (Resolve-RepositorySettings -repositoryConfig $repositoryConfig -repoId 'avm-ptn-example-repo').EntraGroups
                    $repository = [pscustomobject]@{
                        full_name = 'Azure/terraform-azurerm-avm-ptn-example-repo'
                        id = 1234
                        owner = [pscustomobject]@{ id = 6844498 }
                    }
                    Assert-AvmRepositorySyncPlan -Plan $candidatePlan -Settings (Get-AvmBamiSettings -Values (New-AvmTestBamiSettings)) `
                        -Repository $repository -RepositorySyncRepositoryId '1239632211' -EntraGroupNames $groupNames
                    $applied = @($events | Where-Object {
                        $_['type'] -ceq 'test_state' -and $_['@testrun'] -ceq 'single_apply_populates_identity_and_consumer_settings'
                    })
                    if ($applied.Count -ne 1) {
                        throw [System.IO.InvalidDataException]::new('Expected one actual unified mocked apply state.')
                    }
                    $appliedResources = @(Get-AvmTerraformPlannedResource -Module $applied[0]['test_state']['root_module'])
                    $secret = @($appliedResources | Where-Object {
                        $_['type'] -ceq 'github_actions_secret' -and $_['values']['secret_name'] -ceq 'ARM_CLIENT_ID'
                    })
                    $identity = @($appliedResources | Where-Object { $_['address'] -ceq 'module.bami[0].azapi_resource.identity[0]' })
                    if ($secret.Count -ne 1 -or $identity.Count -ne 1 -or
                        $secret[0]['values']['value'] -cne $identity[0]['values']['output']['properties']['clientId']) {
                        throw [System.IO.InvalidDataException]::new('The single mocked apply must publish its own execution client ID through the GitHub secret.')
                    }
                    Write-Build Green '  unified plan passes the ownership guard; one apply resolves GitHub and identity dependencies'
                }
                if ($directoryName -ceq 'terraform-modules-azure') {
                    . (Join-Path $script:repoRoot 'repository-management' 'repository-sync' 'scripts' 'lib' 'TestTenant.ps1')
                    . (Join-Path $script:repoRoot 'repository-management' 'bicep-test-tenant-sync' 'scripts' 'lib' 'ModuleConfig.ps1')
                    . (Join-Path $script:repoRoot 'repository-management' 'bicep-test-tenant-sync' 'scripts' 'lib' 'ModuleIdentitySync.ps1')
                    . (Join-Path $script:repoRoot 'tests' 'fixtures' 'TestTenant.ps1')
                    . (Join-Path $script:repoRoot 'tests' 'fixtures' 'BicepIdentities.ps1')
                    $settings = Get-AvmBamiSettings -Values (New-AvmTestBamiSettings)
                    foreach ($ecosystem in @('terraform', 'bicep')) {
                        $plans = @($events | Where-Object {
                            $_['type'] -ceq 'test_plan' -and $_['@testrun'] -ceq "rename_legacy_${ecosystem}_identity"
                        })
                        if ($plans.Count -ne 1) {
                            throw [System.IO.InvalidDataException]::new("Expected one actual mocked $ecosystem identity rename plan.")
                        }
                        $address = if ($ecosystem -ceq 'bicep') { 'module.bicep["avm/res/fabric/capacity"]' } else { 'module.azure' }
                        $evidence = $plans[0]['test_plan']['output_changes']['test_group_contract']['after']
                        $candidatePlan = ConvertFrom-AvmTestTerraformPlan -Plan $plans[0]['test_plan'] `
                            -GroupContracts @{ $address = $evidence } -AddressPrefix "$address."
                        if (@($candidatePlan.resource_changes | Where-Object { $_['change']['actions'] -contains 'delete' }).Count -ne
                            $(if ($ecosystem -ceq 'bicep') { 5 } else { 7 })) {
                            throw [System.IO.InvalidDataException]::new('A mocked naming migration must replace its identity, every credential and both individual memberships.')
                        }
                        if ($ecosystem -ceq 'bicep') {
                            $previous = Assert-AvmBicepIdentityPlan -Plan $candidatePlan -Settings $settings `
                                -Modules @{ 'avm/res/fabric/capacity' = @('repository-readers', 'repository-owners') } `
                                -Context (New-AvmTestBicepIdentityContext) -PassThru
                            $previous = $previous['avm/res/fabric/capacity']
                        }
                        else {
                            $previous = Assert-AvmBamiIdentityPlan -Plan $candidatePlan -Settings $settings `
                                -Repository 'Azure/terraform-azurerm-avm-ptn-azuremonitorwindowsagent' -RepositoryId '1234' `
                                -RepositoryOwnerId '6844498' -RepositorySyncRepositoryId '1239632211' `
                                -EntraGroupNames @('repository-readers', 'repository-owners') -PassThru
                        }
                        if ($previous.client_id -cne '10000000-0000-4000-8000-000000000106') {
                            throw [System.IO.InvalidDataException]::new('The guard must recover the actual previous identity from the mocked rename plan.')
                        }
                        Write-Build Green "  $ecosystem naming replacement passes its production ownership guard"
                    }
                    $recoveryPlans = @($events | Where-Object {
                        $_['type'] -ceq 'test_plan' -and $_['@testrun'] -ceq 'recreate_windows_identity_after_its_legacy_resources_were_deleted'
                    })
                    if ($recoveryPlans.Count -ne 1) {
                        throw [System.IO.InvalidDataException]::new('Expected one actual mocked windows identity recreation plan.')
                    }
                    $plan = $recoveryPlans[0]['test_plan']
                    $candidatePlan = ConvertFrom-AvmTestTerraformPlan -Plan $plan -AddressPrefix 'module.azure.' `
                        -GroupContracts @{ 'module.azure' = $plan['output_changes']['test_group_contract']['after'] }
                    $managed = @($candidatePlan.resource_changes | Where-Object { $_['mode'] -ceq 'managed' })
                    if ($managed.Count -ne 8 -or @($managed | Where-Object { (@($_['change']['actions']) -join ',') -cne 'create' }).Count -gt 0) {
                        throw [System.IO.InvalidDataException]::new('Recovery after legacy deletion must only create the eight missing identity resources.')
                    }
                    Assert-AvmBamiIdentityPlan -Plan $candidatePlan -Settings $settings `
                        -Repository 'Azure/terraform-azurerm-avm-ptn-azuremonitorwindowsagent' -RepositoryId '1234' `
                        -RepositoryOwnerId '6844498' -RepositorySyncRepositoryId '1239632211' `
                        -EntraGroupNames @('repository-readers', 'repository-owners')
                    Write-Build Green '  windows identity recreation passes its production ownership guard'
                }
                if ($directoryName -ceq 'bicep-identities') {
                    . (Join-Path $script:repoRoot 'repository-management' 'repository-sync' 'scripts' 'lib' 'TestTenant.ps1')
                    . (Join-Path $script:repoRoot 'repository-management' 'bicep-test-tenant-sync' 'scripts' 'lib' 'ModuleConfig.ps1')
                    . (Join-Path $script:repoRoot 'repository-management' 'bicep-test-tenant-sync' 'scripts' 'lib' 'ModuleIdentitySync.ps1')
                    . (Join-Path $script:repoRoot 'tests' 'fixtures' 'TestTenant.ps1')
                    . (Join-Path $script:repoRoot 'tests' 'fixtures' 'BicepIdentities.ps1')
                    $plans = @($events | Where-Object {
                        $_['type'] -ceq 'test_plan' -and $_['@testrun'] -ceq 'module_plan_binds_identities_groups_and_workflows'
                    })
                    if ($plans.Count -ne 1) {
                        throw [System.IO.InvalidDataException]::new('Expected one actual mocked-provider Bicep module plan.')
                    }
                    $candidatePlan = $plans[0]['test_plan']
                    if (-not $candidatePlan.Contains('planned_values')) {
                        $contracts = $candidatePlan['output_changes']['test_group_contract']['after']
                        if ($contracts -isnot [System.Collections.IDictionary] -or $contracts.Count -ne 2) {
                            throw [System.IO.InvalidDataException]::new('The Bicep mock plan must expose both modules and their observed group evidence.')
                        }
                        $groupContracts = @{}
                        foreach ($path in $contracts.Keys) {
                            $groupContracts["module.bicep[`"$path`"]"] = $contracts[$path]
                        }
                        $candidatePlan = ConvertFrom-AvmTestTerraformPlan -Plan $candidatePlan -GroupContracts $groupContracts
                    }
                    $configuration = ConvertFrom-AvmTestTenantJson -Json (
                        Get-Content -LiteralPath (Join-Path $script:repoRoot 'repository-management' 'bicep-config' 'config.json') -Raw
                    )
                    $modules = Resolve-AvmBicepModuleSettings -ModulePaths @('avm/res/fabric/capacity', 'avm/res/storage/storage-account') -Configuration $configuration
                    $settings = Get-AvmBamiSettings -Values (New-AvmTestBamiSettings)
                    Assert-AvmBicepIdentityPlan -Plan $candidatePlan -Settings $settings -Modules $modules -Context (New-AvmTestBicepIdentityContext)
                    $applied = @($events | Where-Object {
                        $_['type'] -ceq 'test_state' -and $_['@testrun'] -ceq 'one_apply_returns_the_complete_module_mapping'
                    })
                    if ($applied.Count -ne 1) {
                        throw [System.IO.InvalidDataException]::new('Expected one applied Bicep identity mock state.')
                    }
                    $null = ConvertTo-AvmBicepIdentityMapping -Identities $applied[0]['test_state']['outputs']['test_identities']['value'] `
                        -ModulePaths @($modules.Keys) -Settings $settings
                    $stable = @($events | Where-Object {
                        $_['type'] -ceq 'test_plan' -and $_['@testrun'] -ceq 'subsequent_plan_keeps_the_same_names_and_client_ids'
                    })
                    if ($stable.Count -ne 1 -or @($stable[0]['test_plan']['resource_changes'] | Where-Object {
                        $_['mode'] -ceq 'managed' -and (@($_['change']['actions']) -join ',') -cne 'no-op'
                    }).Count -gt 0) {
                        throw [System.IO.InvalidDataException]::new('An unchanged Bicep inventory must not replace or modify its applied identities, federation or memberships.')
                    }
                    $groupContracts = @{}
                    foreach ($path in $modules.Keys) {
                        $groupContracts["module.bicep[`"$path`"]"] = $stable[0]['test_plan']['output_changes']['test_group_contract']['after'][$path]
                    }
                    $stablePlan = ConvertFrom-AvmTestTerraformPlan -Plan $stable[0]['test_plan'] -GroupContracts $groupContracts
                    Assert-AvmBicepIdentityPlan -Plan $stablePlan -Settings $settings -Modules $modules -Context (New-AvmTestBicepIdentityContext)
                    Write-Build Green '  Bicep mock plan passes the ownership guard; one apply produces the complete dedicated mapping'
                }
            }
        }
    }
}
