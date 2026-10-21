#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    Import-Module (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    Import-Module -FullyQualifiedName @{ ModuleName = 'powershell-yaml'; RequiredVersion = '0.4.12' }
    . (Join-Path $script:repoRoot 'scripts' 'bicep-workflows' 'Discovery.ps1')
    $action = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $script:repoRoot '.github' 'actions' 'bicep-workflow-matrix' 'action.yml') -Raw)
    $script:matrixStep = $action.runs.steps[0].run
    $script:matrixRoot = Join-Path $TestDrive 'caller'
    $script:modulePath = 'avm/res/mock/widget'
    $script:unrelatedPath = 'avm/res/mock/unrelated'
    $script:savedEnvironment = @{}
    foreach ($name in @(
        'AVM_ACTION_PATH', 'BASE_COMMIT', 'TARGET_COMMIT', 'PULL_REQUEST_HEAD_COMMIT',
            'EVENT_NAME', 'MODULE_PATHS', 'CREATE_RELEASE_TAG', 'PUBLISH_ONLY', 'CUSTOM_LOCATION',
            'STATIC_VALIDATION', 'DEPLOYMENT_VALIDATION', 'REMOVE_DEPLOYMENT', 'GITHUB_WORKSPACE', 'GITHUB_OUTPUT'
        )) {
        $script:savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }

    function Invoke-AvmMatrixTestGit {
        param([string[]] $Arguments)
        $result = Invoke-AvmWorkflowGitRead -Root $script:matrixRoot -Arguments (
            @('-c', 'user.name=WorkflowFixture', '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false') + $Arguments
        )
        return $result.StdOut.Trim()
    }

    function New-AvmMatrixTestCommit {
        param([string] $Message)
        $null = Invoke-AvmMatrixTestGit -Arguments @('add', '--all')
        $null = Invoke-AvmMatrixTestGit -Arguments @('commit', '--quiet', '-m', $Message)
        return Invoke-AvmMatrixTestGit -Arguments @('rev-parse', 'HEAD')
    }

    function Set-AvmMatrixTestTarget {
        param([string] $Commit)
        $null = Invoke-AvmMatrixTestGit -Arguments @('switch', '--quiet', '--detach', $Commit)
        $env:TARGET_COMMIT = $Commit
    }

    function Invoke-AvmMatrixTestStep {
        . ([scriptblock]::Create($script:matrixStep))
        $outputs = @{}
        foreach ($line in Get-Content -LiteralPath $env:GITHUB_OUTPUT) {
            $entry = $line.Split('=', 2)
            $outputs[$entry[0]] = $entry[1]
        }
        return $outputs
    }

    foreach ($module in @($script:modulePath, $script:unrelatedPath)) {
        $folder = Join-Path $script:matrixRoot $module 'tests' 'e2e' 'defaults'
        $null = New-Item -ItemType Directory -Path $folder -Force
        [IO.File]::WriteAllText((Join-Path $script:matrixRoot $module 'main.bicep'), "metadata name = 'fixture'")
        [IO.File]::WriteAllText((Join-Path $folder 'main.test.bicep'), '')
    }
    $null = Invoke-AvmMatrixTestGit -Arguments @('init', '--quiet', '--initial-branch=main')
    $null = Invoke-AvmMatrixTestGit -Arguments @('config', 'core.autocrlf', 'false')
    $script:originalBase = New-AvmMatrixTestCommit -Message base
    $null = Invoke-AvmMatrixTestGit -Arguments @('switch', '--quiet', '-c', 'feature')
    [IO.File]::WriteAllText((Join-Path $script:matrixRoot $script:modulePath 'metadata.json'), '{"name":"requested"}')
    $script:requestHead = New-AvmMatrixTestCommit -Message 'requested metadata'

    $null = Invoke-AvmMatrixTestGit -Arguments @('switch', '--quiet', 'main')
    [IO.File]::WriteAllText((Join-Path $script:matrixRoot $script:unrelatedPath 'metadata.json'), '{"name":"unrelated"}')
    $script:testedBase = New-AvmMatrixTestCommit -Message 'unrelated base metadata'
    $null = Invoke-AvmMatrixTestGit -Arguments @('switch', '--quiet', '-c', 'tested-merge')
    $null = Invoke-AvmMatrixTestGit -Arguments @('merge', '--quiet', '--no-ff', 'feature', '-m', 'tested merge')
    $script:testedMerge = Invoke-AvmMatrixTestGit -Arguments @('rev-parse', 'HEAD')

    $null = Invoke-AvmMatrixTestGit -Arguments @('switch', '--quiet', 'main')
    [IO.File]::WriteAllText((Join-Path $script:matrixRoot $script:unrelatedPath 'main.bicep'), "metadata name = 'updated'")
    $script:latestBase = New-AvmMatrixTestCommit -Message 'newer base'
    $null = Invoke-AvmMatrixTestGit -Arguments @('switch', '--quiet', 'feature')
    $null = Invoke-AvmMatrixTestGit -Arguments @('merge', '--quiet', '--no-ff', 'main', '-m', 'update feature from main')
    $script:updatedHead = Invoke-AvmMatrixTestGit -Arguments @('rev-parse', 'HEAD')
    $null = Invoke-AvmMatrixTestGit -Arguments @('switch', '--quiet', '-c', 'updated-merge', 'main')
    $null = Invoke-AvmMatrixTestGit -Arguments @('merge', '--quiet', '--no-ff', 'feature', '-m', 'updated tested merge')
    $script:updatedMerge = Invoke-AvmMatrixTestGit -Arguments @('rev-parse', 'HEAD')

    $null = Invoke-AvmMatrixTestGit -Arguments @('switch', '--quiet', '-c', 'readme', 'main')
    [IO.File]::WriteAllText((Join-Path $script:matrixRoot $script:modulePath 'README.md'), 'Documentation only.')
    $script:readmeHead = New-AvmMatrixTestCommit -Message 'readme change'
    $null = Invoke-AvmMatrixTestGit -Arguments @('switch', '--quiet', '-c', 'readme-merge', 'main')
    $null = Invoke-AvmMatrixTestGit -Arguments @('merge', '--quiet', '--no-ff', 'readme', '-m', 'readme tested merge')
    $script:readmeMerge = Invoke-AvmMatrixTestGit -Arguments @('rev-parse', 'HEAD')
    $null = Invoke-AvmMatrixTestGit -Arguments @('switch', '--quiet', '-c', 'octopus', 'main')
    $null = Invoke-AvmMatrixTestGit -Arguments @('merge', '--quiet', '--no-ff', 'feature', 'readme', '-m', 'unsupported topology')
    $script:octopusMerge = Invoke-AvmMatrixTestGit -Arguments @('rev-parse', 'HEAD')

    $script:supportRoot = Join-Path $TestDrive 'tools'
    $script:supportAction = Join-Path $script:supportRoot '.github' 'actions' 'bicep-workflow-matrix'
    $supportScripts = Join-Path $script:supportRoot 'scripts' 'bicep-workflows'
    $null = New-Item -ItemType Directory -Path $script:supportAction, $supportScripts -Force
    $discoveryPath = (Join-Path $script:repoRoot 'scripts' 'bicep-workflows' 'Discovery.ps1').Replace("'", "''")
    $bootstrapStub = @'
function Initialize-AvmWorkflow {
    [CmdletBinding(SupportsShouldProcess)]
    param([string] $Profile)
    if ($Profile -cne 'Package') {
        throw [InvalidOperationException]::new('Unexpected fixture package initialization.')
    }
}
'@
    [IO.File]::WriteAllText((Join-Path $supportScripts 'Discovery.ps1'), ". '$discoveryPath'`n$bootstrapStub")
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
    foreach ($name in $script:savedEnvironment.Keys) {
        $value = $script:savedEnvironment[$name]
        [Environment]::SetEnvironmentVariable($name, $(if ($null -eq $value) { [NullString]::Value } else { $value }))
    }
    $fixtureGitDir = Join-Path $script:matrixRoot '.git'
    if (Test-Path -LiteralPath $fixtureGitDir -PathType Container) {
        Get-ChildItem -LiteralPath $fixtureGitDir -File -Recurse -Force |
            ForEach-Object { $_.IsReadOnly = $false }
    }
}

Describe 'Component: Bicep workflow tested-merge matrix action' -Tag Component {
    BeforeEach {
        $env:AVM_ACTION_PATH = $script:supportAction
        $env:BASE_COMMIT = $script:originalBase
        $env:PULL_REQUEST_HEAD_COMMIT = $script:requestHead
        $env:EVENT_NAME = 'pull_request'
        $env:MODULE_PATHS = ''
        $env:CREATE_RELEASE_TAG = 'false'
        $env:PUBLISH_ONLY = 'false'
        $env:CUSTOM_LOCATION = ''
        $env:STATIC_VALIDATION = 'true'
        $env:DEPLOYMENT_VALIDATION = 'true'
        $env:REMOVE_DEPLOYMENT = 'true'
        $env:GITHUB_WORKSPACE = $script:matrixRoot
        $env:GITHUB_OUTPUT = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N')).outputs"
        Set-AvmMatrixTestTarget -Commit $script:testedMerge
        Mock Start-Sleep {}
    }

    It 'selects metadata-only pull request changes with deployment <Enabled>' -ForEach @(
        @{ Enabled = 'true' }
        @{ Enabled = 'false' }
    ) {
        $env:DEPLOYMENT_VALIDATION = $Enabled
        $outputs = Invoke-AvmMatrixTestStep
        $outputs.Count | Should -Be 6
        $outputs.baseCommit | Should -BeExactly $script:testedBase
        $outputs.targetCommit | Should -BeExactly $script:testedMerge
        @(($outputs.moduleMatrix | ConvertFrom-Json).include.modulePath) | Should -Be @($script:modulePath)
        ($outputs.workflowInput | ConvertFrom-Json).deploymentValidation | Should -BeExactly $Enabled
    }

    It 'ignores the <BaseState> event base and excludes unrelated base changes' -ForEach @(
        @{ BaseState = 'older' }
        @{ BaseState = 'matching' }
        @{ BaseState = 'newer' }
        @{ BaseState = 'zero' }
        @{ BaseState = 'unavailable' }
        @{ BaseState = 'empty' }
    ) {
        $env:BASE_COMMIT = switch ($BaseState) {
            older { $script:originalBase }
            matching { $script:testedBase }
            newer { $script:latestBase }
            zero { '0' * 40 }
            unavailable { 'f' * 40 }
            empty { '' }
        }
        $oldDiff = Invoke-AvmMatrixTestGit -Arguments @('diff', '--name-only', $script:originalBase, $script:testedMerge, '--', 'avm')
        $oldDiff | Should -Match 'unrelated/metadata.json'
        $outputs = Invoke-AvmMatrixTestStep
        $outputs.baseCommit | Should -BeExactly $script:testedBase
        $outputs.includeAllVersionedModules | Should -BeExactly 'false'
        @(($outputs.moduleMatrix | ConvertFrom-Json).include.modulePath) | Should -Be @($script:modulePath)
    }

    It 'accepts a pull request head that merged main without selecting its unrelated changes' {
        Set-AvmMatrixTestTarget -Commit $script:updatedMerge
        $env:PULL_REQUEST_HEAD_COMMIT = $script:updatedHead
        $outputs = Invoke-AvmMatrixTestStep
        $outputs.baseCommit | Should -BeExactly $script:latestBase
        $outputs.targetCommit | Should -BeExactly $script:updatedMerge
        @(($outputs.moduleMatrix | ConvertFrom-Json).include.modulePath) | Should -Be @($script:modulePath)
    }

    It 'returns an empty matrix for a README-only pull request despite unrelated base changes' {
        Set-AvmMatrixTestTarget -Commit $script:readmeMerge
        $env:PULL_REQUEST_HEAD_COMMIT = $script:readmeHead
        $outputs = Invoke-AvmMatrixTestStep
        $outputs.baseCommit | Should -BeExactly $script:latestBase
        $outputs.hasModules | Should -BeExactly 'false'
        $outputs.moduleMatrix | Should -BeExactly '{"include":[]}'
    }

    It 'preserves metadata-only push exclusion' {
        $env:EVENT_NAME = 'push'
        Set-AvmMatrixTestTarget -Commit $script:requestHead
        $outputs = Invoke-AvmMatrixTestStep
        $outputs.baseCommit | Should -BeExactly $script:originalBase
        $outputs.hasModules | Should -BeExactly 'false'
    }

    It 'preserves before-to-target source push selection' {
        $env:EVENT_NAME = 'push'
        $env:BASE_COMMIT = $script:testedBase
        Set-AvmMatrixTestTarget -Commit $script:latestBase
        $outputs = Invoke-AvmMatrixTestStep
        @(($outputs.moduleMatrix | ConvertFrom-Json).include.modulePath) | Should -Be @($script:unrelatedPath)
        ($outputs.workflowInput | ConvertFrom-Json).deploymentValidation | Should -BeExactly 'true'
    }

    It 'preserves the credential-free static-only push fallback for a <BaseState> base' -ForEach @(
        @{ BaseState = 'zero'; Value = '0' * 40 }
        @{ BaseState = 'unavailable'; Value = 'f' * 40 }
        @{ BaseState = 'empty'; Value = '' }
    ) {
        $env:EVENT_NAME = 'push'
        $env:BASE_COMMIT = $Value
        $outputs = Invoke-AvmMatrixTestStep
        $outputs.baseCommit | Should -BeNullOrEmpty
        $outputs.includeAllVersionedModules | Should -BeExactly 'true'
        @(($outputs.moduleMatrix | ConvertFrom-Json).include.modulePath) | Should -Be @($script:unrelatedPath, $script:modulePath)
        ($outputs.workflowInput | ConvertFrom-Json).deploymentValidation | Should -BeExactly 'false'
    }

    It 'rejects <History> without writing any matrix outputs' -ForEach @(
        @{ History = 'unavailable target'; Message = '*match targetCommit exactly*' }
        @{ History = 'non-merge target'; Message = '*exactly two parents*' }
        @{ History = 'root target'; Message = '*exactly two parents*' }
        @{ History = 'octopus target'; Message = '*exactly two parents*' }
        @{ History = 'mismatched head'; Message = '*second parent*pull request head*' }
        @{ History = 'missing head'; Message = '*pull request head*full SHA-1*' }
        @{ History = 'invalid head'; Message = '*pull request head*full SHA-1*' }
        @{ History = 'wrong checkout'; Message = '*match targetCommit exactly*' }
    ) {
        switch ($History) {
            'unavailable target' { $env:TARGET_COMMIT = 'f' * 40 }
            'non-merge target' { Set-AvmMatrixTestTarget -Commit $script:requestHead }
            'root target' { Set-AvmMatrixTestTarget -Commit $script:originalBase }
            'octopus target' { Set-AvmMatrixTestTarget -Commit $script:octopusMerge }
            'mismatched head' { $env:PULL_REQUEST_HEAD_COMMIT = $script:testedBase }
            'missing head' { $env:PULL_REQUEST_HEAD_COMMIT = '' }
            'invalid head' { $env:PULL_REQUEST_HEAD_COMMIT = '--all' }
            'wrong checkout' { $env:TARGET_COMMIT = $script:updatedMerge }
        }
        { Invoke-AvmMatrixTestStep } | Should -Throw $Message
        Test-Path -LiteralPath $env:GITHUB_OUTPUT | Should -BeFalse
    }

    It 'preserves explicit manual selections without inspecting non-merge pull request history' {
        $env:EVENT_NAME = 'workflow_dispatch'
        $env:PULL_REQUEST_HEAD_COMMIT = ''
        $env:MODULE_PATHS = "$script:modulePath,$script:unrelatedPath"
        $env:DEPLOYMENT_VALIDATION = 'false'
        $env:CUSTOM_LOCATION = 'eastus'
        Set-AvmMatrixTestTarget -Commit $script:requestHead
        $outputs = Invoke-AvmMatrixTestStep
        $outputs.baseCommit | Should -BeNullOrEmpty
        $outputs.includeAllVersionedModules | Should -BeExactly 'false'
        @(($outputs.moduleMatrix | ConvertFrom-Json).include.modulePath) | Should -Be @($script:unrelatedPath, $script:modulePath)
        ($outputs.workflowInput | ConvertFrom-Json).customLocation | Should -BeExactly 'eastus'
    }
}
