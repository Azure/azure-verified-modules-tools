#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    Import-Module -FullyQualifiedName @{ ModuleName = 'powershell-yaml'; RequiredVersion = '0.4.12' }
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
    $emit = [scriptblock]::Create($initialize.Substring($start))
}

Describe 'Bicep PR scenario selection' {
    BeforeEach {
        $saved = @{}
        foreach ($name in @('FORK', 'REQUIRED', 'OPTIONAL', 'ARTIFACT', 'GITHUB_OUTPUT')) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $env:FORK = 'false'
        $env:REQUIRED = 'true'
        $env:OPTIONAL = 'true'
        $env:ARTIFACT = 'fixture-artifact'
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
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }

    It 'selects <Description> into one shared module entry' -ForEach @(
        @{ Description = 'no tests'; Required = 'false'; Optional = 'false'; Expected = @(); Route = 'none' }
        @{ Description = 'required tests'; Required = 'true'; Optional = 'false'; Expected = @('defaults', 'waf-aligned'); Route = 'native' }
        @{ Description = 'optional tests'; Required = 'false'; Optional = 'true'; Expected = @('max'); Route = 'native' }
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

    It 'warns about a missing scenario while requiring the existing one' {
        $outputs.ModuleMatrix.Include[0].TestFiles = @($outputs.ModuleMatrix.Include[0].TestFiles |
                Where-Object name -NE 'waf-aligned')
        $records = @(& $selection 6>&1)
        $warning = @($records | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })
        $result = $records[-1]
        $warning | Should -HaveCount 1
        $warning[0].MessageData | Should -Match '^::warning::.*waf-aligned.*missing'
        $result.errors | Should -BeNullOrEmpty
        $result.hasRequired | Should -BeTrue
        @($result.modules[0].moduleTestFilePaths | ConvertFrom-Json | ForEach-Object name) |
            Should -Be @('defaults', 'max')
    }

    It 'warns and does not require E2E when both scenarios are missing' {
        $outputs.ModuleMatrix.Include[0].TestFiles = @($outputs.ModuleMatrix.Include[0].TestFiles |
                Where-Object name -EQ 'max')
        $records = @(& $selection 6>&1)
        @($records | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }) | Should -HaveCount 2
        $result = $records[-1]
        $result.errors | Should -BeNullOrEmpty
        $result.hasRequired | Should -BeFalse
        $result.hasOptional | Should -BeTrue
        $result.modules[0].e2eRoute | Should -BeExactly 'native'
        @($result.modules[0].moduleTestFilePaths | ConvertFrom-Json | ForEach-Object name) | Should -Be @('max')
    }

    It 'reports existing ignored required scenarios as errors' {
        $outputs.ModuleMatrix.Include[0].TestFiles[1].e2eIgnore = $true
        $result = & $selection
        $result.errors | Should -Not -BeNullOrEmpty
        ($result.errors -join ' ') | Should -Match 'ignored.*waf-aligned'
        $result.hasRequired | Should -BeTrue
    }

    It 'warns for a missing parent scenario even when a child scenario exists' {
        $outputs.ModuleMatrix.Include[0].TestFiles[1].path = 'child/tests/e2e/waf-aligned/main.test.bicep'
        $records = @(& $selection 6>&1)
        @($records | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })[0].MessageData |
            Should -Match 'waf-aligned.*missing'
        $result = $records[-1]
        $result.errors | Should -BeNullOrEmpty
        @($result.modules[0].moduleTestFilePaths | ConvertFrom-Json | ForEach-Object name) |
            Should -Be @('defaults', 'waf-aligned', 'max')
    }

    It 'exempts utility modules from required checks but selects any matching tests' {
        $outputs.ModuleMatrix.Include = @($outputs.ModuleMatrix.Include[1])
        $outputs.ModuleMatrix.Include[0].TestFiles = @(
            @{ path = 'tests/e2e/defaults/main.test.bicep'; name = 'defaults'; e2eIgnore = $true }
        )
        $env:OPTIONAL = 'false'
        $records = @(& $selection 6>&1)
        @($records | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }) | Should -BeNullOrEmpty
        $result = $records[-1]
        $result.errors | Should -BeNullOrEmpty
        $result.hasRequired | Should -BeFalse
        $result.modules[0].e2eRoute | Should -BeExactly 'native'
        @($result.modules[0].moduleTestFilePaths | ConvertFrom-Json | ForEach-Object name) | Should -Be @('defaults')
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
                'PR_LABELS', 'DEPLOYMENT_VALIDATION', 'GITHUB_OUTPUT')) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $env:EVENT_NAME = 'pull_request'
        $env:REPOSITORY = 'Azure/bicep-registry-modules'
        $env:HEAD_REPOSITORY = $env:REPOSITORY
        $env:EVENT_ACTION = 'labeled'
        $env:EVENT_LABEL = 'PR: Run Optional E2E Tests'
        $env:DEPLOYMENT_VALIDATION = 'false'
        $env:GITHUB_OUTPUT = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }

    AfterEach {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }

    It 'routes each label independently' -ForEach @(
        @{ Labels = '[]'; Required = 'false'; Optional = 'false' }
        @{ Labels = '["PR: Run E2E Tests"]'; Required = 'true'; Optional = 'false' }
        @{ Labels = '["PR: Run Optional E2E Tests"]'; Required = 'false'; Optional = 'true' }
        @{ Labels = '["PR: Run E2E Tests","PR: Run Optional E2E Tests"]'; Required = 'true'; Optional = 'true' }
    ) {
        $env:PR_LABELS = $Labels
        & ([scriptblock]::Create($gate))
        $result = Get-Content -LiteralPath $env:GITHUB_OUTPUT -Raw | ConvertFrom-StringData
        $result.admitted | Should -BeExactly 'true'
        $result.required | Should -BeExactly $Required
        $result.optional | Should -BeExactly $Optional
    }

    It 'does not deploy from forks even when both labels are present' {
        $env:HEAD_REPOSITORY = 'fork/repo'
        $env:PR_LABELS = '["PR: Run E2E Tests","PR: Run Optional E2E Tests"]'
        & ([scriptblock]::Create($gate))
        $result = Get-Content -LiteralPath $env:GITHUB_OUTPUT -Raw | ConvertFrom-StringData
        $result.required | Should -BeExactly 'false'
        $result.optional | Should -BeExactly 'false'
    }

    It 'supports label removal' {
        $env:EVENT_ACTION = 'unlabeled'
        $env:PR_LABELS = '[]'
        & ([scriptblock]::Create($gate))
        $result = Get-Content -LiteralPath $env:GITHUB_OUTPUT -Raw | ConvertFrom-StringData
        $result.admitted | Should -BeExactly 'true'
        $result.required | Should -BeExactly 'false'
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
