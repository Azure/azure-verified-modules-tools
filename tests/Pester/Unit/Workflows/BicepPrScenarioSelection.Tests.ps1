#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    Import-Module -FullyQualifiedName @{ ModuleName = 'powershell-yaml'; RequiredVersion = '0.4.12' }
    Import-Module (Join-Path $root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    $action = ConvertFrom-Yaml (Get-Content -LiteralPath (
            Join-Path $root '.github' 'actions' 'bicep-pr-check-initializer' 'action.yml') -Raw)
    $gate = ($action.runs.steps | Where-Object { $_['id'] -eq 'gate' }).run
    $initialize = ($action.runs.steps | Where-Object { $_['id'] -eq 'initialize' }).run
    $start = $initialize.IndexOf('$modules = [Collections.Generic.List[object]]::new()')
    $end = $initialize.IndexOf('$values = [ordered]@{')
    if ($start -lt 0 -or $end -le $start) { throw 'Scenario selection could not be located.' }
    $selection = [scriptblock]::Create(
        $initialize.Substring($start, $end - $start) +
        "`n[pscustomobject]@{ modules = @(`$modules); hasRequired = `$hasRequiredModules; hasOptional = `$hasOptionalModules; errors = @(`$requiredErrors) }")
    $parametersStart = $initialize.IndexOf('$parameters = @{')
    $configure = [scriptblock]::Create($initialize.Substring($parametersStart, $start - $parametersStart) + "`n`$outputs")
    $emit = [scriptblock]::Create($initialize.Substring($start))
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Bicep PR scenario selection' {
    BeforeEach {
        $saved = @{}
        foreach ($name in @('FORK', 'REQUIRED', 'OPTIONAL', 'ARTIFACT', 'GITHUB_OUTPUT', 'KEEP_RESOURCES',
                'GITHUB_WORKSPACE', 'EVENT_NAME', 'TARGET_COMMIT')) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $env:FORK = 'false'
        $env:REQUIRED = 'true'
        $env:OPTIONAL = 'true'
        $env:ARTIFACT = 'fixture-artifact'
        $env:KEEP_RESOURCES = $action.inputs.keepResources.default
        $env:GITHUB_WORKSPACE = $TestDrive
        $env:EVENT_NAME = 'workflow_dispatch'
        $env:TARGET_COMMIT = 'a' * 40
        $env:GITHUB_OUTPUT = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $outputs = [pscustomobject]@{
            BaseCommit = 'fixture-base'
            TargetCommit = 'fixture-target'
            WorkflowInput = @{ deploymentValidation = 'true' }
            ModuleMatrix = @{ Include = @(
                    [pscustomobject]@{
                        ModulePath = 'avm/res/example/widget'
                        TestFiles = @(
                            @{ path = 'tests/e2e/defaults/main.test.bicep'; name = 'defaults'; e2eIgnore = $false }
                            @{ path = 'tests/e2e/waf-aligned/main.test.bicep'; name = 'waf-aligned'; e2eIgnore = $false }
                            @{ path = 'tests/e2e/max/main.test.bicep'; name = 'max'; e2eIgnore = $false }
                        )
                        PolicyTestFiles = @(@{ path = 'tests/e2e/defaults/main.test.bicep'; name = 'defaults' })
                    },
                    [pscustomobject]@{
                        ModulePath = 'avm/utl/example/widget'
                        TestFiles = @()
                        PolicyTestFiles = @()
                    }
                ) }
        }
    }

    AfterEach {
        foreach ($name in $saved.Keys) {
            $value = $saved[$name]
            [Environment]::SetEnvironmentVariable($name, $(if ($null -eq $value) { [NullString]::Value } else { $value }))
        }
    }

    It 'propagates keepResources=<Keep> for <Event> through the existing cleanup control' -ForEach @(
        @{ Keep = 'false'; Event = 'pull_request'; Remove = $true }
        @{ Keep = 'false'; Event = 'workflow_dispatch'; Remove = $true }
        @{ Keep = 'true'; Event = 'workflow_dispatch'; Remove = $false }
    ) {
        $env:KEEP_RESOURCES = $Keep
        $env:EVENT_NAME = $Event
        Mock Initialize-AvmBicepWorkflowMatrix {
            [pscustomobject]@{ WorkflowInput = @{ removeDeployment = $RemoveDeployment.ToString().ToLowerInvariant() } }
        }
        $configured = & $configure
        Should -Invoke Initialize-AvmBicepWorkflowMatrix -Exactly 1 -ParameterFilter {
            $RemoveDeployment -eq $Remove
        }
        $outputs.WorkflowInput.removeDeployment = $configured.WorkflowInput.removeDeployment
        & $emit
        $values = Get-Content -LiteralPath $env:GITHUB_OUTPUT -Raw | ConvertFrom-StringData
        ($values.workflowInput | ConvertFrom-Json).removeDeployment |
            Should -BeExactly $Remove.ToString().ToLowerInvariant()
    }

    It 'selects <Description> into one shared module entry' -ForEach @(
        @{ Description = 'no tests'; Required = 'false'; Optional = 'false'; Expected = @(); Route = 'none' }
        @{ Description = 'required tests'; Required = 'true'; Optional = 'false'; Expected = @('defaults', 'waf-aligned'); Route = 'native' }
        @{ Description = 'only the optional flag'; Required = 'false'; Optional = 'true'; Expected = @('max'); Route = 'native' }
        @{ Description = 'the union'; Required = 'true'; Optional = 'true'; Expected = @('defaults', 'waf-aligned', 'max'); Route = 'native' }
    ) {
        $env:REQUIRED = $Required
        $env:OPTIONAL = $Optional
        $result = & $selection
        $result.errors | Should -BeNullOrEmpty
        $result.modules | Should -HaveCount 2
        $result.hasRequired | Should -BeTrue
        $result.hasOptional | Should -BeTrue
        $result.modules[0].e2eRoute | Should -BeExactly $Route
        $result.modules[1].e2eRoute | Should -BeExactly 'none'
        @($result.modules[0].moduleTestFilePaths | ConvertFrom-Json | ForEach-Object name) | Should -Be $Expected
        @($result.modules[0].psRuleModuleTestFilePaths | ConvertFrom-Json | ForEach-Object name) | Should -Be @('defaults')
    }

    It 'treats default and defaults as aliases for required Bicep baseline scenarios: <Names>' -ForEach @(
        @{ Names = @('default'); Expected = @('default', 'waf-aligned', 'max') }
        @{ Names = @('defaults'); Expected = @('defaults', 'waf-aligned', 'max') }
        @{ Names = @('default', 'defaults'); Expected = @('default', 'defaults', 'waf-aligned', 'max') }
    ) {
        $outputs.ModuleMatrix.Include = @($outputs.ModuleMatrix.Include[0])
        $baselineTests = @($Names | ForEach-Object {
                @{ path = "tests/e2e/$_/main.test.bicep"; name = $_; e2eIgnore = $false }
            })
        $baselineTests += @{ path = 'tests/e2e/waf-aligned/main.test.bicep'; name = 'waf-aligned'; e2eIgnore = $false }
        $baselineTests += @{ path = 'tests/e2e/max/main.test.bicep'; name = 'max'; e2eIgnore = $false }
        $outputs.ModuleMatrix.Include[0].TestFiles = $baselineTests

        $records = @(& $selection 6>&1)
        $warnings = @($records | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })
        $result = $records[-1]
        $warnings | Should -BeNullOrEmpty
        $result.errors | Should -BeNullOrEmpty
        $result.hasRequired | Should -BeTrue
        @($result.modules[0].moduleTestFilePaths | ConvertFrom-Json | ForEach-Object name) | Should -Be $Expected
    }

    It 'disables test selection for forks or deployment-disabled workflow input' -ForEach @(
        @{ Fork = 'true'; Deployment = 'true' }
        @{ Fork = 'false'; Deployment = 'false' }
    ) {
        $env:FORK = $Fork
        $outputs.WorkflowInput.deploymentValidation = $Deployment
        $result = & $selection
        $result.hasRequired | Should -BeTrue
        $result.modules[0].e2eRoute | Should -BeExactly 'none'
        $result.modules[0].moduleTestFilePaths | Should -BeExactly '[]'
    }

    It 'warns when a resource module is missing its WAF-aligned scenario' {
        $outputs.ModuleMatrix.Include = @($outputs.ModuleMatrix.Include[0])
        $outputs.ModuleMatrix.Include[0].ModulePath = 'avm/res/example/widget'
        $outputs.ModuleMatrix.Include[0].TestFiles = @($outputs.ModuleMatrix.Include[0].TestFiles |
                Where-Object name -NE 'waf-aligned')
        $records = @(& $selection 6>&1)
        $warning = @($records | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })
        $result = $records[-1]
        $warning | Should -HaveCount 1
        $warning[0].MessageData | Should -Match '^::warning::.*resource module is missing.*waf-aligned'
        $result.errors | Should -BeNullOrEmpty
        $result.hasRequired | Should -BeTrue
        @($result.modules[0].moduleTestFilePaths | ConvertFrom-Json | ForEach-Object name) |
            Should -Be @('defaults', 'max')
    }

    It 'requires defaults-prefixed examples but not WAF-aligned for <ModuleType>' -ForEach @(
        @{ ModuleType = 'ptn' }
        @{ ModuleType = 'utl' }
    ) {
        $outputs.ModuleMatrix.Include = @($outputs.ModuleMatrix.Include[0])
        $outputs.ModuleMatrix.Include[0].ModulePath = "avm/$ModuleType/example/widget"
        $outputs.ModuleMatrix.Include[0].TestFiles = @(
            @{ path = 'tests/e2e/defaults.azuredevops.aci/main.test.bicep'; name = 'defaults.azuredevops.aci'; e2eIgnore = $false }
            @{ path = 'tests/e2e/defaults-azuredevops-aci/main.test.bicep'; name = 'defaults-azuredevops-aci'; e2eIgnore = $false }
            @{ path = 'tests/e2e/waf-aligned-westus/main.test.bicep'; name = 'waf-aligned-westus'; e2eIgnore = $false }
            @{ path = 'tests/e2e/max/main.test.bicep'; name = 'max'; e2eIgnore = $false }
        )
        $records = @(& $selection 6>&1)
        @($records | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }) |
            Should -BeNullOrEmpty
        $result = $records[-1]
        $result.errors | Should -BeNullOrEmpty
        $result.hasRequired | Should -BeTrue
        $result.hasOptional | Should -BeTrue
        @($result.modules[0].moduleTestFilePaths | ConvertFrom-Json | ForEach-Object name) |
            Should -Be @('defaults.azuredevops.aci', 'defaults-azuredevops-aci', 'waf-aligned-westus', 'max')
    }

    It 'warns and does not require E2E when both scenarios are missing for <ModuleType>' -ForEach @(
        @{ ModuleType = 'res' }
        @{ ModuleType = 'ptn' }
        @{ ModuleType = 'utl' }
    ) {
        $outputs.ModuleMatrix.Include = @($outputs.ModuleMatrix.Include[0])
        $outputs.ModuleMatrix.Include[0].ModulePath = "avm/$ModuleType/example/widget"
        $outputs.ModuleMatrix.Include[0].TestFiles = @($outputs.ModuleMatrix.Include[0].TestFiles |
                Where-Object name -EQ 'max')
        $records = @(& $selection 6>&1)
        $warnings = @($records | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })
        $warnings | Should -HaveCount $(if ($ModuleType -ceq 'res') { 2 } else { 1 })
        $result = $records[-1]
        $result.errors | Should -BeNullOrEmpty
        $result.hasRequired | Should -BeFalse
        $result.hasOptional | Should -BeTrue
        $result.modules[0].e2eRoute | Should -BeExactly 'native'
        @($result.modules[0].moduleTestFilePaths | ConvertFrom-Json | ForEach-Object name) | Should -Be @('max')
    }

    It 'reports ignored required scenarios as errors for <ModuleType>' -ForEach @(
        @{ ModuleType = 'res'; IgnoredName = 'waf-aligned' }
        @{ ModuleType = 'ptn'; IgnoredName = 'defaults' }
        @{ ModuleType = 'utl'; IgnoredName = 'defaults' }
    ) {
        $outputs.ModuleMatrix.Include = @($outputs.ModuleMatrix.Include[0])
        $outputs.ModuleMatrix.Include[0].ModulePath = "avm/$ModuleType/example/widget"
        $ignored = $outputs.ModuleMatrix.Include[0].TestFiles |
            Where-Object name -CEQ $IgnoredName
        $ignored.e2eIgnore = $true
        $result = & $selection
        $result.errors | Should -Not -BeNullOrEmpty
        ($result.errors -join ' ') | Should -Match ('ignored.*' + [regex]::Escape($IgnoredName))
        $result.hasRequired | Should -BeTrue
    }

    It 'warns for a missing parent scenario even when a child scenario exists' {
        $outputs.ModuleMatrix.Include = @($outputs.ModuleMatrix.Include[0])
        $outputs.ModuleMatrix.Include[0].TestFiles[1].path = 'child/tests/e2e/waf-aligned/main.test.bicep'
        $records = @(& $selection 6>&1)
        @($records | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })[0].MessageData |
            Should -Match 'missing.*waf-aligned'
        $result = $records[-1]
        $result.errors | Should -BeNullOrEmpty
        @($result.modules[0].moduleTestFilePaths | ConvertFrom-Json | ForEach-Object name) |
            Should -Be @('defaults', 'waf-aligned', 'max')
    }

    It 'warns without errors when a utility module has no tests' {
        $outputs.ModuleMatrix.Include = @($outputs.ModuleMatrix.Include[1])
        $env:OPTIONAL = 'false'
        $records = @(& $selection 6>&1)
        $warnings = @($records | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })
        $warnings | Should -HaveCount 1
        $warnings[0].MessageData | Should -Match '^::warning::.*utility module is missing.*defaults'
        $result = $records[-1]
        $result.errors | Should -BeNullOrEmpty
        $result.hasRequired | Should -BeFalse
        $result.modules[0].e2eRoute | Should -BeExactly 'none'
        $result.modules[0].moduleTestFilePaths | Should -BeExactly '[]'
    }

    It 'retains optional ignored records for the runtime to skip' {
        $outputs.ModuleMatrix.Include[0].TestFiles[2].e2eIgnore = $true
        $env:REQUIRED = 'false'
        $result = & $selection
        $selected = @($result.modules[0].moduleTestFilePaths | ConvertFrom-Json)
        $selected | Should -HaveCount 1
        $selected[0].name | Should -BeExactly 'max'
        $selected[0].e2eIgnore | Should -BeTrue
    }

    It 'emits a single selected module matrix and preserves gate outputs' {
        $env:REQUIRED = 'false'
        & $emit
        $result = @{}
        foreach ($line in Get-Content -LiteralPath $env:GITHUB_OUTPUT) {
            $parts = $line -split '=', 2
            $result[$parts[0]] = $parts[1]
        }
        $result.hasModules | Should -BeExactly 'true'
        $result.hasRequiredModules | Should -BeExactly 'true'
        $result.hasOptionalModules | Should -BeExactly 'true'
        $result.requiredErrors | Should -BeExactly '[]'
        $result.authoringArtifact | Should -BeExactly 'fixture-artifact'
        $result.baseCommit | Should -BeExactly 'fixture-base'
        $result.targetCommit | Should -BeExactly 'fixture-target'
        $result.ContainsKey('requiredMatrix') | Should -BeFalse
        $result.ContainsKey('optionalMatrix') | Should -BeFalse
        $matrix = $result.moduleMatrix | ConvertFrom-Json
        $matrix.include | Should -HaveCount 2
        $matrix.include[0].e2eRoute | Should -BeExactly 'native'
        @($matrix.include[0].moduleTestFilePaths | ConvertFrom-Json | ForEach-Object name) | Should -Be @('max')
    }

    It 'emits an empty matrix and false gate flags when no modules exist' {
        $outputs.ModuleMatrix.Include = @()
        & $emit
        $result = @{}
        foreach ($line in Get-Content -LiteralPath $env:GITHUB_OUTPUT) {
            $parts = $line -split '=', 2
            $result[$parts[0]] = $parts[1]
        }
        $result.hasModules | Should -BeExactly 'false'
        $result.hasRequiredModules | Should -BeExactly 'false'
        $result.hasOptionalModules | Should -BeExactly 'false'
        @((ConvertFrom-Json $result.moduleMatrix).include) | Should -BeNullOrEmpty
    }
}

Describe 'Bicep PR label admission' {
    BeforeEach {
        $saved = @{}
        foreach ($name in @('EVENT_NAME', 'REPOSITORY', 'HEAD_REPOSITORY', 'EVENT_ACTION', 'EVENT_LABEL',
                'PR_LABELS', 'DEPLOYMENT_VALIDATION', 'KEEP_RESOURCES', 'GITHUB_OUTPUT', 'FORK', 'REQUIRED', 'OPTIONAL')) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $env:EVENT_NAME = 'pull_request'
        $env:REPOSITORY = 'Azure/bicep-registry-modules'
        $env:HEAD_REPOSITORY = $env:REPOSITORY
        $env:EVENT_ACTION = 'labeled'
        $env:EVENT_LABEL = 'PR: Run All E2E Tests'
        $env:DEPLOYMENT_VALIDATION = 'false'
        $env:KEEP_RESOURCES = $action.inputs.keepResources.default
        $env:GITHUB_OUTPUT = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }

    AfterEach {
        foreach ($name in $saved.Keys) {
            $value = $saved[$name]
            [Environment]::SetEnvironmentVariable($name, $(if ($null -eq $value) { [NullString]::Value } else { $value }))
        }
    }

    It 'rejects malformed retention input <Value>' -ForEach @(
        @{ Value = '' }
        @{ Value = 'True' }
        @{ Value = '1' }
    ) {
        $env:EVENT_NAME = 'workflow_dispatch'
        $env:KEEP_RESOURCES = $Value
        { & ([scriptblock]::Create($gate)) } | Should -Throw '*keepResources must be exactly true or false*'
        Test-Path -LiteralPath $env:GITHUB_OUTPUT | Should -BeFalse
    }

    It 'rejects retention for non-manual event <Event>' -ForEach @(
        @{ Event = 'pull_request' }
        @{ Event = 'push' }
    ) {
        $env:EVENT_NAME = $Event
        $env:KEEP_RESOURCES = 'true'
        { & ([scriptblock]::Create($gate)) } | Should -Throw '*keepResources requires manual dispatch*'
        Test-Path -LiteralPath $env:GITHUB_OUTPUT | Should -BeFalse
    }

    It 'admits manual retention without disabling deployment assertions' {
        $env:EVENT_NAME = 'workflow_dispatch'
        $env:DEPLOYMENT_VALIDATION = 'true'
        $env:KEEP_RESOURCES = 'true'
        & ([scriptblock]::Create($gate))
        $result = Get-Content -LiteralPath $env:GITHUB_OUTPUT -Raw | ConvertFrom-StringData
        $result.admitted | Should -BeExactly 'true'
        $result.deployment | Should -BeExactly 'true'
        $result.required | Should -BeExactly 'true'
        $result.optional | Should -BeExactly 'true'
    }

    It 'selects the correct tests for <Labels>' -ForEach @(
        @{ Labels = '[]'; Required = 'false'; Optional = 'false'; Expected = @(); Route = 'none' }
        @{ Labels = '["PR: Run Required E2E Tests"]'; Required = 'true'; Optional = 'false'; Expected = @('defaults', 'waf-aligned'); Route = 'native' }
        @{ Labels = '["PR: Run All E2E Tests"]'; Required = 'true'; Optional = 'true'; Expected = @('defaults', 'waf-aligned', 'max'); Route = 'native' }
        @{ Labels = '["PR: Run Required E2E Tests","PR: Run All E2E Tests"]'; Required = 'true'; Optional = 'true'; Expected = @('defaults', 'waf-aligned', 'max'); Route = 'native' }
    ) {
        $env:PR_LABELS = $Labels
        & ([scriptblock]::Create($gate))
        $result = Get-Content -LiteralPath $env:GITHUB_OUTPUT -Raw | ConvertFrom-StringData
        $result.admitted | Should -BeExactly 'true'
        $result.required | Should -BeExactly $Required
        $result.optional | Should -BeExactly $Optional
        $action.outputs.requiredRequested.value | Should -BeExactly '${{ steps.gate.outputs.required }}'
        $env:FORK = $result.fork
        $env:REQUIRED = $result.required
        $env:OPTIONAL = $result.optional
        $outputs = [pscustomobject]@{
            WorkflowInput = @{ deploymentValidation = $result.deployment }
            ModuleMatrix = @{ Include = @(
                    [pscustomobject]@{
                        ModulePath = 'avm/res/example/widget'
                        TestFiles = @(
                            @{ path = 'tests/e2e/defaults/main.test.bicep'; name = 'defaults'; e2eIgnore = $false }
                            @{ path = 'tests/e2e/waf-aligned/main.test.bicep'; name = 'waf-aligned'; e2eIgnore = $false }
                            @{ path = 'tests/e2e/max/main.test.bicep'; name = 'max'; e2eIgnore = $false }
                        )
                        PolicyTestFiles = @()
                    }
                ) }
        }
        $selected = & $selection
        $selected.modules[0].e2eRoute | Should -BeExactly $Route
        @($selected.modules[0].moduleTestFilePaths | ConvertFrom-Json | ForEach-Object name) | Should -Be $Expected
    }

    It 'does not deploy from forks for <Labels>' -ForEach @(
        @{ Labels = '["PR: Run All E2E Tests"]' }
        @{ Labels = '["PR: Run Required E2E Tests","PR: Run All E2E Tests"]' }
    ) {
        $env:HEAD_REPOSITORY = 'fork/repo'
        $env:PR_LABELS = $Labels
        & ([scriptblock]::Create($gate))
        $result = Get-Content -LiteralPath $env:GITHUB_OUTPUT -Raw | ConvertFrom-StringData
        $result.required | Should -BeExactly 'false'
        $result.optional | Should -BeExactly 'false'
        $result.deployment | Should -BeExactly 'false'
    }

    It 'supports label removal' {
        $env:EVENT_ACTION = 'unlabeled'
        $env:PR_LABELS = '[]'
        & ([scriptblock]::Create($gate))
        $result = Get-Content -LiteralPath $env:GITHUB_OUTPUT -Raw | ConvertFrom-StringData
        $result.admitted | Should -BeExactly 'true'
        $result.required | Should -BeExactly 'false'
    }

    It 'keeps required tests requested if the required label is removed but the optional label remains' {
        $env:EVENT_ACTION = 'unlabeled'
        $env:PR_LABELS = '["PR: Run All E2E Tests"]'
        & ([scriptblock]::Create($gate))
        $result = Get-Content -LiteralPath $env:GITHUB_OUTPUT -Raw | ConvertFrom-StringData
        $result.required | Should -BeExactly 'true'
        $result.optional | Should -BeExactly 'true'
    }

    It 'uses the manual deployment override to select both sets or neither' -ForEach @(
        @{ Deployment = 'true'; Expected = 'true' }
        @{ Deployment = 'false'; Expected = 'false' }
    ) {
        $env:EVENT_NAME = 'workflow_dispatch'
        $env:DEPLOYMENT_VALIDATION = $Deployment
        & ([scriptblock]::Create($gate))
        $result = Get-Content -LiteralPath $env:GITHUB_OUTPUT -Raw | ConvertFrom-StringData
        $result.required | Should -BeExactly $Expected
        $result.optional | Should -BeExactly $Expected
        $result.deployment | Should -BeExactly $Expected
    }
}
