#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module -FullyQualifiedName @{ ModuleName = 'powershell-yaml'; RequiredVersion = '0.4.12' }
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $workflow = ConvertFrom-Yaml (Get-Content -Raw (Join-Path $root '.github' 'workflows' 'authoring-bootstrap.yml'))
    $script:validate = [scriptblock]::Create(($workflow.jobs.bootstrap.steps | Where-Object name -EQ 'Validate selection').run)
}

Describe 'Authoring bootstrap selection' {
    BeforeEach {
        $script:saved = @{}
        foreach ($name in @('SOURCE', 'REF', 'LEGACY_VERSION', 'EVENT_NAME', 'AVM_OFFLINE')) {
            $script:saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, [NullString]::Value, 'Process')
        }

        $env:SOURCE = 'gallery'
        $env:EVENT_NAME = 'workflow_dispatch'
    }

    AfterEach {
        foreach ($name in $script:saved.Keys) {
            $value = if ($null -eq $script:saved[$name]) { [NullString]::Value } else { $script:saved[$name] }
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
    }

    It 'accepts <Source> with ref <Ref>' -ForEach @(
        @{ Source = 'gallery'; Ref = '' }
        @{ Source = 'gallery'; Ref = '0.35.0' }
        @{ Source = 'repo'; Ref = '' }
        @{ Source = 'repo'; Ref = 'feature/test' }
        @{ Source = 'repo'; Ref = 'v0.35.0' }
        @{ Source = 'repo'; Ref = 'faf10e96bc16002170addd1bcfe91b78bb897c02' }
    ) {
        $env:SOURCE = $Source
        $env:REF = $Ref
        { & $script:validate } | Should -Not -Throw
    }

    It 'rejects invalid source and Gallery version without falling back' {
        $env:SOURCE = 'other'
        { & $script:validate } | Should -Throw '*authoringSource must be gallery or repo*'
        $env:SOURCE = 'gallery'
        $env:REF = '[0.35.0,1.0.0)'
        { & $script:validate } | Should -Throw '*exact stable version*'
    }

    It 'rejects conflicting legacy version and the new selection' {
        $env:LEGACY_VERSION = '[0.30.0,1.0.0)'
        $env:REF = '0.35.0'
        { & $script:validate } | Should -Throw '*cannot be combined*'
        $env:REF = ''
        $env:SOURCE = 'repo'
        { & $script:validate } | Should -Throw '*cannot be combined*'
        $env:SOURCE = 'gallery'
        { & $script:validate } | Should -Not -Throw
    }

    It 'keeps automatic events on Gallery without new overrides' {
        $env:EVENT_NAME = 'pull_request'
        { & $script:validate } | Should -Not -Throw
        $env:SOURCE = 'repo'
        { & $script:validate } | Should -Throw '*require manual dispatch*'
        $env:SOURCE = 'gallery'
        $env:REF = '0.35.0'
        { & $script:validate } | Should -Throw '*require manual dispatch*'
    }

    It 'fails offline before bootstrap' {
        $env:AVM_OFFLINE = '1'
        { & $script:validate } | Should -Throw '*AVM_OFFLINE=1*'
    }
}

Describe 'Prepared Bicep runtime selection' {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
        $scripts = @(
            foreach ($name in @('bicep-module-runtime', 'bicep-module-runtime-e2e', 'bicep-module-runtime-deployment', 'bicep-module-runtime-release')) {
                $workflow = ConvertFrom-Yaml (Get-Content -Raw (Join-Path $root '.github' 'workflows' "$name.yml"))
                foreach ($job in $workflow.jobs.Values) {
                    if (-not $job.Contains('steps')) { continue }
                    foreach ($step in $job.steps | Where-Object name -EQ 'Select prepared authoring runtime') {
                        $step.run
                    }
                }
            }
        )
        if ($scripts.Count -ne 6) {
            throw 'Bicep runtime jobs must select the prepared artifact.'
        }
        foreach ($script in $scripts) {
            if ($script -notmatch 'avm-authoring-discovery' -or
                $script -notmatch 'only discoverable Avm\.Authoring module' -or
                $script -notmatch 'Prepared Avm\.Authoring discovery package does not match' -or
                $script -notmatch 'Import-Module -Name Avm\.Authoring -Global -PassThru -ErrorAction Stop') {
                throw 'Bicep runtime jobs must consistently bind the prepared artifact.'
            }
        }
        $script:selectRuntime = [scriptblock]::Create($scripts[0])
    }

    BeforeEach {
        $script:savedTemp = [Environment]::GetEnvironmentVariable('RUNNER_TEMP', 'Process')
        $script:savedEnv = [Environment]::GetEnvironmentVariable('GITHUB_ENV', 'Process')
        $script:savedModulePath = [Environment]::GetEnvironmentVariable('PSModulePath', 'Process')
        $env:RUNNER_TEMP = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $env:GITHUB_ENV = Join-Path $env:RUNNER_TEMP 'environment'
        $env:PSModulePath = Join-Path $PSHOME 'Modules'
        New-Item -ItemType Directory -Path $env:RUNNER_TEMP -Force | Out-Null
    }

    AfterEach {
        $discoveryModule = Join-Path $env:RUNNER_TEMP 'avm-authoring-discovery' 'Avm.Authoring'
        foreach ($module in @(Get-Module -Name Avm.Authoring | Where-Object {
                    [string]::Equals($_.ModuleBase, $discoveryModule,
                        $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }))
                })) {
            Remove-Module -ModuleInfo $module -Force
        }
        [Environment]::SetEnvironmentVariable('RUNNER_TEMP', ($null -eq $script:savedTemp ? [NullString]::Value : $script:savedTemp), 'Process')
        [Environment]::SetEnvironmentVariable('GITHUB_ENV', ($null -eq $script:savedEnv ? [NullString]::Value : $script:savedEnv), 'Process')
        [Environment]::SetEnvironmentVariable('PSModulePath', ($null -eq $script:savedModulePath ? [NullString]::Value : $script:savedModulePath), 'Process')
    }

    It 'selects only the downloaded manifest for subsequent steps' {
        $directory = Join-Path $env:RUNNER_TEMP 'avm-authoring'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $manifest = Join-Path $directory 'Avm.Authoring.psd1'
        Set-Content -LiteralPath $manifest -Value "@{ ModuleVersion = '0.21.0'; RootModule = 'Avm.Authoring.psm1' }"
        Set-Content -LiteralPath (Join-Path $directory 'Avm.Authoring.psm1') -Value ''
        & $script:selectRuntime
        @(Get-Module -Name Avm.Authoring | Where-Object {
                $_.ModuleBase -eq (Join-Path $env:RUNNER_TEMP 'avm-authoring-discovery' 'Avm.Authoring')
            }) | Should -HaveCount 1
        $environment = Get-Content -LiteralPath $env:GITHUB_ENV
        @($environment | Where-Object { $_ -like 'AVM_AUTHORING_MODULE=*' }) |
            Should -Match '^AVM_AUTHORING_MODULE=.*avm-authoring-discovery.*Avm\.Authoring\.psd1$'
    }

    It 'fails instead of selecting Gallery when the downloaded manifest is missing' {
        { & $script:selectRuntime } | Should -Throw '*manifest is missing*'
        Test-Path -LiteralPath $env:GITHUB_ENV | Should -BeFalse
    }
}
