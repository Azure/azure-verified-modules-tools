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
        "`n[pscustomobject]@{ required = @(`$requiredModules); optional = @(`$optionalModules); errors = @(`$requiredErrors) }")
}

Describe 'Bicep PR scenario selection' {
    BeforeEach {
        $savedFork = [Environment]::GetEnvironmentVariable('FORK')
        $env:FORK = 'false'
        $outputs = [pscustomobject]@{
            WorkflowInput = @{ deploymentValidation = 'true' }
            ModuleMatrix = @{ Include = @(
                    [pscustomobject]@{
                        ModulePath = 'avm/res/example/widget'
                        TestFiles = @(
                            @{ path = 'tests/e2e/defaults/main.test.bicep'; name = 'defaults'; e2eIgnore = $false }
                            @{ path = 'tests/e2e/waf-aligned/main.test.bicep'; name = 'waf-aligned'; e2eIgnore = $false }
                            @{ path = 'tests/e2e/max/main.test.bicep'; name = 'max'; e2eIgnore = $false }
                        )
                        PolicyTestFiles = @()
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
        [Environment]::SetEnvironmentVariable('FORK', $savedFork)
    }

    It 'separates required and optional tests and exempts utility modules' {
        $result = & $selection
        $result.errors | Should -BeNullOrEmpty
        $result.required | Should -HaveCount 1
        $result.optional | Should -HaveCount 1
        @($result.required[0].moduleTestFilePaths | ConvertFrom-Json | ForEach-Object name) |
            Should -Be @('defaults', 'waf-aligned')
        @($result.optional[0].moduleTestFilePaths | ConvertFrom-Json | ForEach-Object name) |
            Should -Be @('max')
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
        $result.required | Should -HaveCount 1
        @($result.required[0].moduleTestFilePaths | ConvertFrom-Json | ForEach-Object name) |
            Should -Be @('defaults')
    }

    It 'warns and does not require E2E when both scenarios are missing' {
        $outputs.ModuleMatrix.Include[0].TestFiles = @($outputs.ModuleMatrix.Include[0].TestFiles |
                Where-Object name -EQ 'max')
        $records = @(& $selection 6>&1)
        @($records | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }) | Should -HaveCount 2
        $result = $records[-1]
        $result.errors | Should -BeNullOrEmpty
        $result.required | Should -BeNullOrEmpty
        $result.optional | Should -HaveCount 1
    }

    It 'reports existing ignored required scenarios as errors' {
        $outputs.ModuleMatrix.Include[0].TestFiles[1].e2eIgnore = $true
        $result = & $selection
        $result.errors | Should -Not -BeNullOrEmpty
        ($result.errors -join ' ') | Should -Match 'ignored.*waf-aligned'
        $result.required | Should -HaveCount 1
    }

    It 'warns for a missing parent scenario even when a child scenario exists' {
        $outputs.ModuleMatrix.Include[0].TestFiles[1].path = 'child/tests/e2e/waf-aligned/main.test.bicep'
        $records = @(& $selection 6>&1)
        @($records | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })[0].MessageData |
            Should -Match 'waf-aligned.*missing'
        $result = $records[-1]
        $result.errors | Should -BeNullOrEmpty
        @($result.required[0].moduleTestFilePaths | ConvertFrom-Json | ForEach-Object name) |
            Should -Be @('defaults', 'waf-aligned')
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

    It 'supports label removal and the manual deployment override' {
        $env:EVENT_ACTION = 'unlabeled'
        $env:PR_LABELS = '[]'
        & ([scriptblock]::Create($gate))
        $result = Get-Content -LiteralPath $env:GITHUB_OUTPUT -Raw | ConvertFrom-StringData
        $result.admitted | Should -BeExactly 'true'
        $result.required | Should -BeExactly 'false'
        $env:EVENT_NAME = 'workflow_dispatch'
        $env:DEPLOYMENT_VALIDATION = 'true'
        $env:GITHUB_OUTPUT = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        & ([scriptblock]::Create($gate))
        $result = Get-Content -LiteralPath $env:GITHUB_OUTPUT -Raw | ConvertFrom-StringData
        $result.required | Should -BeExactly 'true'
        $result.optional | Should -BeExactly 'true'
    }
}
