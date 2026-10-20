#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Integration: packaged Bicep policy' -Tag Integration {
    BeforeAll {
        $script:savedEnvironment = @{}
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        $manifest = Join-Path $repoRoot 'out' 'Avm.Authoring' 'Avm.Authoring.psd1'
        if (-not (Test-Path -LiteralPath $manifest)) {
            throw 'Run .\build.ps1 build before this installed-package acceptance test.'
        }
        $script:package = Join-Path $TestDrive 'installed' 'Avm.Authoring'
        $null = New-Item -ItemType Directory -Path (Split-Path $script:package) -Force
        $sourceRoot = Join-Path $repoRoot 'src' 'Avm.Authoring'
        $sourceFiles = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force)
        $expectedEntries = @($sourceFiles | ForEach-Object {
                'Avm.Authoring/' + [System.IO.Path]::GetRelativePath($sourceRoot, $_.FullName).Replace('\', '/')
            })
        $archivePath = Join-Path $TestDrive 'Avm.Authoring-local-unsigned.zip'
        Compress-Archive -LiteralPath (Split-Path $manifest) -DestinationPath $archivePath
        $archive = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
        try {
            $entries = @($archive.Entries | Where-Object { $_.Name })
            $entries.Count | Should -Be $expectedEntries.Count
            @(Compare-Object -ReferenceObject $expectedEntries -DifferenceObject @($entries.FullName) -CaseSensitive) |
                Should -HaveCount 0
            @($entries | Where-Object { $_.FullName -cmatch '^Avm[.]Authoring/(?:[.]git|tests|out|test-results)/' }) |
                Should -HaveCount 0
        }
        finally {
            $archive.Dispose()
        }
        Expand-Archive -LiteralPath $archivePath -DestinationPath (Split-Path $script:package)
        foreach ($file in $sourceFiles) {
            $relative = [System.IO.Path]::GetRelativePath($sourceRoot, $file.FullName)
            (Get-FileHash -LiteralPath (Join-Path $script:package $relative)).Hash |
                Should -BeExactly (Get-FileHash -LiteralPath $file.FullName).Hash
        }
        $rules = @(Get-ChildItem -LiteralPath (Join-Path $script:package 'Resources' 'bicep' 'psrule' 'rules') -File)
        $rules | Should -HaveCount 8
        @($rules | Where-Object { $_.Name -cnotmatch '\.Rule\.yaml$' }) | Should -HaveCount 0
        Import-Module (Join-Path $script:package 'Avm.Authoring.psd1') -Force
        . (Join-Path $repoRoot 'scripts' 'bicep-workflows' 'Validation.ps1')
        $script:fixture = Join-Path $repoRoot 'tests' 'fixtures' 'modules' 'bicep-storage'
        foreach ($name in @('TEST_SUBSCRIPTION_IDS', 'VALIDATE_SUBSCRIPTION_IDS', 'VALIDATE_SUBSCRIPTION_ID',
                'VALIDATE_TENANT_ID', 'TOKEN_NAMEPREFIX', 'AVM_CI_VARIABLES', 'AVM_CI_SECRETS', 'GITHUB_STEP_SUMMARY')) {
            $script:savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, [NullString]::Value)
        }
        $env:TEST_SUBSCRIPTION_IDS = '[{"id":"11111111-1111-4111-8111-111111111111","name":"compile-only"}]'
        $env:VALIDATE_SUBSCRIPTION_ID = '11111111-1111-4111-8111-111111111111'
        $env:VALIDATE_TENANT_ID = '22222222-2222-4222-8222-222222222222'
        $env:TOKEN_NAMEPREFIX = 'avmpackage'
    }

    AfterAll {
        foreach ($name in $script:savedEnvironment.Keys) {
            $value = $script:savedEnvironment[$name]
            [Environment]::SetEnvironmentVariable($name, $(if ($null -eq $value) { [NullString]::Value } else { $value }))
        }
        Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $script:consumer = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $script:fixture -Destination $script:consumer -Recurse -Force
        $script:modulePath = Join-Path $script:consumer 'avm' 'res' 'storage' 'storage-account'
        InModuleScope Avm.Authoring -Parameters @{ ModulePath = $script:modulePath } {
            param($ModulePath)
            $tool = Resolve-AvmTool -Name bicep
            $null = Get-AvmBicepCompiledJson -SourcePath (
                Join-Path $ModulePath 'tests' 'e2e' 'defaults' 'main.test.bicep') -ToolPath $tool.Path
        }
    }

    It 'executes all packaged baselines in an independent repository without registry utilities' {
        Test-Path -LiteralPath (Join-Path $script:consumer 'utilities') | Should -BeFalse
        (Get-Module Avm.Authoring).ModuleBase | Should -BeExactly $script:package
        $metadata = Test-AvmModuleMetadata -Path $script:modulePath -Ecosystem bicep `
            -ModuleType resource -CheckSource -SkipModuleVersionCheck
        $metadata.Status | Should -Be 'pass' -Because (@($metadata.Issues | ForEach-Object Message) -join '; ')
        $configuration = InModuleScope Avm.Authoring {
            $null = Import-AvmBicepPolicyModule
            Get-AvmBicepPolicyConfiguration
        }
        $configuration.OptionPath | Should -BeLike "$script:package*"
        $configuration.RulePath | Should -BeLike "$script:package*"
        Split-Path -Leaf $configuration.RulePath | Should -BeExactly 'rules'
        $result = Invoke-AvmCheckPolicy -Path $script:modulePath -SkipModuleVersionCheck
        $result.Status | Should -Be 'pass' -Because (@($result.Issues | ForEach-Object Message) -join '; ')
        $result.TestsSelected | Should -Be 2
        $result.BaselinesExecuted | Should -Be 8
        @($result.Evaluations | Where-Object { $_.ProcessedRules -gt 0 }).Count | Should -Be 8
        $result.Evaluations.Baseline | Should -Contain 'CB.AVM.WAF.Security'
    }

    It 'rejects an independent canonical repository without a root reservation map' {
        Remove-Item -LiteralPath (Join-Path $script:consumer '.reserved-test-subscriptions.json') -Force
        $result = Invoke-AvmCheckPolicy -Path $script:modulePath -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.BaselinesExecuted | Should -Be 0
        @($result.Issues | Where-Object {
                $_.Code -eq 'avm.bicep.psrule-source' -and
                $_.Message -eq 'The root .reserved-test-subscriptions.json must be a regular file with exact casing.'
            }).Count | Should -Be 2
    }

    It 'runs the workflow policy selectors against the independent package and General pool' {
        $pool = $env:TEST_SUBSCRIPTION_IDS
        try {
            $env:TEST_SUBSCRIPTION_IDS = '[{"id":"33333333-3333-4333-8333-333333333333","name":"Reserved","tag":"Azure Local"},{"id":"11111111-1111-4111-8111-111111111111","name":"General"}]'
            $results = Join-Path $TestDrive 'workflow-policy'
            Invoke-AvmWorkflowPolicyValidation -Root $script:consumer -ModulePath 'avm/res/storage/storage-account' `
                -Example 'tests/e2e/defaults/main.test.bicep' -Baseline Azure.Default -ResultDirectory $results
            $result = Get-Content -LiteralPath (Join-Path $results 'policy.json') -Raw | ConvertFrom-Json
            $result.Status | Should -BeExactly 'pass'
            $result.TestsSelected | Should -Be 1
            $result.BaselinesExecuted | Should -Be 1
            $env:VALIDATE_SUBSCRIPTION_ID | Should -BeExactly '11111111-1111-4111-8111-111111111111'
        }
        finally { $env:TEST_SUBSCRIPTION_IDS = $pool }
    }

    It 'fails the workflow advisory policy leg when native General selection has no eligible subscription' {
        $pool = $env:TEST_SUBSCRIPTION_IDS
        try {
            $env:TEST_SUBSCRIPTION_IDS = '[{"id":"33333333-3333-4333-8333-333333333333","name":"Reserved","tag":"Azure Local"}]'
            $results = Join-Path $TestDrive 'rejected-workflow-policy'
            { Invoke-AvmWorkflowPolicyValidation -Root $script:consumer -ModulePath 'avm/res/storage/storage-account' `
                    -Example 'tests/e2e/defaults/main.test.bicep' -Baseline Azure.Default -ResultDirectory $results } |
                Should -Throw '*did not pass*'
            $result = Get-Content -LiteralPath (Join-Path $results 'policy.json') -Raw | ConvertFrom-Json
            $result.Status | Should -BeExactly 'fail'
            $result.BaselinesExecuted | Should -Be 0
            @($result.Issues | Where-Object Message -Like "*no 'General' subscriptions*").Count | Should -Be 1
            $env:VALIDATE_SUBSCRIPTION_ID | Should -BeExactly '11111111-1111-4111-8111-111111111111'
        }
        finally { $env:TEST_SUBSCRIPTION_IDS = $pool }
    }

    It 'rejects insecure storage with the actual packaged security baseline' {
        $sourcePath = Join-Path $script:modulePath 'main.bicep'
        $source = [System.IO.File]::ReadAllText($sourcePath).Replace(
            'param supportsHttpsTrafficOnly bool = true', 'param supportsHttpsTrafficOnly bool = false')
        [System.IO.File]::WriteAllText($sourcePath, $source, [System.Text.UTF8Encoding]::new($false))
        $result = Invoke-AvmCheckPolicy -Path $script:modulePath -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        @($result.Issues | Where-Object {
                $_.RuleName -eq 'Azure.Storage.SecureTransfer' -and
                $_.Baseline -eq 'CB.AVM.WAF.Security' -and $_.Severity -eq 'error'
            }).Count | Should -BeGreaterThan 0
        $result.BaselinesExecuted | Should -Be 8
    }

    It 'supplies the static principal default without changing required consumer parameters' {
        $sourcePath = Join-Path $script:modulePath 'tests' 'e2e' 'defaults' 'main.test.bicep'
        $source = [System.IO.File]::ReadAllText($sourcePath).Replace(
            'param resourceLocation string = deployment().location',
            "param resourceLocation string = deployment().location`nparam builtInServicePrincipalObjectId string").Replace(
            '  location: resourceLocation',
            "  location: resourceLocation`n  tags: {`n    principal: builtInServicePrincipalObjectId`n  }")
        [System.IO.File]::WriteAllText($sourcePath, $source, [System.Text.UTF8Encoding]::new($false))
        $result = Invoke-AvmCheckPolicy -Path $script:modulePath -SkipModuleVersionCheck
        $result.Status | Should -Be 'pass' -Because (@($result.Issues | ForEach-Object Message) -join '; ')
        $result.BaselinesExecuted | Should -Be 8
        @($result.Evaluations | Where-Object { $_.ProcessedRules -gt 0 }).Count | Should -Be 8
        [System.IO.File]::ReadAllText($sourcePath) | Should -BeExactly $source
        $source | Should -Not -Match '00000000-0000-4000-8000-000000000001'

        $optionPath = Join-Path $script:package 'Resources' 'bicep' 'psrule' 'ps-rule.yaml'
        $original = [System.IO.File]::ReadAllText($optionPath)
        $withoutDefault = $original -replace '(?m)^  AZURE_PARAMETER_DEFAULTS:\r?\n    builtInServicePrincipalObjectId: "[^"]+"\r?\n', ''
        $withoutDefault | Should -Not -BeExactly $original
        try {
            [System.IO.File]::WriteAllText($optionPath, $withoutDefault, [System.Text.UTF8Encoding]::new($false))
            $missing = Invoke-AvmCheckPolicy -Path $script:modulePath -SkipModuleVersionCheck
            $missing.Status | Should -Be 'fail'
            $missing.BaselinesExecuted | Should -BeLessThan 8
        }
        finally {
            [System.IO.File]::WriteAllText($optionPath, $original, [System.Text.UTF8Encoding]::new($false))
        }
    }
}
