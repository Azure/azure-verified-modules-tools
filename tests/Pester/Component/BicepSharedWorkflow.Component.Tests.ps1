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
    $script:client = '10000000-0000-4000-8000-000000000006'
    $script:secondClient = '10000000-0000-4000-8000-000000000016'
    $script:modulePath = 'avm/res/mock/widget'
    $script:savedEnvironment = @{}
    foreach ($name in @('GITHUB_STEP_SUMMARY', 'TEST_SUBSCRIPTION_IDS', 'VALIDATE_SUBSCRIPTION_ID', 'VALIDATE_CLIENT_ID', 'AZURE_CREDENTIALS')) {
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
            if ($Arguments[0] -eq 'rev-list') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = ('a' * 40), ('b' * 40), ('c' * 40) -join ' '; StdErr = '' }
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

    It 'fails a pull request with no head and invalid manual publication combinations' {
        { Initialize-AvmWorkflowMatrix -Root $script:root -EventName pull_request -TargetCommit ('a' * 40) } | Should -Throw '*pull request head*'
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
        $result = Initialize-AvmWorkflowMatrix -Root $script:root -EventName pull_request -TargetCommit ('a' * 40) `
            -BaseCommit ('d' * 40) -PullRequestHeadCommit ('c' * 40)
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
            -BaseCommit ('b' * 40) -PullRequestHeadCommit ('c' * 40) -DeploymentValidation $Enabled
        ($result.moduleMatrix | ConvertFrom-Json).include.Count | Should -Be $Expected
        ($result.workflowInput | ConvertFrom-Json).deploymentValidation | Should -BeExactly $Enabled.ToString().ToLowerInvariant()
    }

    It 'fails unavailable pull request bases and returns an empty matrix for no relevant changes' {
        Mock Invoke-AvmWorkflowGitRead {
            [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'fixture unavailable' }
        } -ParameterFilter { $Arguments[0] -in @('cat-file', 'fetch') }
        { Initialize-AvmWorkflowMatrix -Root $script:root -EventName pull_request -TargetCommit ('a' * 40) `
                -BaseCommit ('b' * 40) -PullRequestHeadCommit ('c' * 40) } |
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
        [IO.File]::WriteAllText((Join-Path $script:root 'bicepconfig.json'), '{}')
        [IO.File]::WriteAllText((Join-Path $script:root '.reserved-test-subscriptions.json'), '{}')
        [IO.File]::WriteAllText((Join-Path $script:root $script:modulePath 'main.bicep'), '')
        [IO.File]::WriteAllText((Join-Path $folder 'main.test.bicep'), '')
        [IO.File]::WriteAllText((Join-Path $script:root '.oidc-exceptions.json'), '[]')
        $script:pool = ConvertTo-Json -Compress -InputObject @(
            @{ id = $script:subscription; name = 'First' }
            @{ id = $script:secondSubscription; name = 'Second' }
        )
        $entry = Select-AvmTestSubscription -Path $script:root -ModulePath $script:modulePath `
            -Example 'tests/e2e/defaults/main.test.bicep' -TestSubscriptionIds $script:pool -RandomSeed 9 -SkipModuleVersionCheck
        $script:selectedSubscription = $entry.SubscriptionId
        $script:selectedIndex = $entry.Index
        $script:case = @{
            path = 'tests/e2e/defaults/main.test.bicep'; name = 'defaults'; e2eIgnore = $false
            subscriptionIndex = $entry.Index; subscriptionKey = $entry.Key
            selectionSeed = 9; caseIndex = 0; subscriptionModulePath = $entry.ModulePath
        }
        $script:mapping = [ordered]@{
            $script:modulePath = $script:client
            'avm/ptn/lz/sub-vending' = $script:secondClient
        }
        $script:mappingJson = ConvertTo-AvmBicepModuleClientIdJson -ClientIds $script:mapping
        $script:case.identityKey = (Get-AvmWorkflowModuleIdentity -Root $script:root -ModulePath $script:modulePath `
                -ModuleClientIds $script:mappingJson -TenantId $script:tenant).identityKey
        Mock Get-AvmTool { [pscustomobject]@{ Status = 'installed'; Path = 'fixture-bicep' } }
        Mock Invoke-AvmWorkflowProcess {
            [pscustomobject]@{ ExitCode = 0; StdOut = '{"$schema":"https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#","resources":[]}'; StdErr = '' }
        }
    }

    It 'keeps ignored entries in round robin without sharing their locks or exposing subscription IDs' {
        $ignored = @{ path = 'tests/e2e/ignored/main.test.bicep'; name = 'ignored'; e2eIgnore = $true }
        $args = @{
            Root = $script:root; ModulePath = $script:modulePath; TestFiles = @($ignored, $script:case, $script:case)
            PoolJson = $script:pool; RandomSeed = 9; ModuleClientIds = $script:mappingJson; TenantId = $script:tenant
        }
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
        $matrix[0].identityKey | Should -BeNullOrEmpty
        $matrix[1].identityKey | Should -BeExactly $script:case.identityKey
        $matrix[2].identityKey | Should -BeExactly $matrix[1].identityKey
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
        { Select-AvmWorkflowSubscription -Root $script:root -ModulePath $script:modulePath -Example $script:case.path `
                -PoolJson $Value -FallbackSubscriptionId $script:subscription } | Should -Throw
    }

    It 'needs no mapping, tenant, subscription pool or compiler for an empty selection' {
        $matrix = Get-AvmWorkflowDeploymentMatrix -Root $script:root -ModulePath $script:modulePath -TestFiles @()
        $matrix.deploymentMatrix | Should -BeExactly '[]'
        $matrix.sharedScope | Should -BeExactly 'false'
        Should -Invoke Get-AvmTool -Exactly 0
        Should -Invoke Invoke-AvmWorkflowProcess -Exactly 0
    }

    It 'revalidates the original pool index and digest before authentication' {
        $auth = Get-AvmWorkflowAuthentication -Root $script:root -ModulePath $script:modulePath -TestCase $script:case `
            -PoolJson $script:pool -ModuleClientIds $script:mappingJson -TenantId $script:tenant
        $auth.clientId | Should -BeExactly $script:client
        $auth.tenantId | Should -BeExactly $script:tenant
        $auth.subscriptionId | Should -BeExactly $script:selectedSubscription
        $script:case.subscriptionIndex = ($script:selectedIndex + 1) % 2
        { Get-AvmWorkflowAuthentication -Root $script:root -ModulePath $script:modulePath -TestCase $script:case `
                -PoolJson $script:pool -ModuleClientIds $script:mappingJson -TenantId $script:tenant } | Should -Throw '*digest*'
    }

    It 'ignores legacy exception and shared-client settings rather than overriding the mapped identity' {
        [IO.File]::WriteAllText((Join-Path $script:root '.oidc-exceptions.json'), 'not consumed by the new workflow')
        $env:VALIDATE_CLIENT_ID = $script:secondClient
        $env:AZURE_CREDENTIALS = '{"clientId":"legacy-client","clientSecret":"fixture-only","tenantId":"legacy-tenant"}'
        $auth = Get-AvmWorkflowAuthentication -Root $script:root -ModulePath $script:modulePath -TestCase $script:case `
            -PoolJson $script:pool -TenantId $script:tenant -ModuleClientIds $script:mappingJson
        $auth.clientId | Should -BeExactly $script:client
        @($auth.Keys | Sort-Object) | Should -Be @('clientId', 'example', 'modulePath', 'subscriptionId', 'tenantId')
    }

    It 'fails missing mapping even when legacy identity settings exist' {
        $env:VALIDATE_CLIENT_ID = $script:secondClient
        $env:AZURE_CREDENTIALS = '{"clientId":"legacy-client","clientSecret":"fixture-only","tenantId":"legacy-tenant"}'
        { Get-AvmWorkflowAuthentication -Root $script:root -ModulePath $script:modulePath -TestCase $script:case `
                -PoolJson $script:pool -TenantId $script:tenant } | Should -Throw '*VALIDATE_MODULE_CLIENT_IDS*'
    }

    It 'rejects partial selection and a reordered pool before authentication' {
        $parameters = @{
            Root = $script:root; ModulePath = $script:modulePath; TestCase = $script:case
            PoolJson = $script:pool; ModuleClientIds = $script:mappingJson; TenantId = $script:tenant
        }
        $script:case.Remove('subscriptionIndex')
        { Get-AvmWorkflowAuthentication @parameters } | Should -Throw '*index and digest*'
        $script:case.subscriptionIndex = $script:selectedIndex
        $parameters.PoolJson = ConvertTo-Json -Compress -InputObject @(
            @{ id = $script:secondSubscription; name = 'Second' }
            @{ id = $script:subscription; name = 'First' }
        )
        { Get-AvmWorkflowAuthentication @parameters } | Should -Throw '*index and digest*'
    }

    It 'rejects missing, malformed and ambiguous mappings (<Value>)' -ForEach @(
        @{ Value = '' }
        @{ Value = ' ' }
        @{ Value = 'null' }
        @{ Value = '{}' }
        @{ Value = '[]' }
        @{ Value = '{"avm/res/mock/widget":null}' }
        @{ Value = '{"avm/res/mock/widget":{"clientId":"10000000-0000-4000-8000-000000000006"}}' }
        @{ Value = '{"avm/res/mock/widget":"not-a-guid"}' }
        @{ Value = '{"avm/res/mock/widget":"00000000-0000-0000-0000-000000000000"}' }
        @{ Value = '{"avm/res/mock/widget":"10000000-0000-4000-8000-000000000006","avm/res/mock/widget":"10000000-0000-4000-8000-000000000016"}' }
        @{ Value = '{"avm/res/mock/widget":"10000000-0000-4000-8000-000000000006","avm/res/mock/Widget":"10000000-0000-4000-8000-000000000016"}' }
        @{ Value = '{"avm/res/mock/widget":"10000000-0000-4000-8000-000000000006","avm/ptn/lz/sub-vending":"10000000-0000-4000-8000-000000000006"}' }
        @{ Value = '{"avm/res/mock/widget/child":"10000000-0000-4000-8000-000000000006"}' }
        @{ Value = '{"avm/invalid/mock/widget":"10000000-0000-4000-8000-000000000006"}' }
        @{ Value = '{"avm/res/mock/*":"10000000-0000-4000-8000-000000000006"}' }
        @{ Value = '{"avm\\res\\mock\\widget":"10000000-0000-4000-8000-000000000006"}' }
    ) {
        { Get-AvmWorkflowAuthentication -Root $script:root -ModulePath $script:modulePath -TestCase $script:case `
                -PoolJson $script:pool -ModuleClientIds $Value -TenantId $script:tenant } | Should -Throw '*VALIDATE_MODULE_CLIENT_IDS*'
    }

    It 'uses the published root entry for <ModulePath>' -ForEach @(
        @{ ModulePath = 'avm/res/storage/storage-account'; ModuleRoot = 'avm/res/storage/storage-account' }
        @{ ModulePath = 'avm/res/storage/storage-account/blob-service'; ModuleRoot = 'avm/res/storage/storage-account' }
        @{ ModulePath = 'avm/res/storage/storage-account/blob-service/container'; ModuleRoot = 'avm/res/storage/storage-account' }
        @{ ModulePath = 'avm\res\storage\storage-account\blob-service'; ModuleRoot = 'avm/res/storage/storage-account' }
        @{ ModulePath = 'avm/ptn/lz/sub-vending/sub-scope'; ModuleRoot = 'avm/ptn/lz/sub-vending' }
        @{ ModulePath = 'avm/utl/types/avm-common-types'; ModuleRoot = 'avm/utl/types/avm-common-types' }
    ) {
        $null = New-Item -ItemType Directory -Path (Join-Path $script:root ($ModulePath.Replace('\', '/'))) -Force
        $mapping = [ordered]@{ $ModuleRoot = $script:client; 'avm/res/fabric/capacity' = $script:secondClient }
        $json = ConvertTo-AvmBicepModuleClientIdJson -ClientIds $mapping
        $identity = Get-AvmWorkflowModuleIdentity -Root $script:root -ModulePath $ModulePath -ModuleClientIds $json -TenantId $script:tenant
        $identity.moduleRoot | Should -BeExactly $ModuleRoot
        $identity.clientId | Should -BeExactly $script:client
        $identity.tenantId | Should -BeExactly $script:tenant
        $identity.identityKey | Should -Match '^[0-9a-f]{64}$'
    }

    It 'rejects invalid paths without prefix matching or normalizing away a boundary (<ModulePath>)' -ForEach @(
        @{ ModulePath = 'avm/res/mock/widget-extra' }
        @{ ModulePath = 'avm/res/mock/Widget' }
        @{ ModulePath = 'avm/res/mock/widget/../widget' }
        @{ ModulePath = 'avm/res/mock/widget/./child' }
        @{ ModulePath = 'avm/res/mock/widget//child' }
        @{ ModulePath = '../escape' }
        @{ ModulePath = 'avm/res/mock/*' }
    ) {
        $null = New-Item -ItemType Directory -Path (Join-Path $script:root 'avm/res/mock/widget-extra') -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $script:root $script:modulePath 'child') -Force
        { Get-AvmWorkflowModuleIdentity -Root $script:root -ModulePath $ModulePath `
                -ModuleClientIds $script:mappingJson -TenantId $script:tenant } | Should -Throw
    }

    It 'rejects a missing or invalid published tenant (<Tenant>)' -ForEach @(
        @{ Tenant = '' }
        @{ Tenant = 'fixture.onmicrosoft.com' }
        @{ Tenant = '00000000-0000-0000-0000-000000000000' }
        @{ Tenant = 'not-a-guid' }
    ) {
        { Get-AvmWorkflowModuleIdentity -Root $script:root -ModulePath $script:modulePath `
                -ModuleClientIds $script:mappingJson -TenantId $Tenant } | Should -Throw '*VALIDATE_TENANT_ID*'
    }

    It 'fails selection drift instead of switching identity (<Change>)' -ForEach @(
        @{ Change = 'client' }
        @{ Change = 'tenant' }
        @{ Change = 'module' }
        @{ Change = 'missing binding' }
    ) {
        $parameters = @{
            Root = $script:root; ModulePath = $script:modulePath; TestCase = $script:case
            PoolJson = $script:pool; ModuleClientIds = $script:mappingJson; TenantId = $script:tenant
        }
        switch ($Change) {
            'client' {
                $script:mapping[$script:modulePath] = '10000000-0000-4000-8000-000000000026'
                $parameters.ModuleClientIds = ConvertTo-AvmBicepModuleClientIdJson -ClientIds $script:mapping
            }
            'tenant' { $parameters.TenantId = $script:secondSubscription }
            'module' {
                $parameters.ModulePath = 'avm/ptn/lz/sub-vending'
                $null = New-Item -ItemType Directory -Path (Join-Path $script:root $parameters.ModulePath) -Force
            }
            'missing binding' { $script:case.Remove('identityKey') }
        }
        { Get-AvmWorkflowAuthentication @parameters } | Should -Throw '*selected module identity*'
    }

    It 'fails scope selection rather than inferring a safe scope after compiler failure' {
        Mock Invoke-AvmWorkflowProcess { throw 'fixture compiler failure' }
        { Get-AvmWorkflowDeploymentMatrix -Root $script:root -ModulePath $script:modulePath -TestFiles @($script:case) `
                -PoolJson $script:pool -ModuleClientIds $script:mappingJson -TenantId $script:tenant } |
            Should -Throw '*compiler failure*'
    }

    It 'prepares a missing compiler only after native target selection using the caller module path' {
        $script:compilerReady = $false
        $script:compilerModulePath = Resolve-AvmWorkflowPath -Root $script:root -RelativePath $script:modulePath
        Mock Get-AvmTool {
            [pscustomobject]@{ Status = $(if ($script:compilerReady) { 'installed' } else { 'not-installed' }); Path = 'fixture-bicep' }
        }
        Mock Install-AvmTool { $script:compilerReady = $true }

        $result = Get-AvmWorkflowDeploymentMatrix -Root $script:root -ModulePath $script:modulePath -TestFiles @($script:case) `
            -PoolJson $script:pool -ModuleClientIds $script:mappingJson -TenantId $script:tenant
        $result.deploymentMatrix | Should -Not -BeNullOrEmpty
        Should -Invoke Install-AvmTool -Exactly 1 -ParameterFilter {
            $Name -eq 'bicep' -and $Path -ceq $script:compilerModulePath -and $SkipModuleVersionCheck
        }
        Should -Invoke Get-AvmTool -Exactly 2 -ParameterFilter {
            $Name -eq 'bicep' -and $Path -ceq $script:compilerModulePath -and $SkipModuleVersionCheck
        }
    }

    It 'propagates failed compiler preparation instead of emitting a usable deployment matrix' {
        Mock Get-AvmTool { [pscustomobject]@{ Status = 'not-installed'; Path = '' } }
        Mock Install-AvmTool { throw [IO.IOException]::new('Managed compiler preparation failed.') }
        { Get-AvmWorkflowDeploymentMatrix -Root $script:root -ModulePath $script:modulePath -TestFiles @($script:case) `
                -PoolJson $script:pool -ModuleClientIds $script:mappingJson -TenantId $script:tenant } |
            Should -Throw '*Managed compiler preparation failed*'
        Should -Invoke Install-AvmTool -Exactly 1
        Should -Invoke Invoke-AvmWorkflowProcess -Exactly 0
    }

    It 'rejects an incomplete compiler install without replaying preparation' {
        Mock Get-AvmTool { [pscustomobject]@{ Status = 'not-installed'; Path = '' } }
        Mock Install-AvmTool {}
        { Get-AvmWorkflowDeploymentMatrix -Root $script:root -ModulePath $script:modulePath -TestFiles @($script:case) `
                -PoolJson $script:pool -ModuleClientIds $script:mappingJson -TenantId $script:tenant } |
            Should -Throw '*compiler is not installed*'
        Should -Invoke Install-AvmTool -Exactly 1
        Should -Invoke Get-AvmTool -Exactly 2
        Should -Invoke Invoke-AvmWorkflowProcess -Exactly 0
    }

    It 'uses the real native selector to exclude reserved entries while preserving original pool positions' {
        $pool = ConvertTo-Json -Compress -InputObject @(
            @{ id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; name = 'Reserved'; tag = 'Azure Local' }
            @{ id = $script:subscription; name = 'First' }
            @{ id = $script:secondSubscription; name = 'Second'; tag = 'General' }
        )
        $result = Get-AvmWorkflowDeploymentMatrix -Root $script:root -ModulePath $script:modulePath `
            -TestFiles @($script:case, $script:case) -PoolJson $pool -RandomSeed 21 `
            -ModuleClientIds $script:mappingJson -TenantId $script:tenant
        $matrix = ConvertFrom-Json -InputObject $result.deploymentMatrix -AsHashtable
        @($matrix.subscriptionIndex | Sort-Object) | Should -Be @(1, 2)
        $matrix[0].selectionSeed | Should -Be 21
        $matrix[0].caseIndex | Should -Be 0
        $matrix[1].caseIndex | Should -Be 1
        foreach ($testCase in $matrix) {
            $auth = Get-AvmWorkflowAuthentication -Root $script:root -ModulePath $script:modulePath -TestCase $testCase `
                -PoolJson $pool -ModuleClientIds $script:mappingJson -TenantId $script:tenant
            $auth.subscriptionId | Should -BeIn @($script:subscription, $script:secondSubscription)
            $testCase.subscriptionModulePath | Should -BeExactly $script:modulePath
        }
        $result.deploymentMatrix | Should -Not -Match 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    }

    It 'rejects reserved <Owner> cases before compiler access even when another case is General' -ForEach @(
        @{ Owner = 'root' }
        @{ Owner = 'child' }
    ) {
        $ownerPath = $script:modulePath
        $cases = @($script:case)
        if ($Owner -eq 'child') {
            $ownerPath += '/child'
            $folder = Join-Path $script:root $ownerPath 'tests/e2e/defaults'
            $null = New-Item -ItemType Directory -Path $folder -Force
            [IO.File]::WriteAllText((Join-Path $script:root $ownerPath 'main.bicep'), '')
            [IO.File]::WriteAllText((Join-Path $folder 'main.test.bicep'), '')
            $cases += @{ path = 'child/tests/e2e/defaults/main.test.bicep'; name = 'child-defaults'; e2eIgnore = $false }
        }
        [IO.File]::WriteAllText((Join-Path $script:root '.reserved-test-subscriptions.json'),
            (ConvertTo-Json -Compress -InputObject @{ $ownerPath = 'Azure Local' }))
        $pool = ConvertTo-Json -Compress -InputObject @(
            @{ id = $script:subscription; name = 'General' }
            @{ id = $script:secondSubscription; name = 'Reserved'; tag = 'Azure Local' }
        )
        { Get-AvmWorkflowDeploymentMatrix -Root $script:root -ModulePath $script:modulePath -TestFiles $cases `
                -PoolJson $pool -ModuleClientIds $script:mappingJson -TenantId $script:tenant } |
            Should -Throw '*registry-local prepared environment lifecycle*'
        Should -Invoke Get-AvmTool -Exactly 0
        Should -Invoke Invoke-AvmWorkflowProcess -Exactly 0
    }

    It 'uses the child reservation independently from the mapped identity root' {
        $child = "$script:modulePath/child"
        $folder = Join-Path $script:root $child 'tests/e2e/defaults'
        $null = New-Item -ItemType Directory -Path $folder -Force
        [IO.File]::WriteAllText((Join-Path $script:root $child 'main.bicep'), '')
        [IO.File]::WriteAllText((Join-Path $folder 'main.test.bicep'), '')
        [IO.File]::WriteAllText((Join-Path $script:root '.reserved-test-subscriptions.json'),
            (ConvertTo-Json -Compress -InputObject @{ $script:modulePath = 'Azure Local' }))
        $case = @{ path = 'child/tests/e2e/defaults/main.test.bicep'; name = 'child'; e2eIgnore = $false }
        $result = Get-AvmWorkflowDeploymentMatrix -Root $script:root -ModulePath $script:modulePath -TestFiles @($case) `
            -PoolJson $script:pool -ModuleClientIds $script:mappingJson -TenantId $script:tenant
        $selected = (ConvertFrom-Json -InputObject $result.deploymentMatrix -AsHashtable -NoEnumerate)[0]
        $selected.subscriptionModulePath | Should -BeExactly $child
        $selected.identityKey | Should -BeExactly $script:case.identityKey
        $auth = Get-AvmWorkflowAuthentication -Root $script:root -ModulePath $script:modulePath -TestCase $selected `
            -PoolJson $script:pool -ModuleClientIds $script:mappingJson -TenantId $script:tenant
        $auth.clientId | Should -BeExactly $script:client
        $auth.modulePath | Should -BeExactly $child
        $auth.example | Should -BeExactly 'tests/e2e/defaults/main.test.bicep'
    }

    It 'fails reservation drift before authentication rather than selecting the reserved pool' {
        [IO.File]::WriteAllText((Join-Path $script:root '.reserved-test-subscriptions.json'),
            (ConvertTo-Json -Compress -InputObject @{ $script:modulePath = 'Azure Local' }))
        $pool = ConvertTo-Json -Compress -InputObject @(
            @{ id = $script:subscription; name = 'First'; tag = 'Azure Local' }
            @{ id = $script:secondSubscription; name = 'Second'; tag = 'Azure Local' }
        )
        { Get-AvmWorkflowAuthentication -Root $script:root -ModulePath $script:modulePath -TestCase $script:case `
                -PoolJson $pool -ModuleClientIds $script:mappingJson -TenantId $script:tenant } |
            Should -Throw '*registry-local prepared environment lifecycle*'
    }

    It 'rejects missing selection evidence <Field> before authentication' -ForEach @(
        @{ Field = 'selectionSeed' }
        @{ Field = 'caseIndex' }
        @{ Field = 'subscriptionModulePath' }
    ) {
        $script:case.Remove($Field)
        { Get-AvmWorkflowAuthentication -Root $script:root -ModulePath $script:modulePath -TestCase $script:case `
                -PoolJson $script:pool -ModuleClientIds $script:mappingJson -TenantId $script:tenant } |
            Should -Throw '*Rerun selection*'
    }

    It 'passes an explicit singleton through native selection only when no pool is configured' {
        $selected = Select-AvmWorkflowSubscription -Root $script:root -ModulePath $script:modulePath `
            -Example $script:case.path -FallbackSubscriptionId $script:subscription
        $selected.SubscriptionId | Should -BeExactly $script:subscription
        $selected.Index | Should -Be 0
        $selected.Tag | Should -BeExactly 'General'
        { Select-AvmWorkflowSubscription -Root $script:root -ModulePath $script:modulePath `
                -Example $script:case.path -PoolJson ' ' -FallbackSubscriptionId $script:subscription } | Should -Throw
    }

    It 'verifies the actual selected module client, tenant, subscription and cloud' {
        Mock Get-AzContext {
            [pscustomobject]@{
                Subscription = @{ Id = $script:subscription }; Tenant = @{ Id = $script:tenant }
                Account = @{ Id = $script:client; Type = 'ServicePrincipal' }; Environment = @{ Name = 'AzureCloud' }
            }
        }
        Confirm-AvmWorkflowAzureContext -SubscriptionId $script:subscription -TenantId $script:tenant -ClientId $script:client |
            Should -BeExactly $script:tenant
        { Confirm-AvmWorkflowAzureContext -SubscriptionId $script:secondSubscription -TenantId $script:tenant -ClientId $script:client } | Should -Throw '*does not match*'
        { Confirm-AvmWorkflowAzureContext -SubscriptionId $script:subscription -TenantId $script:secondSubscription -ClientId $script:client } | Should -Throw '*does not match*'
        { Confirm-AvmWorkflowAzureContext -SubscriptionId $script:subscription -TenantId $script:tenant -ClientId $script:secondClient } | Should -Throw '*does not match*'
        Mock Get-AzContext {
            [pscustomobject]@{
                Subscription = @{ Id = $script:subscription }; Tenant = @{ Id = $script:tenant }
                Account = @{ Id = $script:client; Type = 'ServicePrincipal' }; Environment = @{ Name = 'AzureUSGovernment' }
            }
        }
        { Confirm-AvmWorkflowAzureContext -SubscriptionId $script:subscription -TenantId $script:tenant -ClientId $script:client } | Should -Throw '*does not match*'
    }
}

Describe 'Component: Bicep workflow module identity action' -Tag Component {
    BeforeAll {
        Import-Module -FullyQualifiedName @{ ModuleName = 'powershell-yaml'; RequiredVersion = '0.4.12' }
        $script:identityActionPath = Join-Path $script:repoRoot '.github' 'actions' 'bicep-module-identity'
        $action = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $script:identityActionPath 'action.yml') -Raw)
        $script:identityActionScript = [scriptblock]::Create($action.runs.steps[0].run)
    }

    BeforeEach {
        $script:identityEnvironment = @{}
        foreach ($name in @('AVM_ACTION_PATH', 'GITHUB_WORKSPACE', 'MODULE_PATH', 'VALIDATE_MODULE_CLIENT_IDS',
                'VALIDATE_TENANT_ID', 'GITHUB_OUTPUT', 'VALIDATE_CLIENT_ID', 'AZURE_CREDENTIALS')) {
            $script:identityEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $env:AVM_ACTION_PATH = $script:identityActionPath
        $env:GITHUB_WORKSPACE = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $env:MODULE_PATH = $script:modulePath
        $env:VALIDATE_MODULE_CLIENT_IDS = ConvertTo-AvmBicepModuleClientIdJson -ClientIds @{
            $script:modulePath = $script:client
            'avm/utl/types/avm-common-types' = $script:secondClient
        }
        $env:VALIDATE_TENANT_ID = $script:tenant
        $env:GITHUB_OUTPUT = Join-Path $env:GITHUB_WORKSPACE 'identity-output'
        $env:VALIDATE_CLIENT_ID = $script:secondClient
        $env:AZURE_CREDENTIALS = '{"clientId":"legacy-client","tenantId":"legacy-tenant"}'
        $null = New-Item -ItemType Directory -Path (Join-Path $env:GITHUB_WORKSPACE $env:MODULE_PATH) -Force
    }

    AfterEach {
        foreach ($name in $script:identityEnvironment.Keys) {
            $value = $script:identityEnvironment[$name]
            [Environment]::SetEnvironmentVariable($name, $(if ($null -eq $value) { [NullString]::Value } else { $value }))
        }
    }

    It 'executes the remote action for <ModulePath> without consulting legacy credentials' -ForEach @(
        @{ ModulePath = 'avm/res/mock/widget'; ModuleRoot = 'avm/res/mock/widget' }
        @{ ModulePath = 'avm/res/mock/widget/child/nested'; ModuleRoot = 'avm/res/mock/widget' }
        @{ ModulePath = 'avm/ptn/lz/sub-vending/sub-scope'; ModuleRoot = 'avm/ptn/lz/sub-vending' }
        @{ ModulePath = 'avm/utl/types/avm-common-types'; ModuleRoot = 'avm/utl/types/avm-common-types' }
        @{ ModulePath = 'avm/res/azure-stack-hci/logical-network'; ModuleRoot = 'avm/res/azure-stack-hci/logical-network' }
    ) {
        $env:MODULE_PATH = $ModulePath
        $env:VALIDATE_MODULE_CLIENT_IDS = ConvertTo-AvmBicepModuleClientIdJson -ClientIds @{ $ModuleRoot = $script:client }
        $null = New-Item -ItemType Directory -Path (Join-Path $env:GITHUB_WORKSPACE $ModulePath) -Force

        & $script:identityActionScript

        $output = Get-Content -LiteralPath $env:GITHUB_OUTPUT -Raw | ConvertFrom-StringData
        @($output.Keys | Sort-Object) | Should -Be @('clientId', 'identityKey', 'moduleRoot', 'tenantId')
        $output.clientId | Should -BeExactly $script:client
        $output.tenantId | Should -BeExactly $script:tenant
        $output.moduleRoot | Should -BeExactly $ModuleRoot
        $expected = Get-AvmWorkflowModuleIdentity -Root $env:GITHUB_WORKSPACE -ModulePath $ModulePath `
            -ModuleClientIds $env:VALIDATE_MODULE_CLIENT_IDS -TenantId $script:tenant
        $output.identityKey | Should -BeExactly $expected.identityKey
    }

    It 'emits no partial authentication output for <Failure>' -ForEach @(
        @{ Failure = 'missing mapping' }
        @{ Failure = 'nested mapping' }
        @{ Failure = 'duplicate mapping key' }
        @{ Failure = 'reused client' }
        @{ Failure = 'invalid tenant' }
        @{ Failure = 'missing root' }
    ) {
        switch ($Failure) {
            'missing mapping' { $env:VALIDATE_MODULE_CLIENT_IDS = '' }
            'nested mapping' { $env:VALIDATE_MODULE_CLIENT_IDS = '{"avm/res/mock/widget":{"clientId":"10000000-0000-4000-8000-000000000006"}}' }
            'duplicate mapping key' { $env:VALIDATE_MODULE_CLIENT_IDS = '{"avm/res/mock/widget":"10000000-0000-4000-8000-000000000006","avm/res/mock/widget":"10000000-0000-4000-8000-000000000016"}' }
            'reused client' { $env:VALIDATE_MODULE_CLIENT_IDS = '{"avm/res/mock/widget":"10000000-0000-4000-8000-000000000006","avm/utl/types/avm-common-types":"10000000-0000-4000-8000-000000000006"}' }
            'invalid tenant' { $env:VALIDATE_TENANT_ID = '00000000-0000-0000-0000-000000000000' }
            'missing root' { $env:MODULE_PATH = 'avm/res/mock/widget-extra' }
        }
        { & $script:identityActionScript } | Should -Throw
        Test-Path -LiteralPath $env:GITHUB_OUTPUT | Should -BeFalse
    }
}

Describe 'Component: Bicep shared workflow native phase forwarding' -Tag Component {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $folder = Join-Path $script:root $script:modulePath 'tests/e2e/defaults'
        $null = New-Item -ItemType Directory -Path $folder -Force
        [IO.File]::WriteAllText((Join-Path $script:root 'bicepconfig.json'), '{}')
        [IO.File]::WriteAllText((Join-Path $script:root '.reserved-test-subscriptions.json'), '{}')
        [IO.File]::WriteAllText((Join-Path $script:root $script:modulePath 'main.bicep'), '')
        [IO.File]::WriteAllText((Join-Path $folder 'main.test.bicep'), '')
        $script:output = Join-Path $script:root 'results'
        $script:state = Join-Path $script:root 'state.json'
        Mock Invoke-AvmTestE2e { [pscustomobject]@{ Status = 'pass'; RunsTotal = 1; RunsSkipped = 0; Issues = @() } }
        Mock Invoke-AvmTestUnit { [pscustomobject]@{ Status = 'pass'; RunsTotal = 1; RunsSkipped = 0; RunsFiltered = 0; Issues = @() } }
        Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Status = 'pass'; TestsSelected = 1; BaselinesExecuted = 1; Issues = @() } }
        Mock Invoke-AvmTestCleanup { [pscustomobject]@{ Status = 'pass' } }
        Mock Get-AzContext {
            [pscustomobject]@{
                Subscription = @{ Id = $script:subscription }; Tenant = @{ Id = $script:tenant }
                Account = @{ Id = $script:client; Type = 'ServicePrincipal' }; Environment = @{ Name = 'AzureCloud' }
            }
        }
    }

    It 'uses one packaged compliance and authored-unit route without custom compliance paths' {
        Invoke-AvmWorkflowStaticValidation -Root $script:root -ModulePath $script:modulePath -ResultDirectory $script:output
        Should -Invoke Invoke-AvmTestUnit -Exactly 1 -ParameterFilter {
            $IncludeCompliance -and $Recurse -and $Ecosystem -eq 'bicep' -and -not $CompliancePath -and $SkipModuleVersionCheck
        }
    }

    It 'forwards only one policy example/baseline and rejects empty evaluations' {
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

    It 'leaves pool selection and reservation validation to native policy without changing the singleton' {
        $saved = @{}
        foreach ($name in @('TEST_SUBSCRIPTION_IDS', 'VALIDATE_SUBSCRIPTION_ID')) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        try {
            $env:TEST_SUBSCRIPTION_IDS = '[{"id":"99999999-2222-4333-8444-555555555555","name":"Reserved","tag":"Azure Local"}]'
            $env:VALIDATE_SUBSCRIPTION_ID = $script:subscription
            Mock Invoke-AvmCheckPolicy {
                $env:VALIDATE_SUBSCRIPTION_ID | Should -BeExactly $script:subscription
                $env:TEST_SUBSCRIPTION_IDS | Should -Match '"tag":"Azure Local"'
                throw [ArgumentException]::new('Native reservation selection rejected the configured pool.')
            }

            { Invoke-AvmWorkflowPolicyValidation -Root $script:root -ModulePath $script:modulePath `
                    -Example 'tests/e2e/defaults/main.test.bicep' -Baseline Azure.Default -ResultDirectory $script:output } |
                Should -Throw '*Native reservation selection*'
            Should -Invoke Invoke-AvmCheckPolicy -Exactly 1 -ParameterFilter {
                $Path -ceq (Join-Path $script:root $script:modulePath) -and $Ecosystem -ceq 'bicep' -and $SkipModuleVersionCheck
            }
            $env:VALIDATE_SUBSCRIPTION_ID | Should -BeExactly $script:subscription
        }
        finally {
            foreach ($name in $saved.Keys) {
                $value = $saved[$name]
                [Environment]::SetEnvironmentVariable($name, $(if ($null -eq $value) { [NullString]::Value } else { $value }))
            }
        }
    }

    It 'separates deployment inputs from state-selected completion and keeps metadata location fixed' {
        $parameters = @{
            Root = $script:root; ModulePath = $script:modulePath; SubscriptionId = $script:subscription
            TenantId = $script:tenant; ClientId = $script:client; StatePath = $script:state; ResultDirectory = $script:output
        }
        Invoke-AvmWorkflowE2e @parameters -Phase Deploy -Example 'tests/e2e/defaults/main.test.bicep' -CustomLocation northeurope -RemoveDeployment $false -Confirm:$false
        Invoke-AvmWorkflowE2e @parameters -Phase Complete -RemoveDeployment $false -Confirm:$false
        Should -Invoke Invoke-AvmTestE2e -Exactly 1 -ParameterFilter {
            $Phase -eq 'Deploy' -and $UseCiInputs -and $Location -eq 'WestEurope' -and $ResourceLocation -eq 'northeurope' -and $KeepResources
        }
        Should -Invoke Invoke-AvmTestE2e -Exactly 1 -ParameterFilter {
            $Phase -eq 'Complete' -and -not $UseCiInputs -and -not $Example -and -not $ManagementGroupId -and -not $ResourceLocation -and $KeepResources
        }
    }

    It 'passes the native-selected child owner to deployment and completion without changing its root identity' {
        $child = "$script:modulePath/child"
        $folder = Join-Path $script:root $child 'tests/e2e/defaults'
        $null = New-Item -ItemType Directory -Path $folder -Force
        [IO.File]::WriteAllText((Join-Path $script:root $child 'main.bicep'), '')
        [IO.File]::WriteAllText((Join-Path $folder 'main.test.bicep'), '')
        $pool = ConvertTo-Json -Compress -InputObject @(@{ id = $script:subscription; name = 'General' })
        $mapping = ConvertTo-AvmBicepModuleClientIdJson -ClientIds @{ $script:modulePath = $script:client }
        $requestedExample = 'child/tests/e2e/defaults/main.test.bicep'
        $selected = Select-AvmTestSubscription -Path $script:root -ModulePath $script:modulePath `
            -Example $requestedExample -TestSubscriptionIds $pool -SkipModuleVersionCheck
        $identity = Get-AvmWorkflowModuleIdentity -Root $script:root -ModulePath $script:modulePath `
            -ModuleClientIds $mapping -TenantId $script:tenant
        $case = @{
            path = $requestedExample; identityKey = $identity.identityKey; subscriptionIndex = $selected.Index
            subscriptionKey = $selected.Key; subscriptionModulePath = $selected.ModulePath
            selectionSeed = 0; caseIndex = 0
        }
        $auth = Get-AvmWorkflowAuthentication -Root $script:root -ModulePath $script:modulePath -TestCase $case `
            -PoolJson $pool -ModuleClientIds $mapping -TenantId $script:tenant
        $auth.clientId | Should -BeExactly $script:client
        $auth.modulePath | Should -BeExactly $child
        $script:expectedOwnerPath = Resolve-AvmWorkflowPath -Root $script:root -RelativePath $child
        $parameters = @{
            Root = $script:root; ModulePath = $auth.modulePath; SubscriptionId = $auth.subscriptionId
            TenantId = $auth.tenantId; ClientId = $auth.clientId; StatePath = $script:state; ResultDirectory = $script:output
        }
        $script:ownerCalls = [Collections.Generic.List[object]]::new()
        Mock Invoke-AvmTestE2e {
            $script:ownerCalls.Add([pscustomobject]@{
                    Phase = $PesterBoundParameters['Phase']; Path = $PesterBoundParameters['Path']
                    Example = $PesterBoundParameters['Example']; UseCiInputs = [bool]$PesterBoundParameters['UseCiInputs']
                    SubscriptionId = $PesterBoundParameters['SubscriptionId']; TenantId = $PesterBoundParameters['TenantId']
                })
            [pscustomobject]@{ Status = 'pass'; RunsTotal = 1; RunsSkipped = 0; Issues = @() }
        }
        Invoke-AvmWorkflowE2e @parameters -Phase Deploy -Example $auth.example -Confirm:$false
        Invoke-AvmWorkflowE2e @parameters -Phase Complete -Confirm:$false
        Should -Invoke Invoke-AvmTestE2e -Exactly 2
        @($script:ownerCalls.Phase) | Should -Be @('Deploy', 'Complete')
        foreach ($call in $script:ownerCalls) {
            $call.Path | Should -BeExactly $script:expectedOwnerPath
            $call.SubscriptionId | Should -BeExactly $script:subscription
            $call.TenantId | Should -BeExactly $script:tenant
        }
        @($script:ownerCalls[0].Example) | Should -Be @('tests/e2e/defaults/main.test.bicep')
        $script:ownerCalls[0].UseCiInputs | Should -BeTrue
        $script:ownerCalls[1].Example | Should -BeNullOrEmpty
        $script:ownerCalls[1].UseCiInputs | Should -BeFalse
    }

    It 'does not run native mutations under WhatIf or on absent recovery state' {
        Invoke-AvmWorkflowE2e -Root $script:root -ModulePath $script:modulePath -Phase Deploy `
            -SubscriptionId $script:subscription -TenantId $script:tenant -ClientId $script:client -Example 'tests/e2e/defaults/main.test.bicep' `
            -StatePath $script:state -ResultDirectory $script:output -WhatIf
        Invoke-AvmWorkflowRecovery -StatePath $script:state -SubscriptionId $script:subscription -TenantId $script:tenant -ClientId $script:client -Confirm:$false
        Should -Invoke Invoke-AvmTestE2e -Exactly 0
        Should -Invoke Invoke-AvmTestCleanup -Exactly 0
        Should -Invoke Get-AzContext -Exactly 0
    }

    It 'uses state-only recovery without rerunning deployment or authored hooks' {
        [IO.File]::WriteAllText($script:state, '{}')
        Invoke-AvmWorkflowRecovery -StatePath $script:state -SubscriptionId $script:subscription -TenantId $script:tenant -ClientId $script:client -Confirm:$false
        Should -Invoke Invoke-AvmTestCleanup -Exactly 1 -ParameterFilter { $SubscriptionId -eq $script:subscription -and $TenantId -eq $script:tenant }
        Should -Invoke Invoke-AvmTestE2e -Exactly 0
    }

    It 'keeps two module identities separate through deployment, completion and recovery' {
        $mapping = [ordered]@{
            $script:modulePath = $script:client
            'avm/ptn/lz/sub-vending' = $script:secondClient
        }
        $json = ConvertTo-AvmBicepModuleClientIdJson -ClientIds $mapping
        $pool = ConvertTo-Json -Compress -InputObject @(@{ id = $script:subscription; name = 'Test subscription' })
        $selectedClients = [Collections.Generic.List[string]]::new()
        Mock Get-AzContext {
            $selectedClients.Add($script:activeClient)
            [pscustomobject]@{
                Subscription = @{ Id = $script:subscription }; Tenant = @{ Id = $script:tenant }
                Account = @{ Id = $script:activeClient; Type = 'ServicePrincipal' }; Environment = @{ Name = 'AzureCloud' }
            }
        }
        foreach ($modulePath in $mapping.Keys) {
            $example = 'tests/e2e/defaults/main.test.bicep'
            $folder = Join-Path $script:root $modulePath 'tests/e2e/defaults'
            $null = New-Item -ItemType Directory -Path $folder -Force
            [IO.File]::WriteAllText((Join-Path $script:root $modulePath 'main.bicep'), '')
            [IO.File]::WriteAllText((Join-Path $folder 'main.test.bicep'), '')
            $identity = Get-AvmWorkflowModuleIdentity -Root $script:root -ModulePath $modulePath -ModuleClientIds $json -TenantId $script:tenant
            $target = Select-AvmTestSubscription -Path $script:root -ModulePath $modulePath -Example $example `
                -TestSubscriptionIds $pool -SkipModuleVersionCheck
            $case = @{
                path = $example; identityKey = $identity.identityKey; subscriptionIndex = $target.Index; subscriptionKey = $target.Key
                selectionSeed = 0; caseIndex = 0; subscriptionModulePath = $target.ModulePath
            }
            $auth = Get-AvmWorkflowAuthentication -Root $script:root -ModulePath $modulePath -TestCase $case `
                -ModuleClientIds $json -PoolJson $pool -TenantId $script:tenant
            $auth.clientId | Should -BeExactly $mapping[$modulePath]
            $script:activeClient = $auth.clientId
            $state = Join-Path $script:root "$($auth.clientId).json"
            $parameters = @{
                Root = $script:root; ModulePath = $modulePath; SubscriptionId = $auth.subscriptionId
                TenantId = $auth.tenantId; ClientId = $auth.clientId; StatePath = $state; ResultDirectory = $script:output
            }
            Invoke-AvmWorkflowE2e @parameters -Phase Deploy -Example $example -Confirm:$false
            Invoke-AvmWorkflowE2e @parameters -Phase Complete -Confirm:$false
            [IO.File]::WriteAllText($state, '{}')
            Invoke-AvmWorkflowRecovery -StatePath $state -SubscriptionId $auth.subscriptionId -TenantId $auth.tenantId `
                -ClientId $auth.clientId -Confirm:$false
        }
        @($selectedClients) | Should -Be @(
            $script:client, $script:client, $script:client, $script:secondClient, $script:secondClient, $script:secondClient
        )
        Should -Invoke Invoke-AvmTestE2e -Exactly 4 -ParameterFilter {
            $SubscriptionId -eq $script:subscription -and $TenantId -eq $script:tenant
        }
        Should -Invoke Invoke-AvmTestCleanup -Exactly 2 -ParameterFilter {
            $SubscriptionId -eq $script:subscription -and $TenantId -eq $script:tenant
        }
    }

    It 'refuses an account switch before deployment, completion or recovery' {
        $parameters = @{
            Root = $script:root; ModulePath = $script:modulePath; SubscriptionId = $script:subscription
            TenantId = $script:tenant; ClientId = $script:secondClient; StatePath = $script:state; ResultDirectory = $script:output
        }
        foreach ($phase in @('Deploy', 'Complete')) {
            { Invoke-AvmWorkflowE2e @parameters -Phase $phase -Example 'tests/e2e/defaults/main.test.bicep' -Confirm:$false } |
                Should -Throw '*selected module client*'
        }
        [IO.File]::WriteAllText($script:state, '{}')
        { Invoke-AvmWorkflowRecovery -StatePath $script:state -SubscriptionId $script:subscription -TenantId $script:tenant `
                -ClientId $script:secondClient -Confirm:$false } | Should -Throw '*selected module client*'
        Should -Invoke Invoke-AvmTestE2e -Exactly 0
        Should -Invoke Invoke-AvmTestCleanup -Exactly 0
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
