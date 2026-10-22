#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    Import-Module (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    Import-Module -FullyQualifiedName @{ ModuleName = 'powershell-yaml'; RequiredVersion = '0.4.12' }
    $script:pwsh = (Get-Process -Id $PID).Path
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: Bicep isolated workflow bootstrap' -Tag Component {
    BeforeEach {
        $script:fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:support = Join-Path $script:fixture 'tools'
        $script:caller = Join-Path $script:fixture 'caller'
        $manifest = Import-PowerShellDataFile -Path (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1')
        $packageRoot = Join-Path $script:fixture 'published-modules'
        $publishedVersion = [version]'99.0.0'
        $publishedPackage = Join-Path $packageRoot 'Avm.Authoring' $publishedVersion
        $null = New-Item -ItemType Directory -Path $publishedPackage -Force
        Copy-Item -Path (Join-Path $script:repoRoot 'src' 'Avm.Authoring' '*') -Destination $publishedPackage -Recurse
        $manifestPath = Join-Path $publishedPackage 'Avm.Authoring.psd1'
        $manifestText = [IO.File]::ReadAllText($manifestPath)
        $manifestText = [regex]::Replace($manifestText, "(?m)^(\s*ModuleVersion\s*=\s*)'[^']+'", "`${1}'$publishedVersion'")
        [IO.File]::WriteAllText($manifestPath, $manifestText, [Text.UTF8Encoding]::new($false))
        foreach ($relative in @('.github/actions', 'scripts/bicep-workflows', 'repository-management/shared')) {
            $destination = Join-Path $script:support $relative
            $null = New-Item -ItemType Directory -Path (Split-Path $destination) -Force
            Copy-Item -LiteralPath (Join-Path $script:repoRoot $relative) -Destination $destination -Recurse
        }
        $script:modulePath = 'avm/res/mock/widget'
        $test = Join-Path $script:caller $script:modulePath 'tests' 'e2e' 'defaults'
        $null = New-Item -ItemType Directory -Path $test -Force
        [IO.File]::WriteAllText((Join-Path $test 'main.test.bicep'), '')
        [IO.File]::WriteAllText((Join-Path $test '.e2eignore'), '')
        [IO.File]::WriteAllText((Join-Path $script:caller 'workflow.yml'), '')
        $script:outputPath = Join-Path $script:fixture 'outputs'
        $script:environment = @{
            PSModulePath = $packageRoot + [IO.Path]::PathSeparator + (Join-Path $PSHOME 'Modules')
            GITHUB_WORKSPACE = $script:caller
            GITHUB_OUTPUT = $script:outputPath
            MODULE_PATH = $script:modulePath
        }
    }

    It 'executes the copied <Action> with no caller utilities or source runtime' -ForEach @(
        @{ Action = 'bicep-workflow-input'; Keys = @('workflowInput') }
        @{ Action = 'bicep-module-test-files'; Keys = @('moduleTestFilePaths', 'psRuleModuleTestFilePaths') }
        @{ Action = 'bicep-module-identity'; Keys = @('clientId', 'identityKey', 'moduleRoot', 'tenantId') }
        @{ Action = 'bicep-subscription-selection'; Keys = @('deploymentMatrix', 'sharedScope') }
    ) {
        $actionPath = Join-Path $script:support '.github' 'actions' $Action
        $definition = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $actionPath 'action.yml') -Raw)
        $script:environment.AVM_ACTION_PATH = $actionPath
        $script:environment.GITHUB_EVENT_NAME = 'workflow_dispatch'
        $script:environment.WORKFLOW_PATH = 'workflow.yml'
        $script:environment.EVENT_INPUTS = '{"removeDeployment":false,"customLocation":"2026-10-17T11:22:33.1234567+05:30"}'
        $script:environment.PSRULE_FILTER = '(defaults|waf-aligned)'
        $script:environment.VALIDATE_MODULE_CLIENT_IDS = '{"avm/res/mock/widget":"10000000-0000-4000-8000-000000000006"}'
        $script:environment.VALIDATE_TENANT_ID = '10000000-0000-4000-8000-000000000001'
        $script:environment.MODULE_TEST_FILES = '[]'
        $script:environment.GITHUB_RUN_ID = '1'
        $script:environment.GITHUB_RUN_ATTEMPT = '1'
        $script:environment.DISPLAY_SUBSCRIPTION_NAMES = 'false'
        $scriptPath = Join-Path $script:fixture 'action.ps1'
        [IO.File]::WriteAllText($scriptPath, $definition.runs.steps[0].run)
        $result = InModuleScope Avm.Authoring -Parameters @{
            Executable = $script:pwsh; Script = $scriptPath; Environment = $script:environment
        } {
            param($Executable, $Script, $Environment)
            Invoke-AvmProcess -FilePath $Executable -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $Script) `
                -EnvVars $Environment
        }
        $result.ExitCode | Should -Be 0
        $outputs = Get-Content -LiteralPath $script:outputPath -Raw | ConvertFrom-StringData
        @($outputs.Keys | Sort-Object) | Should -Be $Keys
        switch ($Action) {
            'bicep-workflow-input' {
                $document = [Text.Json.JsonDocument]::Parse($outputs.workflowInput)
                try {
                    $document.RootElement.GetProperty('removeDeployment').GetString() | Should -BeExactly 'false'
                    $document.RootElement.GetProperty('customLocation').GetString() |
                        Should -BeExactly '2026-10-17T11:22:33.1234567+05:30'
                }
                finally { $document.Dispose() }
            }
            'bicep-module-test-files' {
                $files = ConvertFrom-Json -InputObject $outputs.moduleTestFilePaths -NoEnumerate
                $files | Should -HaveCount 1
                $files[0].e2eIgnore | Should -BeTrue
                $files[0].path | Should -BeExactly 'tests/e2e/defaults/main.test.bicep'
            }
            'bicep-module-identity' {
                $outputs.moduleRoot | Should -BeExactly $script:modulePath
                $outputs.clientId | Should -BeExactly '10000000-0000-4000-8000-000000000006'
            }
            'bicep-subscription-selection' {
                $outputs.deploymentMatrix | Should -BeExactly '[]'
                $outputs.sharedScope | Should -BeExactly 'false'
            }
        }
        Test-Path -LiteralPath (Join-Path $script:support 'src') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:caller 'utilities') | Should -BeFalse
    }

    It 'emits no partial output from an isolated action with <Failure>' -ForEach @(
        @{ Failure = 'nonobject dispatch input'; Action = 'bicep-workflow-input' }
        @{ Failure = 'missing module'; Action = 'bicep-module-test-files' }
        @{ Failure = 'invalid mapping'; Action = 'bicep-module-identity' }
        @{ Failure = 'missing shared support'; Action = 'bicep-module-identity' }
    ) {
        $actionPath = Join-Path $script:support '.github' 'actions' $Action
        $definition = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $actionPath 'action.yml') -Raw)
        $script:environment.AVM_ACTION_PATH = $actionPath
        $script:environment.GITHUB_EVENT_NAME = 'workflow_dispatch'
        $script:environment.WORKFLOW_PATH = 'workflow.yml'
        $script:environment.EVENT_INPUTS = '["not-an-object"]'
        $script:environment.PSRULE_FILTER = '(defaults|waf-aligned)'
        $script:environment.VALIDATE_MODULE_CLIENT_IDS = '{}'
        $script:environment.VALIDATE_TENANT_ID = '10000000-0000-4000-8000-000000000001'
        if ($Failure -eq 'missing module') { $script:environment.MODULE_PATH = 'avm/res/mock/absent' }
        if ($Failure -eq 'missing shared support') {
            Remove-Item -LiteralPath (Join-Path $script:support 'repository-management' 'shared' 'GroupSettings.ps1')
        }
        $scriptPath = Join-Path $script:fixture 'invalid-action.ps1'
        [IO.File]::WriteAllText($scriptPath, $definition.runs.steps[0].run)
        $result = InModuleScope Avm.Authoring -Parameters @{
            Executable = $script:pwsh; Script = $scriptPath; Environment = $script:environment
        } {
            param($Executable, $Script, $Environment)
            Invoke-AvmProcess -FilePath $Executable -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $Script) `
                -EnvVars $Environment -IgnoreExitCode
        }
        $result.ExitCode | Should -Not -Be 0
        Test-Path -LiteralPath $script:outputPath | Should -BeFalse
    }

    It 'executes the fork static bootstrap and packaged validation with empty configuration and no protected prerequisites' {
        . (Join-Path $script:repoRoot 'scripts' 'bicep-workflows' 'Validation.ps1')
        $workflow = ConvertFrom-Yaml (Get-Content -LiteralPath (
                Join-Path $script:repoRoot '.github' 'workflows' 'bicep-module-static.yml') -Raw)
        $action = ConvertFrom-Yaml (Get-Content -LiteralPath (
                Join-Path $script:repoRoot '.github' 'actions' 'bicep-validation' 'action.yml') -Raw)
        $saved = @{}
        $values = @{
            GITHUB_WORKSPACE = $script:caller
            GITHUB_OUTPUT = $script:outputPath
            GITHUB_ENV = Join-Path $script:fixture 'environment'
            AVM_ACTION_PATH = Join-Path $script:support '.github' 'actions' 'bicep-validation'
            OPERATION = 'Static'
            MODULE_PATH = $script:modulePath
            EXAMPLE = ''
            BASELINE = ''
            RUNNER_TEMP = Join-Path $script:fixture 'temp'
        }
        $staticJob = $workflow.jobs['job_module_static_validation']
        $workflowEnvironment = if ($staticJob -is [Collections.IDictionary] -and $staticJob.Contains('env')) {
            $staticJob['env']
        }
        else {
            @{}
        }
        foreach ($name in $workflowEnvironment.Keys) {
            $values[$name] = $workflowEnvironment[$name]
        }
        foreach ($name in $values.Keys) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $values[$name])
        }
        try {
            Mock Install-AvmWorkflowModule {}
            Mock Import-AvmWorkflowPackage {}
            Mock Install-AvmTool {}
            Mock Get-Module { Microsoft.PowerShell.Core\Get-Module @PesterBoundParameters }
            Mock Get-Module {
                [pscustomobject]@{
                    Version = [version]'0.30.0'
                    PrivateData = @{ AvmCapabilities = @{ BicepPackagedCompliance = 1 } }
                }
            } -ParameterFilter { $Name -eq 'Avm.Authoring' }
            Mock Invoke-AvmTestUnit {
                $env:AVM_CI_VARIABLES | Should -BeExactly '{}'
                $env:AVM_CI_SECRETS | Should -BeExactly '{}'
                [pscustomobject]@{
                    Status = 'pass'; RunsTotal = 3; RunsPassed = 3; RunsFailed = 0
                    RunsSkipped = 0; RunsFiltered = 0; Issues = @()
                }
            }
            Mock Invoke-AvmCheckPolicy { throw 'Policy must not run in the public-data-only static tier.' }
            Mock Select-AvmTestSubscription { throw 'Static validation must not select a subscription.' }
            Mock Get-AvmWorkflowAuthentication { throw 'Static validation must not resolve an identity.' }
            Mock Invoke-AvmTestE2e { throw 'Static validation must not deploy.' }
            foreach ($step in $action.runs.steps | Where-Object { $_.Contains('run') }) {
                $tokens = $null
                $errors = $null
                $ast = [Management.Automation.Language.Parser]::ParseInput($step.run, [ref]$tokens, [ref]$errors)
                $errors | Should -BeNullOrEmpty
                $body = ($ast.EndBlock.Statements | Where-Object {
                        $_.Extent.Text -notmatch '^\.\s+\(Join-Path'
                    } | ForEach-Object { $_.Extent.Text }) -join "`n"
                . ([scriptblock]::Create($body))
            }
            Should -Invoke Invoke-AvmTestUnit -Exactly 1 -ParameterFilter {
                $Ecosystem -ceq 'bicep' -and $Recurse -and $IncludeCompliance -and $SkipModuleVersionCheck
            }
            Should -Invoke Install-AvmWorkflowModule -Exactly 1 -ParameterFilter { $Name -eq 'Avm.Authoring' }
            Should -Invoke Install-AvmWorkflowModule -Exactly 0 -ParameterFilter { $Name -like 'Az*' }
            Should -Invoke Invoke-AvmCheckPolicy -Exactly 0
            Should -Invoke Select-AvmTestSubscription -Exactly 0
            Should -Invoke Get-AvmWorkflowAuthentication -Exactly 0
            Should -Invoke Invoke-AvmTestE2e -Exactly 0
            $result = Get-Content -LiteralPath (Join-Path $env:RUNNER_TEMP 'avm-bicep-results' 'static.json') -Raw |
                ConvertFrom-Json
            $result.Status | Should -BeExactly 'pass'
            $result.RunsTotal | Should -Be 3
        }
        finally {
            foreach ($name in $saved.Keys) {
                $value = $saved[$name]
                [Environment]::SetEnvironmentVariable($name, $(if ($null -eq $value) { [NullString]::Value } else { $value }))
            }
        }
    }

    It 'imports the newest installed package instead of retaining an older import' {
        $moduleRoot = Join-Path $script:fixture 'installed' 'Avm.Authoring'
        foreach ($version in @('1.2.3', '9.9.9')) {
            $directory = Join-Path $moduleRoot $version
            $null = New-Item -ItemType Directory -Path $directory -Force
            [IO.File]::WriteAllText((Join-Path $directory 'Avm.Authoring.psd1'),
                "@{ RootModule = 'Avm.Authoring.psm1'; ModuleVersion = '$version'; FunctionsToExport = @('Get-FixtureRelease') }")
            [IO.File]::WriteAllText((Join-Path $directory 'Avm.Authoring.psm1'),
                "function Get-FixtureRelease { '$version' }")
        }
        $callerSource = Join-Path $script:caller '.avm-tools' 'src' 'Avm.Authoring'
        $null = New-Item -ItemType Directory -Path $callerSource -Force
        [IO.File]::WriteAllText((Join-Path $callerSource 'Avm.Authoring.psd1'),
            "@{ RootModule = 'Avm.Authoring.psm1'; ModuleVersion = '1.2.3' }")
        [IO.File]::WriteAllText((Join-Path $callerSource 'Avm.Authoring.psm1'), "throw 'Caller source must never load.'")
        $script:environment.PSModulePath = (Split-Path $moduleRoot) + [IO.Path]::PathSeparator + (Join-Path $PSHOME 'Modules')
        $scriptPath = Join-Path $script:fixture 'import.ps1'
        $commonPath = (Join-Path $script:support 'scripts' 'bicep-workflows' 'Common.ps1').Replace("'", "''")
        [IO.File]::WriteAllText($scriptPath, @"
. '$commonPath'
Import-Module -FullyQualifiedName @{ ModuleName = 'Avm.Authoring'; RequiredVersion = '1.2.3' }
Import-AvmWorkflowPackage
Get-FixtureRelease
"@)
        $result = InModuleScope Avm.Authoring -Parameters @{
            Executable = $script:pwsh; Script = $scriptPath; Environment = $script:environment
        } {
            param($Executable, $Script, $Environment)
            Invoke-AvmProcess -FilePath $Executable -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $Script) `
                -EnvVars $Environment -IgnoreExitCode
        }
        $result.ExitCode | Should -Be 0 -Because $result.StdErr
        $result.StdOut.Trim() | Should -BeExactly '9.9.9'
        $result.StdErr | Should -Not -Match 'Caller source must never load'
    }
}
