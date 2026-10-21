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
            PSModulePath = Join-Path $PSHOME 'Modules'
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
