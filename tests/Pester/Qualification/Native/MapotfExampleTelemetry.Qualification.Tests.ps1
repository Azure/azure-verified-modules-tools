#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Qualification: MAPOTF example telemetry' -Tag Qualification {
BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
        $moduleRoot = Join-Path $repoRoot 'src' 'Avm.Authoring'
        $script:profilesRoot = Join-Path $moduleRoot 'Resources' 'mapotf'
        $script:fixturesRoot = Join-Path $repoRoot 'tests' 'fixtures' 'modules'
        $script:originalEnvironment = @{}
        foreach ($name in @('AVM_HOME', 'AVM_MPTF_CONFIG_DIR', 'TF_PLUGIN_CACHE_DIR')) {
            $script:originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        if (-not $env:AVM_HOME) {
            $env:AVM_HOME = Join-Path $TestDrive 'avm-home'
        }
        $env:AVM_MPTF_CONFIG_DIR = $null
        $env:TF_PLUGIN_CACHE_DIR = $null
        Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
        $script:tools = InModuleScope 'Avm.Authoring' {
            @{
                mapotf = (Resolve-AvmTool -Name mapotf).Path
                terraform = (Resolve-AvmTool -Name terraform).Path
            }
        }
        $script:processEnvironment = InModuleScope 'Avm.Authoring' -Parameters @{ Terraform = $script:tools.terraform } {
            param($Terraform)
            New-AvmToolPathEnvironment -ToolPath $Terraform -ToolName terraform
        }
        foreach ($name in @('TF_DATA_DIR', 'TF_CLI_ARGS', 'TF_CLI_ARGS_get', 'TF_CLI_ARGS_init', 'TF_CLI_ARGS_validate', 'TF_CLI_ARGS_plan', 'TF_CLI_ARGS_show', 'TF_VAR_location')) {
            $script:processEnvironment[$name] = $null
        }

        function Invoke-TelemetryProcess {
            param([string] $Tool, [string[]] $Arguments, [string] $Root, [switch] $IgnoreExitCode)

            InModuleScope 'Avm.Authoring' -Parameters @{
                Tool = $script:tools[$Tool]
                Arguments = $Arguments
                Root = $Root
                Environment = $script:processEnvironment
                IgnoreExitCode = [bool]$IgnoreExitCode
            } {
                param($Tool, $Arguments, $Root, $Environment, $IgnoreExitCode)
                Invoke-AvmProcess -FilePath $Tool -ArgumentList $Arguments `
                    -WorkingDirectory $Root -EnvVars $Environment -IgnoreExitCode:$IgnoreExitCode
            }
        }

        function Invoke-TelemetryProfiles {
            param([string] $Root, [string[]] $Profile = @('example', 'provider-cleanup', 'common'))

            $arguments = @('transform', '--tf-dir', $Root)
            foreach ($name in $Profile) {
                $arguments += @('--mptf-dir', (Join-Path $script:profilesRoot $name))
            }
            $result = Invoke-TelemetryProcess -Tool mapotf -Arguments $arguments -Root $Root
            $result.ExitCode | Should -Be 0
            $null = Invoke-TelemetryProcess -Tool mapotf -Root $Root -Arguments @('clean-backup', '--tf-dir', $Root)
        }

        function Assert-TelemetryExampleValid {
            param([string] $Root)

            $null = Invoke-TelemetryProcess -Tool terraform -Root $Root -Arguments @(
                'init', '-backend=false', '-input=false', '-upgrade', '-no-color'
            )
            $validation = Invoke-TelemetryProcess -Tool terraform -Root $Root -Arguments @('validate', '-json')
            ($validation.StdOut | ConvertFrom-Json).valid | Should -BeTrue
        }

        function Invoke-TelemetryEngine {
            param([string] $Root, [switch] $CheckDrift, [switch] $WhatIf)

            InModuleScope 'Avm.Authoring' -Parameters @{
                Root = $Root
                CheckDrift = [bool]$CheckDrift
                WhatIf = [bool]$WhatIf
            } {
                param($Root, $CheckDrift, $WhatIf)
                Invoke-AvmTerraformTransform -Context ([pscustomobject]@{
                        Kind = 'terraform-module-repo'
                        Root = $Root
                        Ecosystem = 'terraform'
                    }) -CheckDrift:$CheckDrift -WhatIf:$WhatIf -ThrottleLimit 4
            }
        }

        $script:sourceVariables = @'
variable "enable_telemetry" {
  type    = bool
  default = true
}

variable "a_optional" {
  type    = string
  default = ""
}

variable "z_optional" {
  type    = string
  default = ""
}
'@
    }

BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:target = Join-Path $script:root 'examples' 'default'
        $script:source = Join-Path $script:root 'modules' 'support'
        $null = New-Item -ItemType Directory -Path $script:target, $script:source -Force
        $script:main = Join-Path $script:target 'main.tf'
        $script:variables = Join-Path $script:source 'variables.tf'
        Set-Content -LiteralPath $script:variables -Value $script:sourceVariables -Encoding utf8NoBOM
    }

AfterAll {
        foreach ($entry in $script:originalEnvironment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
        }
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

It 'updates every supported call across files and skips a utility subdirectory' {
        $utility = Join-Path $script:source 'utility'
        $null = New-Item -ItemType Directory -Path $utility
        Set-Content -LiteralPath (Join-Path $utility 'main.tf') -Encoding utf8NoBOM -Value 'output "name" { value = "utility" }'
        Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -Value @'
module "enabled" {
  source           = "../../modules/support"
  enable_telemetry = true
}

module "disabled" {
  source           = "../../modules/support"
  enable_telemetry = false
}
'@
        $helpers = Join-Path $script:target 'helpers.tf'
        Set-Content -LiteralPath $helpers -Encoding utf8NoBOM -Value @'
module "missing" {
  source = "../../modules/support"
}

module "utility" {
  source = "../../modules/support/utility"
}
'@

        Invoke-TelemetryProfiles -Root $script:target
        $main = Get-Content -LiteralPath $script:main -Raw
        $helperContent = Get-Content -LiteralPath $helpers -Raw
        @([regex]::Matches($main, '(?m)^\s+enable_telemetry\s*=\s*var\.enable_telemetry\s*$')) | Should -HaveCount 2
        @([regex]::Matches($helperContent, '(?m)^\s+enable_telemetry\s*=\s*var\.enable_telemetry\s*$')) | Should -HaveCount 1
        $exampleVariables = Join-Path $script:target 'variables.tf'
        $declaration = Get-Content -LiteralPath $exampleVariables -Raw
        $declaration | Should -Match '(?s)variable "enable_telemetry" \{[^}]*default\s*=\s*true'
        @([regex]::Matches($declaration, '(?m)^variable "enable_telemetry"')) | Should -HaveCount 1
        $utilityBody = [regex]::Match($helperContent, '(?ms)^module "utility" \{(?<body>.*?)^\}').Groups['body'].Value
        $utilityBody | Should -Match 'source\s*=\s*"\.\./\.\./modules/support/utility"'
        $utilityBody | Should -Not -Match 'enable_telemetry'
        Assert-TelemetryExampleValid -Root $script:target

        Invoke-TelemetryProfiles -Root $script:target
        Get-Content -LiteralPath $script:main -Raw | Should -BeExactly $main
        Get-Content -LiteralPath $helpers -Raw | Should -BeExactly $helperContent
        Get-Content -LiteralPath $exampleVariables -Raw | Should -BeExactly $declaration

        $unreadable = Join-Path $script:target 'unreadable.tf'
        [IO.File]::WriteAllText($unreadable, 'module "unreadable" { source = "../../modules/not-present" }')
        $beforeFailure = @(Get-ChildItem -LiteralPath $script:target -Filter '*.tf' -File | Get-FileHash)
        { Invoke-TelemetryProfiles -Root $script:target } | Should -Throw
        foreach ($file in $beforeFailure) {
            (Get-FileHash -LiteralPath $file.Path).Hash | Should -BeExactly $file.Hash
        }
    }
}
