BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $lib = Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'lib'
    . (Join-Path $lib 'Logging.ps1')
    . (Join-Path $lib 'TestTenant.ps1')
    . (Join-Path $script:root 'tests' 'fixtures' 'TestTenant.ps1')
}

Describe 'Repository Terraform saved-plan execution' -Tag Component {
    BeforeEach {
        $script:fixture = @{
            Plan = New-AvmTestRepositorySyncPlan -KnownClient
            Calls = [System.Collections.Generic.List[object]]::new()
            FailAt = ''
            InvalidJson = $false
        }
        $fixture = $script:fixture
        Mock Invoke-RepositorySyncProcess ({
            param($Command, $Arguments, $WorkingDirectory, $EnvVars, $TimeoutSec)
            if ($Command -cne 'terraform') { throw 'Unexpected command in isolated Terraform test.' }
            $fixture.Calls.Add(@{
                Arguments = @($Arguments); Root = $WorkingDirectory; Environment = $EnvVars; Timeout = $TimeoutSec
            })
            if ($fixture.FailAt -ceq $Arguments[0]) {
                return @{ ExitCode = 7; StdOut = 'failed native output'; StdErr = 'native failure detail' }
            }
            $text = if ($Arguments[0] -ceq 'show') {
                $fixture.InvalidJson ? 'not JSON with private material' : (ConvertTo-Json -InputObject $fixture.Plan -Depth 100)
            } else { "native $($Arguments[0]) output" }
            return @{ ExitCode = 0; StdOut = $text; StdErr = '' }
        }.GetNewClosure())
        Mock Start-Process { throw 'No legacy process or state-repair path is permitted.' }
        $script:parameters = @{
            terraformModulePath = $TestDrive
            repoId = 'avm-ptn-example-repo'
            orgAndRepoName = 'Azure/terraform-azurerm-avm-ptn-example-repo'
            planOnly = $false
            resourceTypesThatCannotBeDestroyed = @('github_repository')
            bamiSettings = New-AvmTestBamiSettings
            repository = [pscustomobject]@{
                full_name = 'Azure/terraform-azurerm-avm-ptn-example-repo'
                id = 1234
                owner = [pscustomobject]@{ id = 6844498 }
            }
            repositorySyncRepositoryId = '1239632211'
            entraGroupNames = @('avm-test-entra-readers', 'avm-test-identity-owners')
            issueLog = @()
        }
        $script:parameters.environment = Get-RepositorySyncTerraformEnvironment -Root $TestDrive -Settings $script:parameters.bamiSettings
    }

    It 'uses one guarded saved plan with known client <Known> and plan-only <PlanOnly>' -ForEach @(
        @{ Known = $false; PlanOnly = $false }
        @{ Known = $false; PlanOnly = $true }
        @{ Known = $true; PlanOnly = $false }
        @{ Known = $true; PlanOnly = $true }
    ) {
        $script:fixture.Plan = New-AvmTestRepositorySyncPlan -KnownClient:$Known
        $script:parameters.planOnly = $PlanOnly
        $null = Invoke-TerraformPlanAndApply @script:parameters
        $script:fixture.Calls.Arguments | Where-Object { $_ -ceq 'plan' } | Should -HaveCount 1
        $script:fixture.Calls.Count | Should -Be ($PlanOnly ? 2 : 3)
        $script:fixture.Calls[0].Arguments | Should -Contain '-lock-timeout=5m'
        $path = Join-Path $TestDrive 'avm-ptn-example-repo.tfplan'
        $script:fixture.Calls[0].Arguments | Should -Contain "-out=$path"
        $script:fixture.Calls[1].Arguments | Should -Be @('show', '-json', $path)
        if (-not $PlanOnly) {
            $script:fixture.Calls[2].Arguments | Should -Be @('apply', '-input=false', '-no-color', '-lock-timeout=5m', $path)
        }
        foreach ($call in $script:fixture.Calls) {
            $call.Root | Should -Be $TestDrive
            $call.Environment.ARM_TENANT_ID | Should -Be $script:parameters.bamiSettings.TEST_BAMI_TENANT_ID
            $call.Environment.ARM_CLIENT_ID | Should -Be $script:parameters.bamiSettings.TEST_BAMI_CONTROLLER_CLIENT_ID
            $call.Environment.ARM_USE_CLI | Should -BeExactly 'false'
            $call.Environment.ARM_USE_MSI | Should -BeExactly 'false'
            $call.Timeout | Should -Be 1800
        }
        Should -Invoke Start-Process -Exactly 0
    }

    It 'deliberately retires transferred legacy BAMI permissions without losing ownership' {
        $script:fixture.Plan = New-AvmTestRepositorySyncPlan -KnownClient -OwnerMigration -LegacyMembershipMigration
        $null = Invoke-TerraformPlanAndApply @script:parameters
        $script:fixture.Calls.Count | Should -Be 3
    }

    It 'allows only coherent forget-only retired-tenant entries beside live BAMI ownership' {
        $script:fixture.Plan.resource_changes += @(New-AvmTestRetiredIdentityChanges)
        $null = Invoke-TerraformPlanAndApply @script:parameters
        $script:fixture.Calls.Count | Should -Be 3
    }

    It 'allows cached repository-name aliases when the immutable GitHub ID still matches' {
        $change = $script:fixture.Plan.resource_changes[-1].change
        $change.before.id = 'previous-name'
        $change.before.name = 'previous-name'
        $change.before.full_name = 'Azure/previous-name'
        $change.after.id = 'previous-name'
        $null = Invoke-TerraformPlanAndApply @script:parameters
        $script:fixture.Calls.Count | Should -Be 3
    }

    It 'rejects unsafe or partial plans before apply: <Case>' -ForEach @(
        @{ Case = 'protected repository deletion'; Mutate = { param($p) $p.resource_changes[-1].change.actions = @('delete') }; Message = '*protected resource*' }
        @{ Case = 'wrong GitHub state'; Mutate = { param($p) $p.resource_changes[-1].change.before.repo_id = 9876 }; Message = '*different GitHub repository*' }
        @{ Case = 'repository rename'; Mutate = { param($p) $p.resource_changes[-1].change.after.name = 'terraform-azurerm-avm-ptn-other' }; Message = '*different GitHub repository*' }
        @{ Case = 'wrong GitHub owner'; Mutate = { param($p) $p.resource_changes[-1].change.after.full_name = 'Another/terraform-azurerm-avm-ptn-example-repo' }; Message = '*different GitHub repository*' }
        @{ Case = 'missing GitHub anchor'; Mutate = {
            param($p)
            $p.resource_changes = @($p.resource_changes | Where-Object { $_.address -cne 'module.github.github_repository.this' })
            $p.planned_values.root_module.child_modules = @($p.planned_values.root_module.child_modules | Where-Object { $_.address -cne 'module.github' })
        }; Message = '*verified GitHub repository*' }
        @{ Case = 'identity replacement'; Mutate = { param($p) $p.resource_changes[0].change.actions = @('delete', 'create') }; Message = '*must not delete or replace*' }
        @{ Case = 'wrong provider'; Mutate = { param($p) $p.resource_changes[0].provider_name = 'registry.terraform.io/hashicorp/azurerm' }; Message = '*provider binding*' }
        @{ Case = 'split address'; Mutate = { param($p) $p.resource_changes[0].address = 'module.azure.azapi_resource.identity' }; Message = '*provider binding*' }
        @{ Case = 'partial transfer'; Mutate = { param($p) $p.planned_values.root_module.child_modules[0].resources = @($p.planned_values.root_module.child_modules[0].resources | Select-Object -Skip 1) }; Message = '*complete dedicated*' }
        @{ Case = 'wrong identity resource ID'; Mutate = { param($p) $p.planned_values.root_module.child_modules[0].resources[0].values.id += '-wrong' }; Message = '*expected repository*' }
        @{ Case = 'controller client'; Mutate = { param($p) $p.planned_values.root_module.child_modules[0].resources[0].values.output.properties.clientId = '10000000-0000-4000-8000-000000000002' }; Message = '*dedicated repository client*' }
        @{ Case = 'unrefreshed evidence'; Mutate = { param($p) $p.Remove('prior_state') }; Message = '*refreshed Terraform*' }
        @{ Case = 'errored plan'; Mutate = { param($p) $p.errored = $true }; Message = '*incomplete or errored*' }
        @{ Case = 'incomplete retired state'; Mutate = { param($p) $p.resource_changes += @(New-AvmTestRetiredIdentityChanges | Select-Object -Skip 1) }; Message = '*Partial retired-tenant*' }
        @{ Case = 'BAMI identity under retired address'; Mutate = {
            param($p)
            $old = @(New-AvmTestRetiredIdentityChanges)
            $old[0].change.before.output.properties.tenantId = '10000000-0000-4000-8000-000000000001'
            $p.resource_changes += $old
        }; Message = '*retired tenant*' }
        @{ Case = 'retired provider mismatch'; Mutate = {
            param($p)
            $old = @(New-AvmTestRetiredIdentityChanges)
            $old[0].provider_name = 'registry.terraform.io/hashicorp/null'
            $p.resource_changes += $old
        }; Message = '*provider binding*' }
    ) {
        & $Mutate $script:fixture.Plan
        { Invoke-TerraformPlanAndApply @script:parameters } | Should -Throw $Message
        $script:fixture.Calls.Count | Should -Be 2
        Should -Invoke Start-Process -Exactly 0
    }

    It 'never replans or reapplies a failed native operation: <Command>' -ForEach @(
        @{ Command = 'plan'; Calls = 1 }
        @{ Command = 'show'; Calls = 2 }
        @{ Command = 'apply'; Calls = 3 }
    ) {
        $script:fixture.FailAt = $Command
        { Invoke-TerraformPlanAndApply @script:parameters } | Should -Throw "*Terraform $Command failed (exit code 7)*"
        $script:fixture.Calls.Count | Should -Be $Calls
        Should -Invoke Start-Process -Exactly 0
    }

    It 'does not echo malformed plan JSON or apply it' {
        $script:fixture.InvalidJson = $true
        { Invoke-TerraformPlanAndApply @script:parameters } | Should -Throw '*invalid plan JSON*'
        $script:fixture.Calls.Count | Should -Be 2
    }

    It 'does not invoke Terraform for WhatIf' {
        $null = Invoke-TerraformPlanAndApply @script:parameters -WhatIf
        $script:fixture.Calls.Count | Should -Be 0
    }

    It 'refuses to delete local state during workspace cleanup' {
        $path = Join-Path $TestDrive 'terraform.tfstate'
        'synthetic local state' | Set-Content -LiteralPath $path
        $hash = (Get-FileHash -LiteralPath $path).Hash
        { Clear-TerraformWorkspace -terraformModulePath $TestDrive } | Should -Throw '*must not delete state*'
        (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
    }
}
