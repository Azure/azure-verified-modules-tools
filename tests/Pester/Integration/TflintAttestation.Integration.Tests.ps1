#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Integration: TFLint AVM plugin attestation' -Tag 'Integration' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        $script:moduleManifest = Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
        $script:configPath = Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Resources' 'tflint' 'avm.tflint.hcl'
        $script:originalAvmHome = $env:AVM_HOME
        $env:AVM_HOME = Join-Path $TestDrive 'avm-home'
        Import-Module $script:moduleManifest -Force
    }

    AfterAll {
        if ($null -eq $script:originalAvmHome) {
            Remove-Item Env:\AVM_HOME -ErrorAction SilentlyContinue
        }
        else {
            $env:AVM_HOME = $script:originalAvmHome
        }
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

    It 'installs and executes the pinned AVM ruleset with artifact attestation' -Skip:((Test-Path Env:\AVM_OFFLINE) -and ($env:AVM_OFFLINE -eq '1')) {
        Install-AvmTool -Name tflint -InformationAction Continue -ErrorAction Stop

        $moduleRoot = Join-Path $TestDrive 'terraform-module'
        New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null
        @'
terraform {
  required_version = ">= 1.9.0"
}

variable "first" {
  type        = string
  description = "First value."
}

variable "second" {
  type        = string
  description = "Second value."
}
'@ | Set-Content -LiteralPath (Join-Path $moduleRoot 'variables.tf') -Encoding utf8NoBOM

        $run = InModuleScope 'Avm.Authoring' -Parameters @{
            Config = $script:configPath
            Root   = $moduleRoot
        } {
            param($Config, $Root)

            $tool = Resolve-AvmTool -Name 'tflint'
            $init = Invoke-AvmProcess `
                -FilePath $tool.Path `
                -ArgumentList @('--init', '--config', $Config) `
                -WorkingDirectory $Root `
                -IgnoreExitCode
            $version = Invoke-AvmProcess `
                -FilePath $tool.Path `
                -ArgumentList @('--config', $Config, '--version') `
                -WorkingDirectory $Root `
                -IgnoreExitCode
            $lint = Invoke-AvmProcess `
                -FilePath $tool.Path `
                -ArgumentList @('--config', $Config, '--format=json', '--minimum-failure-severity=notice') `
                -WorkingDirectory $Root `
                -IgnoreExitCode

            [pscustomobject]@{
                ToolVersion = $tool.Version
                Init        = $init
                Version     = $version
                Lint        = $lint
            }
        }

        $run.ToolVersion | Should -Be '0.64.0'
        $run.Init.ExitCode | Should -Be 0 -Because $run.Init.StdErr
        $run.Version.ExitCode | Should -Be 0 -Because $run.Version.StdErr
        "$($run.Version.StdOut)`n$($run.Version.StdErr)" | Should -Match 'TFLint version 0\.64\.0'
        "$($run.Version.StdOut)`n$($run.Version.StdErr)" | Should -Match 'ruleset\.avm \(0\.18\.0\)'

        $run.Lint.ExitCode | Should -Be 2 -Because $run.Lint.StdErr
        $payload = $run.Lint.StdOut | ConvertFrom-Json
        @($payload.issues.rule.name) | Should -Contain 'terraform_variable_separate'
    }
}
