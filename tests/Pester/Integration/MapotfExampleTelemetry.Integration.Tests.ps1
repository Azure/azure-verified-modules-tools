#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Integration: MAPOTF example telemetry' -Tag 'Integration' -Skip:($env:AVM_OFFLINE -eq '1') {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
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
        foreach ($name in @('TF_DATA_DIR', 'TF_CLI_ARGS', 'TF_CLI_ARGS_get', 'TF_CLI_ARGS_init', 'TF_CLI_ARGS_validate')) {
            $script:processEnvironment[$name] = $null
        }

        function Invoke-TelemetryProcess {
            param([string] $Tool, [string[]] $Arguments, [string] $Root)

            InModuleScope 'Avm.Authoring' -Parameters @{
                Tool = $script:tools[$Tool]
                Arguments = $Arguments
                Root = $Root
                Environment = $script:processEnvironment
            } {
                param($Tool, $Arguments, $Root, $Environment)
                Invoke-AvmProcess -FilePath $Tool -ArgumentList $Arguments `
                    -WorkingDirectory $Root -EnvVars $Environment
            }
        }

        function Invoke-TelemetryProfiles {
            param([string] $Root, [string[]] $Profile = @('example', 'common'))

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
            param([string] $Root, [switch] $CheckDrift)

            InModuleScope 'Avm.Authoring' -Parameters @{ Root = $Root; CheckDrift = [bool]$CheckDrift } {
                param($Root, $CheckDrift)
                Invoke-AvmTerraformTransform -Context ([pscustomobject]@{
                        Kind = 'terraform-module-repo'
                        Root = $Root
                        Ecosystem = 'terraform'
                    }) -CheckDrift:$CheckDrift -ThrottleLimit 4
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

    It 'disables <Name> on the first pass and stays ordered and idempotent' -TestCases @(
        @{ Name = 'an omitted optional input'; Value = ''; Required = $false }
        @{ Name = 'an enabled input'; Value = 'true'; Required = $false }
        @{ Name = 'a variable expression'; Value = 'var.enable_telemetry'; Required = $false }
        @{ Name = 'a null input'; Value = 'null'; Required = $false }
        @{ Name = 'an omitted required input'; Value = ''; Required = $true }
    ) {
        param($Name, $Value, $Required)

        if ($Required) {
            Set-Content -LiteralPath $script:variables -Encoding utf8NoBOM -Value (
                $script:sourceVariables.Replace('  default = true', ''))
        }
        $sourceHash = (Get-FileHash -LiteralPath $script:variables).Hash
        $assignment = if ($Value) { "  enable_telemetry = $Value" } else { '' }
        Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -Value @"
variable "enable_telemetry" {
  type    = bool
  default = true
}

module "example" {
  source = "../../modules/support"

  z_optional = "z"
  a_optional = "a"
$assignment
  depends_on = []
}

output "example" {
  value = "unchanged"
}
"@

        Invoke-TelemetryProfiles -Root $script:target
        $first = Get-Content -LiteralPath $script:main -Raw
        $body = [regex]::Match($first, '(?ms)^module "example" \{(?<body>.*?)^\}').Groups['body'].Value
        $body | Should -Not -BeNullOrEmpty
        $body | Should -Match '(?m)^\s+enable_telemetry\s*=\s*false\s*$'
        $names = @([regex]::Matches($body, '(?m)^\s+(\w+)\s*=') | ForEach-Object { $_.Groups[1].Value })
        $expected = if ($Required) {
            'source,enable_telemetry,a_optional,z_optional,depends_on'
        }
        else {
            'source,a_optional,enable_telemetry,z_optional,depends_on'
        }
        ($names -join ',') | Should -BeExactly $expected
        $first | Should -Match '(?s)variable "enable_telemetry" \{[^}]*default\s*=\s*true'
        $first | Should -Match 'output "example"'
        @(Get-ChildItem -LiteralPath $script:target -Filter '*.tf' -File).Name | Should -Be @('main.tf')
        (Get-FileHash -LiteralPath $script:variables).Hash | Should -BeExactly $sourceHash
        Assert-TelemetryExampleValid -Root $script:target

        Invoke-TelemetryProfiles -Root $script:target
        Get-Content -LiteralPath $script:main -Raw | Should -BeExactly $first
    }

    It 'leaves an existing literal false and its comment untouched' {
        Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -Value @'
module "example" {
  source = "../../modules/support"

  enable_telemetry = false # Keep telemetry disabled.
}
'@
        $before = Get-Content -LiteralPath $script:main -Raw
        Invoke-TelemetryProfiles -Root $script:target -Profile example
        Get-Content -LiteralPath $script:main -Raw | Should -BeExactly $before
        Assert-TelemetryExampleValid -Root $script:target
    }

    It 'does not add an unsupported input for <Name>' -TestCases @(
        @{ Name = 'a utility with no variables'; Source = 'output "name" { value = "utility" }' }
        @{ Name = 'the enabled_telemetry spelling'; Source = 'variable "enabled_telemetry" { default = true }' }
        @{ Name = 'a differently cased input'; Source = 'variable "Enable_telemetry" { default = true }' }
        @{ Name = 'a commented-out input'; Source = "# variable `"enable_telemetry`" {}`noutput `"name`" { value = `"utility`" }" }
    ) {
        param($Name, $Source)

        Set-Content -LiteralPath $script:variables -Value $Source -Encoding utf8NoBOM
        Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -Value @'
variable "enable_telemetry" {
  type    = bool
  default = true
}

module "utility" {
  source = "../../modules/support"
}
'@
        $before = Get-Content -LiteralPath $script:main -Raw
        Invoke-TelemetryProfiles -Root $script:target -Profile example
        Get-Content -LiteralPath $script:main -Raw | Should -BeExactly $before
        Assert-TelemetryExampleValid -Root $script:target
    }

    It 'handles an inline module call' {
        Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -Value 'module "example" { source = "../../modules/support" }'

        Invoke-TelemetryProfiles -Root $script:target
        $first = Get-Content -LiteralPath $script:main -Raw
        $first | Should -Match '(?m)^\s+enable_telemetry\s*=\s*false\s*$'
        Assert-TelemetryExampleValid -Root $script:target
        Invoke-TelemetryProfiles -Root $script:target
        Get-Content -LiteralPath $script:main -Raw | Should -BeExactly $first
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
        @([regex]::Matches($main, '(?m)^\s+enable_telemetry\s*=\s*false\s*$')) | Should -HaveCount 2
        @([regex]::Matches($helperContent, '(?m)^\s+enable_telemetry\s*=\s*false\s*$')) | Should -HaveCount 1
        $utilityBody = [regex]::Match($helperContent, '(?ms)^module "utility" \{(?<body>.*?)^\}').Groups['body'].Value
        $utilityBody | Should -Match 'source\s*=\s*"\.\./\.\./modules/support/utility"'
        $utilityBody | Should -Not -Match 'enable_telemetry'
        Assert-TelemetryExampleValid -Root $script:target

        Invoke-TelemetryProfiles -Root $script:target
        Get-Content -LiteralPath $script:main -Raw | Should -BeExactly $main
        Get-Content -LiteralPath $helpers -Raw | Should -BeExactly $helperContent
    }

    It 'leaves an example without module calls untouched' {
        Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -Value 'output "name" { value = "example" }'
        $before = Get-Content -LiteralPath $script:main -Raw

        Invoke-TelemetryProfiles -Root $script:target -Profile example
        Get-Content -LiteralPath $script:main -Raw | Should -BeExactly $before
    }

    It 'reports an unreadable module source instead of assuming telemetry is unsupported' {
        Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -Value @'
module "example" {
  source = "./missing"
}
'@
        { Invoke-TelemetryProfiles -Root $script:target -Profile example } | Should -Throw '*cannot fetch module source*'
    }

    It 'keeps canonical examples and their generated documentation unchanged' {
        $script:tools['terraform-docs'] = InModuleScope 'Avm.Authoring' {
            (Resolve-AvmTool -Name terraform-docs).Path
        }
        $checked = 0
        foreach ($name in @('terraform-azure-avm-res-mock', 'terraform-azurerm-avm-res-mock')) {
            $fixture = Join-Path $script:root $name
            Copy-Item -LiteralPath (Join-Path $script:fixturesRoot $name) -Destination $fixture -Recurse
            $examples = Join-Path $fixture 'examples'
            foreach ($example in Get-ChildItem -LiteralPath $examples -Directory) {
                $main = Join-Path $example.FullName 'main.tf'
                $readme = Join-Path $example.FullName 'README.md'
                $beforeMain = Get-Content -LiteralPath $main -Raw
                $beforeReadme = Get-Content -LiteralPath $readme -Raw
                $beforeMain | Should -Match '(?m)^\s+enable_telemetry\s*=\s*false\s*$'

                Invoke-TelemetryProfiles -Root $example.FullName -Profile example
                $null = Invoke-TelemetryProcess -Tool terraform -Root $example.FullName -Arguments @('fmt', '-check', '-diff', '.')
                $null = Invoke-TelemetryProcess -Tool terraform-docs -Root $example.FullName -Arguments @(
                    '-c', (Join-Path $examples '.terraform-docs.yml'), '.'
                )
                Get-Content -LiteralPath $main -Raw | Should -BeExactly $beforeMain
                Get-Content -LiteralPath $readme -Raw | Should -BeExactly $beforeReadme
                $checked++
            }
        }
        $checked | Should -Be 5
    }

    It 'sees newly generated root inputs, preserves module calls, and restores drift checks' {
        $rootProfile = Join-Path $script:root 'config' 'mapotf' 'root'
        $wrapper = Join-Path $script:root 'modules' 'wrapper'
        $null = New-Item -ItemType Directory -Path $rootProfile, $wrapper -Force
        Set-Content -LiteralPath (Join-Path $rootProfile 'telemetry.mptf.hcl') -Encoding utf8NoBOM -Value @'
data "variable" "telemetry" {
  name = "enable_telemetry"
}

transform "new_block" "telemetry" {
  for_each       = contains(keys(data.variable.telemetry.result), "enable_telemetry") ? toset([]) : toset([1])
  new_block_type = "variable"
  labels         = ["enable_telemetry"]
  filename       = "variables.tf"
  asraw {
    type    = bool
    default = true
  }
}
'@
        Set-Content -LiteralPath (Join-Path $script:root 'main.tf') -Encoding utf8NoBOM -Value @'
module "dependency" {
  source           = "./modules/support"
  enable_telemetry = true
}
'@
        Set-Content -LiteralPath (Join-Path $wrapper 'terraform.tf') -Encoding utf8NoBOM -Value 'terraform {}'
        Set-Content -LiteralPath (Join-Path $wrapper 'main.tf') -Encoding utf8NoBOM -Value @'
module "dependency" {
  source           = "../support"
  enable_telemetry = true
}
'@
        Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -Value @'
module "example" {
  source = "../../"
}

module "wrapper" {
  source = "../../modules/wrapper"
}
'@
        $before = @{}
        foreach ($file in Get-ChildItem -LiteralPath $script:root -Recurse -Filter '*.tf' -File) {
            $before[$file.FullName] = (Get-FileHash -LiteralPath $file.FullName).Hash
        }
        $examplePath = Join-Path 'examples' 'default' 'main.tf'
        $drift = Invoke-TelemetryEngine -Root $script:root -CheckDrift
        $drift.Status | Should -Be 'fail'
        @($drift.Issues | Where-Object { $_.File -eq $examplePath -and $_.Code -eq 'avm.tf.mapotf-drift' }) | Should -HaveCount 1
        $restored = @(Get-ChildItem -LiteralPath $script:root -Recurse -Filter '*.tf' -File)
        $restored | Should -HaveCount $before.Count
        foreach ($file in $restored) {
            (Get-FileHash -LiteralPath $file.FullName).Hash | Should -BeExactly $before[$file.FullName]
        }
        (Join-Path $script:root 'variables.tf') | Should -Not -Exist

        $result = Invoke-TelemetryEngine -Root $script:root
        $result.Status | Should -Be 'pass'
        $result.Changed | Should -Contain $examplePath
        $example = Get-Content -LiteralPath $script:main -Raw
        $example | Should -Match '(?ms)^module "example" \{[^}]*enable_telemetry\s*=\s*false'
        $example | Should -Match '(?ms)^module "wrapper" \{\s*source\s*=\s*"\.\./\.\./modules/wrapper"\s*\}'
        Get-Content -LiteralPath (Join-Path $script:root 'variables.tf') -Raw |
            Should -Match '(?s)variable "enable_telemetry" \{[^}]*default\s*=\s*true'
        foreach ($module in @($script:root, $wrapper)) {
            Get-Content -LiteralPath (Join-Path $module 'main.tf') -Raw |
                Should -Match '(?m)^\s+enable_telemetry\s*=\s*true\s*$'
        }
        Assert-TelemetryExampleValid -Root $script:target

        $clean = Invoke-TelemetryEngine -Root $script:root -CheckDrift
        $clean.Status | Should -Be 'pass'
        @($clean.Changed) | Should -HaveCount 0
    }
}
