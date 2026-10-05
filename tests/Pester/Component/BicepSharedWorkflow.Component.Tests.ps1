#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    Import-Module (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    . (Join-Path $script:repoRoot 'scripts' 'bicep-workflows' 'Discovery.ps1')
    . (Join-Path $script:repoRoot 'scripts' 'bicep-workflows' 'Validation.ps1')
    . (Join-Path $script:repoRoot 'scripts' 'bicep-workflows' 'Release.ps1')
    $script:subscription = '11111111-2222-4333-8444-555555555555'
    $script:secondSubscription = '99999999-2222-4333-8444-555555555555'
    $script:tenant = '11111111-2222-4333-8444-666666666666'
    $script:modulePath = 'avm/res/mock/widget'
    $script:savedEnvironment = @{}
    foreach ($name in @('GITHUB_STEP_SUMMARY', 'TEST_SUBSCRIPTION_IDS', 'VALIDATE_SUBSCRIPTION_ID')) {
        $script:savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, [NullString]::Value)
    }
    function Get-AzContext { [CmdletBinding()] param() throw 'Azure context inspection must be mocked.' }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
    foreach ($name in $script:savedEnvironment.Keys) {
        $value = $script:savedEnvironment[$name]
        [Environment]::SetEnvironmentVariable($name, $(if ($null -eq $value) { [NullString]::Value } else { $value }))
    }
}

Describe 'Component: Bicep shared workflow discovery and defaults' -Tag Component {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $folder = Join-Path $script:root $script:modulePath 'tests/e2e/defaults'
        $null = New-Item -ItemType Directory -Path $folder -Force
        [IO.File]::WriteAllText((Join-Path $script:root $script:modulePath 'main.bicep'), '')
        [IO.File]::WriteAllText((Join-Path $folder 'main.test.bicep'), '')
        Mock Invoke-AvmWorkflowProcess { throw 'Unexpected process invocation.' }
        Mock Invoke-AvmWorkflowGitRead {
            if ($Arguments[0] -eq 'rev-parse') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = 'a' * 40; StdErr = '' }
            }
            throw "Unexpected Git read: $($Arguments[0])"
        }
    }

    It 'preserves singleton arrays and deployment-ignore markers without suppressing PSRule' {
        [IO.File]::WriteAllText((Join-Path $script:root $script:modulePath 'tests/e2e/defaults/.e2eignore'), '')
        $files = Get-AvmWorkflowTestFiles -Root $script:root -ModulePath $script:modulePath
        $tests = ConvertFrom-Json -InputObject $files.moduleTestFilePaths -NoEnumerate
        ($tests -is [array]) | Should -BeTrue
        $tests.Count | Should -Be 1
        $tests[0].e2eIgnore | Should -BeTrue
        $tests[0].path | Should -BeExactly 'tests/e2e/defaults/main.test.bicep'
        (ConvertFrom-Json -InputObject $files.psRuleModuleTestFilePaths -NoEnumerate).Count | Should -Be 1
    }

    It 'returns genuine empty arrays when a module has no tests' {
        $empty = Join-Path $script:root 'avm/utl/mock/empty'
        $null = New-Item -ItemType Directory -Path $empty -Force
        $files = Get-AvmWorkflowTestFiles -Root $script:root -ModulePath 'avm/utl/mock/empty'
        $files.moduleTestFilePaths | Should -BeExactly '[]'
        $files.psRuleModuleTestFilePaths | Should -BeExactly '[]'
    }

    It 'reads false dispatch defaults and omits an unset custom location' {
        $yaml = @'
on:
  workflow_dispatch:
    inputs:
      staticValidation:
        default: true
      removeDeployment:
        default: false
      customLocation:
        type: string
'@
        [IO.File]::WriteAllText((Join-Path $script:root 'workflow.yml'), $yaml)
        $result = Get-AvmWorkflowInput -Root $script:root -WorkflowPath workflow.yml -EventName push | ConvertFrom-Json -AsHashtable
        $result.staticValidation | Should -BeExactly 'true'
        $result.removeDeployment | Should -BeExactly 'false'
        $result.ContainsKey('customLocation') | Should -BeFalse
    }

    It 'treats manual input as data and retains false values' {
        [IO.File]::WriteAllText((Join-Path $script:root 'workflow.yml'), '')
        $inputJson = '{"customLocation":"$(throw ''not code'')","removeDeployment":false,"empty":""}'
        $result = Get-AvmWorkflowInput -Root $script:root -WorkflowPath workflow.yml -EventName workflow_dispatch -EventInputs $inputJson |
            ConvertFrom-Json -AsHashtable
        $result.customLocation | Should -BeExactly '$(throw ''not code'')'
        $result.removeDeployment | Should -BeExactly 'false'
        $result.ContainsKey('empty') | Should -BeFalse
    }

    It 'normalizes changed children and excludes README and push-only metadata changes' {
        $changes = @("$script:modulePath/child/main.bicep", "$script:modulePath/README.md", "$script:modulePath/metadata.json")
        $matrix = Get-AvmWorkflowModuleMatrix -Root $script:root -ChangedFiles $changes -ExcludeMetadataChanges
        $matrix.include.Count | Should -Be 1
        $matrix.include[0].modulePath | Should -BeExactly $script:modulePath
        (Get-AvmWorkflowModuleMatrix -Root $script:root -ChangedFiles @("$script:modulePath/metadata.json") -ExcludeMetadataChanges).include.Count |
            Should -Be 0
        (Get-AvmWorkflowModuleMatrix -Root $script:root -ChangedFiles @("$script:modulePath/metadata.json")).include.Count |
            Should -Be 1
    }

    It 'rejects invalid manual selections (<Value>)' -ForEach @(
        @{ Value = 'avm/res/mock/widget,' }
        @{ Value = 'avm/res/mock/*' }
        @{ Value = 'avm/res/mock/widget/../other' }
        @{ Value = 'avm/res/mock/missing' }
        @{ Value = 'main.bicep' }
    ) {
        { Get-AvmWorkflowModuleMatrix -Root $script:root -ModulePaths $Value } | Should -Throw
    }

    It 'rejects traversal and workflow-output line injection' {
        { Resolve-AvmWorkflowPath -Root $script:root -RelativePath '../escape' } | Should -Throw
        { Write-AvmWorkflowOutput -Name safe -Value "a`ninjected=true" -FilePath (Join-Path $script:root 'output') } | Should -Throw
    }

    It 'accepts 256 modules and rejects a 257th before discovering tests' {
        $paths = @(for ($index = 0; $index -lt 257; $index++) {
                $relative = "avm/res/mock/module-$index"
                $folder = Join-Path $script:root $relative
                $null = New-Item -ItemType Directory -Path $folder -Force
                [IO.File]::WriteAllText((Join-Path $folder 'main.bicep'), '')
                $relative
            })
        (Get-AvmWorkflowModuleMatrix -Root $script:root -ModulePaths ($paths[0..255] -join ',')).include.Count | Should -Be 256
        { Get-AvmWorkflowModuleMatrix -Root $script:root -ModulePaths ($paths -join ',') } | Should -Throw '*256-job*'
    }

    It 'uses the visible static-only all-module fallback for a missing push base' {
        Mock Invoke-AvmWorkflowGitRead {
            [pscustomobject]@{ ExitCode = 0; StdOut = "$script:modulePath/main.bicep"; StdErr = '' }
        } -ParameterFilter { $Arguments[0] -eq 'ls-tree' }
        $output = Initialize-AvmWorkflowMatrix -Root $script:root -EventName push -TargetCommit ('a' * 40) -BaseCommit ('0' * 40)
        $output.includeAllVersionedModules | Should -BeExactly 'true'
        $output.hasModules | Should -BeExactly 'true'
        ($output.workflowInput | ConvertFrom-Json).deploymentValidation | Should -BeExactly 'false'
        $output.baseCommit | Should -BeNullOrEmpty
    }

    It 'fails a pull request with no base and invalid manual publication combinations' {
        { Initialize-AvmWorkflowMatrix -Root $script:root -EventName pull_request -TargetCommit ('a' * 40) } | Should -Throw '*base commit*'
        { Initialize-AvmWorkflowMatrix -Root $script:root -EventName workflow_dispatch -TargetCommit ('a' * 40) `
                -ModulePaths $script:modulePath -PublishOnly $true } | Should -Throw '*requires createReleaseTag*'
        { Initialize-AvmWorkflowMatrix -Root $script:root -EventName workflow_dispatch -TargetCommit ('a' * 40) `
                -ModulePaths $script:modulePath -CreateReleaseTag $true -StaticValidation $false } | Should -Throw '*requires staticValidation*'
    }

    It 'fetches a missing base once and uses the recovered commit for changed-file selection' {
        $script:hasBase = $false
        Mock Invoke-AvmWorkflowGitRead {
            [pscustomobject]@{ ExitCode = $(if ($script:hasBase) { 0 } else { 1 }); StdOut = ''; StdErr = '' }
        } -ParameterFilter { $Arguments[0] -eq 'cat-file' }
        Mock Invoke-AvmWorkflowGitRead {
            $script:hasBase = $true
            [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
        } -ParameterFilter { $Arguments[0] -eq 'fetch' }
        Mock Invoke-AvmWorkflowGitRead {
            [pscustomobject]@{ ExitCode = 0; StdOut = "$script:modulePath/main.bicep`n"; StdErr = '' }
        } -ParameterFilter { $Arguments[0] -eq 'diff' }
        $result = Initialize-AvmWorkflowMatrix -Root $script:root -EventName pull_request -TargetCommit ('a' * 40) -BaseCommit ('b' * 40)
        $result.baseCommit | Should -BeExactly ('b' * 40)
        $result.hasModules | Should -BeExactly 'true'
        $result.includeAllVersionedModules | Should -BeExactly 'false'
        Should -Invoke Invoke-AvmWorkflowGitRead -Exactly 1 -ParameterFilter {
            $Arguments[0] -eq 'fetch' -and $Arguments[-1] -ceq ('b' * 40) -and $Remote -and $AllowFailure
        }
    }

    It 'selects metadata-only <EventName> changes with deployment validation <Enabled>' -ForEach @(
        @{ EventName = 'pull_request'; Enabled = $true; Expected = 1 }
        @{ EventName = 'pull_request'; Enabled = $false; Expected = 1 }
        @{ EventName = 'push'; Enabled = $true; Expected = 0 }
    ) {
        Mock Invoke-AvmWorkflowGitRead {
            [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
        } -ParameterFilter { $Arguments[0] -eq 'cat-file' }
        Mock Invoke-AvmWorkflowGitRead {
            [pscustomobject]@{ ExitCode = 0; StdOut = "$script:modulePath/metadata.json`n"; StdErr = '' }
        } -ParameterFilter { $Arguments[0] -eq 'diff' }
        $result = Initialize-AvmWorkflowMatrix -Root $script:root -EventName $EventName -TargetCommit ('a' * 40) `
            -BaseCommit ('b' * 40) -DeploymentValidation $Enabled
        ($result.moduleMatrix | ConvertFrom-Json).include.Count | Should -Be $Expected
        ($result.workflowInput | ConvertFrom-Json).deploymentValidation | Should -BeExactly $Enabled.ToString().ToLowerInvariant()
    }

    It 'fails unavailable pull request bases and returns an empty matrix for no relevant changes' {
        Mock Invoke-AvmWorkflowGitRead {
            [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'fixture unavailable' }
        } -ParameterFilter { $Arguments[0] -in @('cat-file', 'fetch') }
        { Initialize-AvmWorkflowMatrix -Root $script:root -EventName pull_request -TargetCommit ('a' * 40) -BaseCommit ('b' * 40) } |
            Should -Throw '*base commit is unavailable*'
        Mock Invoke-AvmWorkflowGitRead {
            [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
        } -ParameterFilter { $Arguments[0] -in @('cat-file', 'diff') }
        $result = Initialize-AvmWorkflowMatrix -Root $script:root -EventName push -TargetCommit ('a' * 40) -BaseCommit ('b' * 40)
        $result.hasModules | Should -BeExactly 'false'
        $result.moduleMatrix | Should -BeExactly '{"include":[]}'
    }

    It 'rejects an invalid target or a checkout different from the selected target' {
        { Initialize-AvmWorkflowMatrix -Root $script:root -EventName push -TargetCommit '--help' } | Should -Throw '*full SHA-1*'
        { Initialize-AvmWorkflowMatrix -Root $script:root -EventName workflow_dispatch -TargetCommit ('b' * 40) -ModulePaths $script:modulePath } |
            Should -Throw '*match targetCommit exactly*'
    }
}

Describe 'Component: Bicep shared workflow target and authentication boundaries' -Tag Component {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $folder = Join-Path $script:root $script:modulePath 'tests/e2e/defaults'
        $null = New-Item -ItemType Directory -Path $folder -Force
        [IO.File]::WriteAllText((Join-Path $folder 'main.test.bicep'), '')
        [IO.File]::WriteAllText((Join-Path $script:root '.oidc-exceptions.json'), '[]')
        $script:pool = ConvertTo-Json -Compress -InputObject @(
            @{ id = $script:subscription; name = 'First' }
            @{ id = $script:secondSubscription; name = 'Second' }
        )
        $entry = @(Get-AvmWorkflowSubscriptions -PoolJson $script:pool)[0]
        $script:case = @{ path = 'tests/e2e/defaults/main.test.bicep'; name = 'defaults'; e2eIgnore = $false; subscriptionIndex = 0; subscriptionKey = $entry.key }
        Mock Get-AvmTool { [pscustomobject]@{ Status = 'installed'; Path = 'fixture-bicep' } }
        Mock Invoke-AvmWorkflowProcess {
            [pscustomobject]@{ ExitCode = 0; StdOut = '{"$schema":"https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#","resources":[]}'; StdErr = '' }
        }
    }

    It 'keeps ignored entries in round robin without sharing their locks or exposing subscription IDs' {
        $ignored = @{ path = 'tests/e2e/ignored/main.test.bicep'; name = 'ignored'; e2eIgnore = $true }
        $args = @{ Root = $script:root; ModulePath = $script:modulePath; TestFiles = @($ignored, $script:case, $script:case); PoolJson = $script:pool; RandomSeed = 9 }
        $first = Get-AvmWorkflowDeploymentMatrix @args
        $second = Get-AvmWorkflowDeploymentMatrix @args
        $matrix = ConvertFrom-Json -InputObject $first.deploymentMatrix
        $matrix[0].subscriptionIndex | Should -BeNullOrEmpty
        $matrix[0].concurrencyGroup | Should -Not -Be (ConvertFrom-Json $second.deploymentMatrix)[0].concurrencyGroup
        $matrix[1].subscriptionIndex | Should -Not -Be $matrix[2].subscriptionIndex
        $matrix[1].subscriptionName | Should -Match '^Configured subscription'
        $first.deploymentMatrix | Should -Not -Match $script:subscription
        $first.deploymentMatrix | Should -Not -Match $script:secondSubscription
        $matrix[1].concurrencyGroup | Should -Be (ConvertFrom-Json $second.deploymentMatrix)[1].concurrencyGroup
    }

    It 'needs no pool, compiler or setup when every case is ignored' {
        $script:case.e2eIgnore = $true
        $result = Get-AvmWorkflowDeploymentMatrix -Root $script:root -ModulePath $script:modulePath -TestFiles @($script:case)
        $result.sharedScope | Should -BeExactly 'false'
        Should -Invoke Get-AvmTool -Times 0 -Exactly
        Should -Invoke Invoke-AvmWorkflowProcess -Times 0 -Exactly
    }

    It 'detects tenant, management-group, linked and expression-based nested templates' {
        foreach ($nested in @(
                @{ template = @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-08-01/tenantDeploymentTemplate.json#' } }
                @{ template = @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-08-01/managementGroupDeploymentTemplate.json#' } }
                @{ templateLink = @{ uri = 'https://example.invalid/template.json' } }
                @{ template = '[variables(''nestedTemplate'')]' }
            )) {
            Test-AvmWorkflowSharedScope -Template @{ resources = @{ nested = @{ type = 'Microsoft.Resources/deployments'; properties = $nested } } } |
                Should -BeTrue
        }
        Test-AvmWorkflowSharedScope -Template @{ resources = @() } | Should -BeFalse
    }

    It 'rejects malformed preferred pools instead of falling back (<Value>)' -ForEach @(
        @{ Value = ' ' }
        @{ Value = '[]' }
        @{ Value = '{}' }
        @{ Value = '[{"id":"bad","name":"fixture"}]' }
        @{ Value = '[{"id":"11111111-2222-4333-8444-555555555555","name":"\n"}]' }
    ) {
        { Get-AvmWorkflowSubscriptions -PoolJson $Value -FallbackSubscriptionId $script:subscription } | Should -Throw
    }

    It 'revalidates the original pool index and digest before authentication' {
        $auth = Get-AvmWorkflowAuthentication -Root $script:root -ModulePath $script:modulePath -TestCase $script:case `
            -PoolJson $script:pool -ClientId fixture-client -TenantId $script:tenant
        $auth.useSecret | Should -BeExactly 'false'
        $auth.subscriptionId | Should -BeExactly $script:subscription
        $script:case.subscriptionIndex = 1
        { Get-AvmWorkflowAuthentication -Root $script:root -ModulePath $script:modulePath -TestCase $script:case `
                -PoolJson $script:pool -ClientId fixture-client -TenantId $script:tenant } | Should -Throw '*digest*'
    }

    It 'scopes secret authentication to the declared exception and replaces only the selected subscription' {
        [IO.File]::WriteAllText((Join-Path $script:root '.oidc-exceptions.json'), '["avm/res/mock/widget"]')
        $credentials = ConvertTo-Json -Compress -InputObject @{ clientId = 'fixture'; clientSecret = 'not-a-real-secret'; tenantId = $script:tenant; subscriptionId = $script:secondSubscription }
        $auth = Get-AvmWorkflowAuthentication -Root $script:root -ModulePath $script:modulePath -TestCase $script:case `
            -PoolJson $script:pool -TenantId $script:tenant -Credentials $credentials
        $auth.useSecret | Should -BeExactly 'true'
        ($auth.credentials | ConvertFrom-Json).subscriptionId | Should -BeExactly $script:subscription
        ($credentials | ConvertFrom-Json).subscriptionId | Should -BeExactly $script:secondSubscription
        { Get-AvmWorkflowAuthentication -Root $script:root -ModulePath $script:modulePath -TestCase $script:case `
                -PoolJson $script:pool -TenantId $script:secondSubscription -Credentials $credentials } | Should -Throw '*tenantId does not match*'
    }

    It 'never falls back to secret authentication for an ordinary module' {
        { Get-AvmWorkflowAuthentication -Root $script:root -ModulePath $script:modulePath -TestCase $script:case `
                -PoolJson $script:pool -Credentials '{"clientId":"fixture","clientSecret":"not-real","tenantId":"fixture"}' } |
            Should -Throw '*do not fall back*'
    }

    It 'rejects partial selection and a reordered pool before authentication' {
        $parameters = @{ Root = $script:root; ModulePath = $script:modulePath; TestCase = $script:case; PoolJson = $script:pool; ClientId = 'fixture'; TenantId = $script:tenant }
        $script:case.Remove('subscriptionIndex')
        { Get-AvmWorkflowAuthentication @parameters } | Should -Throw '*index and digest*'
        $script:case.subscriptionIndex = 0
        $parameters.PoolJson = ConvertTo-Json -Compress -InputObject @(
            @{ id = $script:secondSubscription; name = 'Second' }
            @{ id = $script:subscription; name = 'First' }
        )
        { Get-AvmWorkflowAuthentication @parameters } | Should -Throw '*index and digest*'
    }

    It 'rejects malformed exception configuration (<Value>)' -ForEach @(
        @{ Value = '{}' }
        @{ Value = '[1]' }
        @{ Value = '["avm/res/mock/widget","avm/res/mock/widget"]' }
        @{ Value = '["avm/res/mock/widget/*"]' }
    ) {
        [IO.File]::WriteAllText((Join-Path $script:root '.oidc-exceptions.json'), $Value)
        { Get-AvmWorkflowAuthentication -Root $script:root -ModulePath $script:modulePath -TestCase $script:case `
                -PoolJson $script:pool -ClientId fixture -TenantId $script:tenant } | Should -Throw '*oidc-exceptions.json*'
    }

    It 'fails scope selection rather than inferring a safe scope after compiler failure' {
        Mock Invoke-AvmWorkflowProcess { throw 'fixture compiler failure' }
        { Get-AvmWorkflowDeploymentMatrix -Root $script:root -ModulePath $script:modulePath -TestFiles @($script:case) -PoolJson $script:pool } |
            Should -Throw '*compiler failure*'
    }

    It 'verifies the actual selected subscription and resolves tenant domains without accepting a mismatched GUID' {
        Mock Get-AzContext {
            [pscustomobject]@{ Subscription = @{ Id = $script:subscription }; Tenant = @{ Id = $script:tenant } }
        }
        Confirm-AvmWorkflowAzureContext -SubscriptionId $script:subscription -TenantId 'fixture.onmicrosoft.com' | Should -BeExactly $script:tenant
        { Confirm-AvmWorkflowAzureContext -SubscriptionId $script:secondSubscription -TenantId $script:tenant } | Should -Throw '*does not match*'
        { Confirm-AvmWorkflowAzureContext -SubscriptionId $script:subscription -TenantId $script:secondSubscription } | Should -Throw '*does not match*'
    }
}

Describe 'Component: Bicep shared workflow native phase forwarding' -Tag Component {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $folder = Join-Path $script:root $script:modulePath 'tests/e2e/defaults'
        $null = New-Item -ItemType Directory -Path $folder -Force
        [IO.File]::WriteAllText((Join-Path $folder 'main.test.bicep'), '')
        $script:output = Join-Path $script:root 'results'
        $script:state = Join-Path $script:root 'state.json'
        Mock Invoke-AvmTestE2e { [pscustomobject]@{ Status = 'pass'; RunsTotal = 1; RunsSkipped = 0; Issues = @() } }
        Mock Invoke-AvmTestUnit { [pscustomobject]@{ Status = 'pass'; RunsTotal = 1; RunsSkipped = 0; RunsFiltered = 0; Issues = @() } }
        Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Status = 'pass'; TestsSelected = 1; BaselinesExecuted = 1; Issues = @() } }
        Mock Invoke-AvmTestCleanup { [pscustomobject]@{ Status = 'pass' } }
    }

    It 'uses one packaged compliance and authored-unit route without custom compliance paths' {
        Invoke-AvmWorkflowStaticValidation -Root $script:root -ModulePath $script:modulePath -ResultDirectory $script:output
        Should -Invoke Invoke-AvmTestUnit -Exactly 1 -ParameterFilter {
            $IncludeCompliance -and $Recurse -and $Ecosystem -eq 'bicep' -and -not $CompliancePath -and $SkipModuleVersionCheck
        }
    }

    It 'forwards only one policy example/baseline and rejects empty evaluations' {
        Mock Get-AvmWorkflowSubscriptions { [pscustomobject]@{ id = $script:subscription } }
        Invoke-AvmWorkflowPolicyValidation -Root $script:root -ModulePath $script:modulePath `
            -Example 'tests/e2e/defaults/main.test.bicep' -Baseline Azure.Default -ResultDirectory $script:output
        Should -Invoke Invoke-AvmCheckPolicy -Exactly 1 -ParameterFilter {
            $Example.Count -eq 1 -and $Example[0] -ceq 'tests/e2e/defaults/main.test.bicep' -and $Baseline[0] -ceq 'Azure.Default'
        }
        Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Status = 'pass'; TestsSelected = 1; BaselinesExecuted = 0; Issues = @() } }
        { Invoke-AvmWorkflowPolicyValidation -Root $script:root -ModulePath $script:modulePath `
                -Example 'tests/e2e/defaults/main.test.bicep' -Baseline Azure.Default -ResultDirectory $script:output } |
            Should -Throw '*exactly*'
    }

    It 'separates deployment inputs from state-selected completion and keeps metadata location fixed' {
        $parameters = @{ Root = $script:root; ModulePath = $script:modulePath; SubscriptionId = $script:subscription; TenantId = $script:tenant; StatePath = $script:state; ResultDirectory = $script:output }
        Invoke-AvmWorkflowE2e @parameters -Phase Deploy -Example 'tests/e2e/defaults/main.test.bicep' -CustomLocation northeurope -RemoveDeployment $false -Confirm:$false
        Invoke-AvmWorkflowE2e @parameters -Phase Complete -RemoveDeployment $false -Confirm:$false
        Should -Invoke Invoke-AvmTestE2e -Exactly 1 -ParameterFilter {
            $Phase -eq 'Deploy' -and $UseCiInputs -and $Location -eq 'WestEurope' -and $ResourceLocation -eq 'northeurope' -and $KeepResources
        }
        Should -Invoke Invoke-AvmTestE2e -Exactly 1 -ParameterFilter {
            $Phase -eq 'Complete' -and -not $UseCiInputs -and -not $Example -and -not $ManagementGroupId -and -not $ResourceLocation -and $KeepResources
        }
    }

    It 'does not run native mutations under WhatIf or on absent recovery state' {
        Invoke-AvmWorkflowE2e -Root $script:root -ModulePath $script:modulePath -Phase Deploy `
            -SubscriptionId $script:subscription -TenantId $script:tenant -Example 'tests/e2e/defaults/main.test.bicep' `
            -StatePath $script:state -ResultDirectory $script:output -WhatIf
        Invoke-AvmWorkflowRecovery -StatePath $script:state -SubscriptionId $script:subscription -TenantId $script:tenant -Confirm:$false
        Should -Invoke Invoke-AvmTestE2e -Exactly 0
        Should -Invoke Invoke-AvmTestCleanup -Exactly 0
    }

    It 'uses state-only recovery without rerunning deployment or authored hooks' {
        [IO.File]::WriteAllText($script:state, '{}')
        Invoke-AvmWorkflowRecovery -StatePath $script:state -SubscriptionId $script:subscription -TenantId $script:tenant -Confirm:$false
        Should -Invoke Invoke-AvmTestCleanup -Exactly 1 -ParameterFilter { $SubscriptionId -eq $script:subscription -and $TenantId -eq $script:tenant }
        Should -Invoke Invoke-AvmTestE2e -Exactly 0
    }

    It 'retains required failures and advisory warning severity without raw package output' {
        $result = [pscustomobject]@{
            Status = 'pass'; TestsSelected = 1; BaselinesExecuted = 1
            Issues = @([pscustomobject]@{ Code = 'PolicyWarning'; Message = 'Fixture warning'; Severity = 'Warning' })
            RawResponse = 'not suitable for artifacts'
        }
        Write-AvmWorkflowResult -Name policy -Result $result -Directory $script:output
        $record = Get-Content -LiteralPath (Join-Path $script:output 'policy.json') -Raw | ConvertFrom-Json
        $record.Status | Should -BeExactly 'pass'
        $record.Issues[0].Severity | Should -BeExactly 'Warning'
        $record.PSObject.Properties.Name | Should -Not -Contain RawResponse
        $result.Status = 'fail'
        { Write-AvmWorkflowResult -Name policy -Result $result -Directory $script:output } | Should -Throw '*did not pass*'
        (Get-Content -LiteralPath (Join-Path $script:output 'policy.json') -Raw | ConvertFrom-Json).Status | Should -BeExactly 'fail'
    }

    It 'cannot publish a passing artifact for an empty, skipped, filtered or malformed package result (<Kind>)' -ForEach @(
        @{ Kind = 'empty'; Result = @{ Status = 'pass'; RunsTotal = 0; RunsSkipped = 0; RunsFiltered = 0 } }
        @{ Kind = 'skipped'; Result = @{ Status = 'skipped'; RunsTotal = 0; RunsSkipped = 1; RunsFiltered = 0 } }
        @{ Kind = 'filtered'; Result = @{ Status = 'pass'; RunsTotal = 1; RunsSkipped = 0; RunsFiltered = 1 } }
        @{ Kind = 'missing count'; Result = @{ Status = 'pass'; RunsTotal = 1; RunsSkipped = 0 } }
        @{ Kind = 'string count'; Result = @{ Status = 'pass'; RunsTotal = '1'; RunsSkipped = 0; RunsFiltered = 0 } }
        @{ Kind = 'unknown status'; Result = @{ Status = 'unknown' } }
        @{ Kind = 'missing status'; Result = @{} }
    ) {
        { Write-AvmWorkflowResult -Name static -Result ([pscustomobject]$Result) -Directory $script:output } | Should -Throw
        $record = Get-Content -LiteralPath (Join-Path $script:output 'static.json') -Raw | ConvertFrom-Json
        $record.Status | Should -Not -Be 'pass'
    }
}
