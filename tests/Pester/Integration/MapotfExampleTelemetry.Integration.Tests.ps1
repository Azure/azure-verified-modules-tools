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

    It 'connects <Name> to the example variable on the first pass and stays ordered and idempotent' -TestCases @(
        @{ Name = 'an omitted optional input'; Value = ''; Required = $false }
        @{ Name = 'an enabled input'; Value = 'true'; Required = $false }
        @{ Name = 'a disabled input'; Value = 'false'; Required = $false }
        @{ Name = 'a variable expression'; Value = 'var.enable_telemetry'; Required = $false }
        @{ Name = 'a reference-looking string literal'; Value = '"var.enable_telemetry"'; Required = $false }
        @{ Name = 'a conditional expression'; Value = 'var.enable_telemetry ? true : false'; Required = $false }
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
        $body | Should -Match '(?m)^\s+enable_telemetry\s*=\s*var\.enable_telemetry\s*$'
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

    It 'creates variables.tf for <Name> while preserving the call comment' -TestCases @(
        @{ Name = 'literal false'; Value = 'false' }
        @{ Name = 'an existing variable reference'; Value = 'var.enable_telemetry' }
    ) {
        param($Name, $Value)

        Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -Value @"
module "example" {
  source = "../../modules/support"

  enable_telemetry = $Value # see variables.tf
}
"@
        Invoke-TelemetryProfiles -Root $script:target -Profile example
        $first = Get-Content -LiteralPath $script:main -Raw
        $first | Should -Match '(?m)^\s+enable_telemetry\s*=\s*var\.enable_telemetry # see variables\.tf$'
        $exampleVariables = Join-Path $script:target 'variables.tf'
        $declaration = Get-Content -LiteralPath $exampleVariables -Raw
        $declaration | Should -Match '(?s)variable "enable_telemetry" \{\s*type\s*=\s*bool\s*default\s*=\s*true'
        @(Get-ChildItem -LiteralPath $script:target -Filter '*.tf' -File).Name |
            Should -Be @('main.tf', 'variables.tf')
        Assert-TelemetryExampleValid -Root $script:target

        Invoke-TelemetryProfiles -Root $script:target -Profile example
        Get-Content -LiteralPath $script:main -Raw | Should -BeExactly $first
        Get-Content -LiteralPath $exampleVariables -Raw | Should -BeExactly $declaration
    }

    It 'forwards an overridable telemetry location when <Name>' -TestCases @(
        @{ Name = 'the example has a location'; Location = $true; Expected = 'var\.telemetry_location != null \? var\.telemetry_location : var\.location'; Default = 'null' }
        @{ Name = 'the example has no location'; Location = $false; Expected = 'var\.telemetry_location'; Default = '"westus2"' }
    ) {
        param($Name, $Location, $Expected, $Default)

        Add-Content -LiteralPath $script:variables -Encoding utf8NoBOM -Value @'
variable "telemetry_location" {
  type    = string
  default = null
}
'@
        $locationDeclaration = if ($Location) {
            @'
variable "location" {
  type    = string
  default = "eastus"
}
'@
        }
        else {
            ''
        }
        Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -Value @"
$locationDeclaration
module "example" {
  source = "../../modules/support"

  enable_telemetry   = true
  telemetry_location = "old" # keep this comment
}
"@

        Invoke-TelemetryProfiles -Root $script:target
        $first = Get-Content -LiteralPath $script:main -Raw
        $first | Should -Match ('(?m)^\s*telemetry_location\s*=\s*' + $Expected + ' # keep this comment')
        $declaration = Get-Content -LiteralPath (Join-Path $script:target 'variables.tf') -Raw
        $declaration | Should -Match ('(?s)variable "telemetry_location" \{\s*type\s*=\s*string\s*default\s*=\s*' + $Default)
        Assert-TelemetryExampleValid -Root $script:target

        Invoke-TelemetryProfiles -Root $script:target
        Get-Content -LiteralPath $script:main -Raw | Should -BeExactly $first
        Get-Content -LiteralPath (Join-Path $script:target 'variables.tf') -Raw | Should -BeExactly $declaration
    }

    It 'leaves an already-correct reference and true-default declaration byte-identical' {
        Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -NoNewline -Value @'
module "example" {
  source = "../../modules/support"

  enable_telemetry = var.enable_telemetry # see variables.tf
}

'@
        $exampleVariables = Join-Path $script:target 'variables.tf'
        Set-Content -LiteralPath $exampleVariables -Encoding utf8NoBOM -NoNewline -Value @'
variable "enable_telemetry" {
  type    = bool
  default = true # Keep this default.
}

'@
        $beforeMain = Get-Content -LiteralPath $script:main -Raw
        $beforeVariables = Get-Content -LiteralPath $exampleVariables -Raw

        Invoke-TelemetryProfiles -Root $script:target -Profile example
        Get-Content -LiteralPath $script:main -Raw | Should -BeExactly $beforeMain
        Get-Content -LiteralPath $exampleVariables -Raw | Should -BeExactly $beforeVariables
        Assert-TelemetryExampleValid -Root $script:target
    }

    It 'reuses the <Name> declaration without moving it or changing metadata' -TestCases @(
        @{ Name = 'required input'; File = 'inputs.tf'; Default = ''; Type = 'any'; Nullable = 'true'; Sensitive = 'false' }
        @{ Name = 'true default'; File = 'variables.telemetry.tf'; Default = 'true'; Type = 'bool'; Nullable = 'false'; Sensitive = 'true' }
        @{ Name = 'null default'; File = 'variable.tf'; Default = 'null'; Type = 'bool'; Nullable = 'false'; Sensitive = 'true' }
        @{ Name = 'string false default'; File = 'settings.tf'; Default = '"false"'; Type = 'bool'; Nullable = 'false'; Sensitive = 'true' }
        @{ Name = 'false default in main'; File = 'main.tf'; Default = 'false'; Type = 'bool'; Nullable = 'true'; Sensitive = 'false' }
    ) {
        param($Name, $File, $Default, $Type, $Nullable, $Sensitive)

        $defaultLine = if ($Default) { "  default = $Default # Keep this comment." } else { '' }
        $description = "Retain this authored description.`nIt spans multiple lines."
        $declaration = @"
variable "enable_telemetry" {
  type = $Type
$defaultLine
  description = <<DESCRIPTION
$description
DESCRIPTION
  nullable  = $Nullable
  sensitive = $Sensitive

  validation {
    condition     = var.enable_telemetry != null
    error_message = "Telemetry must not be null."
  }
}
"@
        $call = @'
module "example" {
  source           = "../../modules/support"
  enable_telemetry = true
}
'@
        $declarationPath = Join-Path $script:target $File
        Set-Content -LiteralPath $script:main -Value $call -Encoding utf8NoBOM
        $content = if ($File -eq 'main.tf') { "$declaration`n`n$call" } else { $declaration }
        Set-Content -LiteralPath $declarationPath -Value $content -Encoding utf8NoBOM

        Invoke-TelemetryProfiles -Root $script:target -Profile example
        $first = Get-Content -LiteralPath $declarationPath -Raw
        $first | Should -Match '(?m)^\s+default\s*=\s*true'
        $first | Should -Match "(?m)^\s+type\s*=\s*$Type\s*$"
        $first | Should -Match "(?m)^\s+nullable\s*=\s*$Nullable\s*$"
        $first | Should -Match "(?m)^\s+sensitive\s*=\s*$Sensitive\s*$"
        $first | Should -Match ([regex]::Escape($description))
        $first | Should -Match 'condition\s*=\s*var\.enable_telemetry != null'
        $first | Should -Match 'error_message\s*=\s*"Telemetry must not be null\."'
        if ($Default) {
            $first | Should -Match 'default\s*=\s*true # Keep this comment\.'
        }
        $files = @(Get-ChildItem -LiteralPath $script:target -Filter '*.tf' -File | Sort-Object Name)
        $files.Name | Should -Be @(@('main.tf', $File) | Sort-Object -Unique)
        $allContent = ($files | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
        @([regex]::Matches($allContent, '(?m)^variable "enable_telemetry"')) | Should -HaveCount 1
        $allContent | Should -Match 'enable_telemetry\s*=\s*var\.enable_telemetry'
        Assert-TelemetryExampleValid -Root $script:target

        Invoke-TelemetryProfiles -Root $script:target -Profile example
        Get-Content -LiteralPath $declarationPath -Raw | Should -BeExactly $first
    }

    It 'appends the exact variable after <Name> and a trailing comment without a newline' -TestCases @(
        @{ Name = 'an unrelated input'; Variable = 'name' }
        @{ Name = 'the enabled_telemetry spelling'; Variable = 'enabled_telemetry' }
        @{ Name = 'a differently cased variable'; Variable = 'Enable_telemetry' }
        @{ Name = 'a longer variable name'; Variable = 'enable_telemetry_extra' }
    ) {
        param($Name, $Variable)

        $exampleVariables = Join-Path $script:target 'variables.tf'
        $originalVariable = "variable `"$Variable`" { default = true }"
        $comment = '# variable "enable_telemetry" { default = true }'
        $before = "$originalVariable`n$comment"
        Set-Content -LiteralPath $exampleVariables -Value $before -NoNewline -Encoding utf8NoBOM
        Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -Value @'
module "example" {
  source = "../../modules/support"
}
'@

        Invoke-TelemetryProfiles -Root $script:target -Profile example
        $first = Get-Content -LiteralPath $exampleVariables -Raw
        $first | Should -Match (
            '^' + [regex]::Escape($originalVariable) + '\r?\n(?:\r?\n)?' +
            [regex]::Escape($comment) + '\r?\nvariable "enable_telemetry" \{')
        $first | Should -Match '(?ms)^variable "enable_telemetry" \{\s*type\s*=\s*bool\s*default\s*=\s*true'
        @([regex]::Matches($first, '(?m)^variable "enable_telemetry"')) | Should -HaveCount 1
        Get-Content -LiteralPath $script:main -Raw | Should -Match 'enable_telemetry\s*=\s*var\.enable_telemetry'
        Assert-TelemetryExampleValid -Root $script:target

        Invoke-TelemetryProfiles -Root $script:target -Profile example
        Get-Content -LiteralPath $exampleVariables -Raw | Should -BeExactly $first
    }

    It 'defaults an inline <Name> declaration without duplicating it' -TestCases @(
        @{ Name = 'empty'; Body = '' }
        @{ Name = 'required bool'; Body = 'type = bool' }
        @{ Name = 'true-default'; Body = 'default = true' }
        @{ Name = 'false-default'; Body = 'default = false' }
    ) {
        param($Name, $Body)

        Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -Value @"
variable "enable_telemetry" { $Body }

module "example" {
  source = "../../modules/support"
}
"@
        Invoke-TelemetryProfiles -Root $script:target
        $first = Get-Content -LiteralPath $script:main -Raw
        $first | Should -Match '(?s)variable "enable_telemetry" \{[^}]*default\s*=\s*true'
        $first | Should -Match 'enable_telemetry\s*=\s*var\.enable_telemetry'
        @(Get-ChildItem -LiteralPath $script:target -Filter '*.tf' -File).Name | Should -Be @('main.tf')
        Assert-TelemetryExampleValid -Root $script:target

        Invoke-TelemetryProfiles -Root $script:target
        Get-Content -LiteralPath $script:main -Raw | Should -BeExactly $first
    }

    It 'repairs stranded telemetry variables without TFLint unused declarations for <Calls> calls' -TestCases @(
        @{ Calls = 1 }
        @{ Calls = 2 }
    ) {
        param($Calls)

        $script:tools['tflint'] = InModuleScope 'Avm.Authoring' {
            (Resolve-AvmTool -Name tflint).Path
        }
        $config = Join-Path $script:root 'unused.tflint.hcl'
        Set-Content -LiteralPath $config -Encoding utf8NoBOM -Value @'
config {
  disabled_by_default = true
}

plugin "terraform" {
  enabled = true
}

rule "terraform_unused_declarations" {
  enabled = true
}
'@
        $exampleVariables = Join-Path $script:target 'variables.tf'
        Set-Content -LiteralPath $exampleVariables -Encoding utf8NoBOM -Value @'
variable "name" {
  type = string
}

variable "enable_telemetry" {
  type    = bool
  default = true
  description = <<DESCRIPTION
This variable controls whether or not telemetry is enabled for the module.
For more information see <https://aka.ms/avm/telemetryinfo>.
If it is set to false, then no telemetry will be collected.
DESCRIPTION
}
'@
        $callBlocks = foreach ($index in 1..$Calls) {
            @"
module "call$index" {
  source = "../../modules/support"

  enable_telemetry = false # see variables.tf
}
"@
        }
        $output = @'
output "name" {
  value = var.name
}
'@
        Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -Value (
            ($callBlocks -join "`n`n") + "`n`n" + $output)
        Assert-TelemetryExampleValid -Root $script:target
        $arguments = @('--config', $config, '--format=json', '--call-module-type=none')
        $before = Invoke-TelemetryProcess -Tool tflint -Root $script:target -Arguments $arguments -IgnoreExitCode
        $before.ExitCode | Should -Be 2
        $before.StdOut | Should -Not -BeNullOrEmpty
        $diagnostic = $before.StdOut | ConvertFrom-Json
        @($diagnostic.errors) | Should -HaveCount 0
        @($diagnostic.issues) | Should -HaveCount 1
        $diagnostic.issues[0].rule.name | Should -BeExactly 'terraform_unused_declarations'
        $diagnostic.issues[0].message | Should -Match 'enable_telemetry'
        $diagnostic.issues[0].range.filename | Should -BeExactly 'variables.tf'

        Invoke-TelemetryProfiles -Root $script:target
        $first = Get-Content -LiteralPath $script:main -Raw
        @([regex]::Matches($first, '(?m)^\s+enable_telemetry\s*=\s*var\.enable_telemetry # see variables\.tf$')) |
            Should -HaveCount $Calls
        $declaration = Get-Content -LiteralPath $exampleVariables -Raw
        $declaration | Should -Match '(?s)variable "enable_telemetry" \{[^}]*default\s*=\s*true'
        $declaration | Should -Match '(?s)description = <<DESCRIPTION\nThis variable controls whether or not telemetry is enabled for the module\.\nFor more information see <https://aka\.ms/avm/telemetryinfo>\.\nIf it is set to false, then no telemetry will be collected\.\nDESCRIPTION'
        @([regex]::Matches($declaration, '(?m)^variable "enable_telemetry"')) | Should -HaveCount 1
        $after = Invoke-TelemetryProcess -Tool tflint -Root $script:target -Arguments $arguments
        $after.ExitCode | Should -Be 0
        $after.StdOut | Should -Not -BeNullOrEmpty
        $clean = $after.StdOut | ConvertFrom-Json
        @($clean.errors) | Should -HaveCount 0
        @($clean.issues) | Should -HaveCount 0
        Assert-TelemetryExampleValid -Root $script:target

        Invoke-TelemetryProfiles -Root $script:target
        Get-Content -LiteralPath $script:main -Raw | Should -BeExactly $first
        Get-Content -LiteralPath $exampleVariables -Raw | Should -BeExactly $declaration
    }

    It 'does not add an unsupported input for <Name>' -TestCases @(
        @{ Name = 'a utility without an example variable'; Source = 'output "name" { value = "utility" }'; DeclareVariable = $false }
        @{ Name = 'a utility with no variables'; Source = 'output "name" { value = "utility" }' }
        @{ Name = 'the enabled_telemetry spelling'; Source = 'variable "enabled_telemetry" { default = true }' }
        @{ Name = 'a differently cased input'; Source = 'variable "Enable_telemetry" { default = true }' }
        @{ Name = 'a commented-out input'; Source = "# variable `"enable_telemetry`" {}`noutput `"name`" { value = `"utility`" }" }
    ) {
        param($Name, $Source, [bool] $DeclareVariable = $true)

        Set-Content -LiteralPath $script:variables -Value $Source -Encoding utf8NoBOM
        $declaration = if ($DeclareVariable) {
            @'
variable "enable_telemetry" {
  type    = bool
  default = true
}
'@
        }
        else {
            ''
        }
        Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -Value @"
$declaration

module "utility" {
  source = "../../modules/support"
}
"@
        $before = Get-Content -LiteralPath $script:main -Raw
        Invoke-TelemetryProfiles -Root $script:target -Profile example
        Get-Content -LiteralPath $script:main -Raw | Should -BeExactly $before
        @(Get-ChildItem -LiteralPath $script:target -Filter '*.tf' -File).Name | Should -Be @('main.tf')
        Assert-TelemetryExampleValid -Root $script:target
    }

    It 'handles an inline module call' {
        Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -Value 'module "example" { source = "../../modules/support" }'

        Invoke-TelemetryProfiles -Root $script:target
        $first = Get-Content -LiteralPath $script:main -Raw
        $first | Should -Match '(?m)^\s+enable_telemetry\s*=\s*var\.enable_telemetry\s*$'
        Get-Content -LiteralPath (Join-Path $script:target 'variables.tf') -Raw |
            Should -Match '(?s)variable "enable_telemetry" \{[^}]*default\s*=\s*true'
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
    }

    It 'leaves an example without module calls <Name> untouched' -TestCases @(
        @{ Name = 'and without a telemetry variable'; Content = 'output "name" { value = "example" }' }
        @{ Name = 'but with a telemetry variable'; Content = 'variable "enable_telemetry" { default = true }' }
    ) {
        param($Name, $Content)

        Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -Value $Content
        $before = Get-Content -LiteralPath $script:main -Raw

        Invoke-TelemetryProfiles -Root $script:target -Profile example
        Get-Content -LiteralPath $script:main -Raw | Should -BeExactly $before
        @(Get-ChildItem -LiteralPath $script:target -Filter '*.tf' -File).Name | Should -Be @('main.tf')
    }

    It 'reports an unreadable source with <Name> instead of assuming telemetry is unsupported' -TestCases @(
        @{ Name = 'no argument'; Argument = '' }
        @{ Name = 'a literal false'; Argument = '  enable_telemetry = false' }
        @{ Name = 'a variable reference'; Argument = '  enable_telemetry = var.enable_telemetry' }
    ) {
        param($Name, $Argument)

        Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -Value @"
module "example" {
  source = "./missing"
$Argument
}
"@
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
                $variables = Join-Path $example.FullName 'variables.tf'
                $readme = Join-Path $example.FullName 'README.md'
                $beforeMain = Get-Content -LiteralPath $main -Raw
                $beforeVariables = Get-Content -LiteralPath $variables -Raw
                $beforeReadme = Get-Content -LiteralPath $readme -Raw
                $beforeMain | Should -Match '(?m)^\s+enable_telemetry\s*=\s*var\.enable_telemetry\s*$'
                $beforeVariables | Should -Match '(?s)variable "enable_telemetry" \{[^}]*default\s*=\s*true'

                Invoke-TelemetryProfiles -Root $example.FullName -Profile example
                $null = Invoke-TelemetryProcess -Tool terraform -Root $example.FullName -Arguments @('fmt', '-check', '-diff', '.')
                $null = Invoke-TelemetryProcess -Tool terraform-docs -Root $example.FullName -Arguments @(
                    '-c', (Join-Path $examples '.terraform-docs.yml'), '.'
                )
                Get-Content -LiteralPath $main -Raw | Should -BeExactly $beforeMain
                Get-Content -LiteralPath $variables -Raw | Should -BeExactly $beforeVariables
                Get-Content -LiteralPath $readme -Raw | Should -BeExactly $beforeReadme
                $checked++
            }
        }
        $checked | Should -Be 5
    }

    It 'preserves inline example declarations beside an existing telemetry variables file' {
        $exampleVariables = Join-Path $script:target 'variables.tf'
        Copy-Item -LiteralPath (Join-Path $script:fixturesRoot 'terraform-azure-avm-res-mock' 'examples' 'default' 'variables.tf') `
            -Destination $exampleVariables
        $exampleVariables | Should -Exist
        $originalVariables = [System.IO.File]::ReadAllBytes($exampleVariables)
        $originalVariables | Should -Not -BeNullOrEmpty
        Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -NoNewline -Value @'
module "example" {
  source           = "../../modules/support"
  enable_telemetry = var.enable_telemetry
}

variable "single_file_input" {
  type    = string
  default = "example"
}

output "single_file_output" {
  value = var.single_file_input
}

'@

        Invoke-TelemetryProfiles -Root $script:target

        $exampleVariables | Should -Exist
        [System.IO.File]::ReadAllBytes($exampleVariables) | Should -Be $originalVariables
        $main = Get-Content -LiteralPath $script:main -Raw
        $main | Should -Match 'variable "single_file_input"'
        $main | Should -Match 'output "single_file_output"'
        $main | Should -Match 'value\s*=\s*var\.single_file_input'
        @(Get-ChildItem -LiteralPath $script:target -Filter '*.tf' -File | Sort-Object Name).Name |
            Should -Be @('main.tf', 'variables.tf')
        Assert-TelemetryExampleValid -Root $script:target
    }

    It 'sees newly generated root inputs, preserves module calls, and restores drift checks' {
        $wrapper = Join-Path $script:root 'modules' 'wrapper'
        $null = New-Item -ItemType Directory -Path $wrapper -Force
        Set-Content -LiteralPath (Join-Path $script:root 'main.tf') -Encoding utf8NoBOM -Value @'
module "dependency" {
  source           = "./modules/support"
  enable_telemetry = true
}
'@
        Set-Content -LiteralPath (Join-Path $script:root 'terraform.tf') -Encoding utf8NoBOM -Value @'
terraform {
  required_version = ">= 1.9"
}
'@
        Set-Content -LiteralPath (Join-Path $script:root 'metadata.json') -Encoding utf8NoBOM -Value @'
{
  "$schema": "https://raw.githubusercontent.com/Azure/azure-verified-modules-tools/main/src/Avm.Authoring/Resources/Schemas/v1/avm-module-metadata.schema.json",
  "moduleDisplayName": "Telemetry parent",
  "moduleDescription": "Fixture for example ordering.",
  "canonicalType": "Microsoft.Resources/resourceGroups",
  "telemetryIdPrefix": "46d3xtrf.res.e1a2b3c",
  "owners": []
}
'@
        Set-Content -LiteralPath (Join-Path $script:source 'metadata.json') -Encoding utf8NoBOM -Value @'
{
  "$schema": "https://raw.githubusercontent.com/Azure/azure-verified-modules-tools/main/src/Avm.Authoring/Resources/Schemas/v1/avm-module-metadata.schema.json",
  "moduleDisplayName": "Support helper",
  "moduleDescription": "Helper without telemetry.",
  "canonicalType": "helper"
}
'@
        Set-Content -LiteralPath (Join-Path $wrapper 'terraform.tf') -Encoding utf8NoBOM -Value 'terraform {}'
        Set-Content -LiteralPath (Join-Path $wrapper 'metadata.json') -Encoding utf8NoBOM -Value @'
{
  "$schema": "https://raw.githubusercontent.com/Azure/azure-verified-modules-tools/main/src/Avm.Authoring/Resources/Schemas/v1/avm-module-metadata.schema.json",
  "moduleDisplayName": "Wrapper helper",
  "moduleDescription": "Helper without telemetry.",
  "canonicalType": "helper"
}
'@
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
        $exampleVariablesPath = Join-Path 'examples' 'default' 'variables.tf'
        $dryRun = Invoke-TelemetryEngine -Root $script:root -WhatIf
        $dryRun.Status | Should -Be 'skipped'
        $untouched = @(Get-ChildItem -LiteralPath $script:root -Recurse -Filter '*.tf' -File)
        $untouched | Should -HaveCount $before.Count
        foreach ($file in $untouched) {
            (Get-FileHash -LiteralPath $file.FullName).Hash | Should -BeExactly $before[$file.FullName]
        }

        $drift = Invoke-TelemetryEngine -Root $script:root -CheckDrift
        $drift.Status | Should -Be 'fail'
        @($drift.Issues | Where-Object { $_.File -eq 'main.telemetry.tf' -and $_.Code -eq 'avm.tf.mapotf-drift' }) | Should -HaveCount 1
        @($drift.Issues | Where-Object { $_.File -eq $examplePath -and $_.Code -eq 'avm.tf.mapotf-drift' }) | Should -HaveCount 1
        @($drift.Issues | Where-Object { $_.File -eq $exampleVariablesPath -and $_.Code -eq 'avm.tf.mapotf-drift' }) | Should -HaveCount 1
        $restored = @(Get-ChildItem -LiteralPath $script:root -Recurse -Filter '*.tf' -File)
        $restored | Should -HaveCount $before.Count
        foreach ($file in $restored) {
            (Get-FileHash -LiteralPath $file.FullName).Hash | Should -BeExactly $before[$file.FullName]
        }
        (Join-Path $script:root 'variables.tf') | Should -Not -Exist
        (Join-Path $script:root 'main.telemetry.tf') | Should -Not -Exist
        (Join-Path $script:root $exampleVariablesPath) | Should -Not -Exist

        $result = Invoke-TelemetryEngine -Root $script:root
        $result.Status | Should -Be 'pass'
        $result.Changed | Should -Contain $examplePath
        $result.Changed | Should -Contain $exampleVariablesPath
        $example = Get-Content -LiteralPath $script:main -Raw
        $example | Should -Match '(?ms)^module "example" \{[^}]*enable_telemetry\s*=\s*var\.enable_telemetry'
        $example | Should -Match '(?ms)^module "example" \{[^}]*telemetry_location\s*=\s*var\.telemetry_location'
        $example | Should -Match '(?ms)^module "wrapper" \{\s*source\s*=\s*"\.\./\.\./modules/wrapper"\s*\}'
        Get-Content -LiteralPath (Join-Path $script:root $exampleVariablesPath) -Raw |
            Should -Match '(?s)variable "enable_telemetry" \{[^}]*default\s*=\s*true'
        Get-Content -LiteralPath (Join-Path $script:root $exampleVariablesPath) -Raw |
            Should -Match '(?s)variable "telemetry_location" \{[^}]*default\s*=\s*"westus2"'
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
