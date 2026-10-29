#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Qualification: TFLint module sources' -Tag Qualification {
BeforeAll {
        $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring'
        Import-Module -Name (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
        $script:savedVariables = @{}
        foreach ($name in @('AVM_HOME', 'TFLINT_PLUGIN_DIR')) {
            $script:savedVariables[$name] = [System.Environment]::GetEnvironmentVariable($name)
            if (-not $script:savedVariables[$name]) {
                [System.Environment]::SetEnvironmentVariable($name, (Join-Path $TestDrive $name))
            }
        }

        $script:configDir = InModuleScope 'Avm.Authoring' { Resolve-AvmTflintConfigDir }
        $script:tflint = InModuleScope 'Avm.Authoring' { Resolve-AvmTool -Name tflint }
        $null = InModuleScope 'Avm.Authoring' { Resolve-AvmTool -Name terraform }
        InModuleScope 'Avm.Authoring' -Parameters @{
            ConfigDir = $script:configDir
            Tool = $script:tflint
            Root = "$TestDrive"
        } {
            param($ConfigDir, $Tool, $Root)
            foreach ($name in @('avm.tflint.hcl', 'avm.tflint_module.hcl', 'avm.tflint_example.hcl')) {
                $init = Invoke-AvmProcess -FilePath $Tool.Path `
                    -ArgumentList @('--init', '--config', (Join-Path $ConfigDir $name)) `
                    -WorkingDirectory $Root -IgnoreExitCode
                $init.ExitCode | Should -Be 0 -Because $init.StdErr
            }
        }
    }

AfterAll {
        foreach ($name in $script:savedVariables.Keys) {
            $value = if ($null -eq $script:savedVariables[$name]) {
                [NullString]::Value
            }
            else {
                $script:savedVariables[$name]
            }
            [System.Environment]::SetEnvironmentVariable($name, $value)
        }
        Remove-Module -Name Avm.Authoring -Force -ErrorAction SilentlyContinue
    }

It 'accepts generated telemetry-only locations with the released root and submodule lint profiles' {
        $root = Join-Path $TestDrive 'telemetry-location'
        $null = New-Item -ItemType Directory -Path $root
        [IO.File]::WriteAllText((Join-Path $root 'variables.tf'), @'
variable "location" {
  type     = string
  nullable = false
}

variable "enable_telemetry" {
  type    = bool
  default = true
}
'@)
        [IO.File]::WriteAllText((Join-Path $root 'main.telemetry.tf'), @'
locals {
  main_location = var.location
}

resource "azapi_resource" "telemetry" {
  count    = var.enable_telemetry ? 1 : 0
  type     = "Microsoft.Resources/deployments@2025-04-01"
  location = local.main_location
}
'@)
        InModuleScope 'Avm.Authoring' -Parameters @{
            Root = $root; ConfigDir = $script:configDir; Tflint = $script:tflint.Path
        } {
            param($Root, $ConfigDir, $Tflint)
            $mapotf = Resolve-AvmTool -Name mapotf
            $profile = Resolve-AvmMapotfConfigDir -Root $Root -ProfileName 'module-call'
            $null = Invoke-AvmProcess -FilePath $mapotf.Path -WorkingDirectory $Root -ArgumentList @(
                'transform', '--tf-dir', $Root, '--mptf-dir', $profile
            )
            $variablesPath = Join-Path $Root 'variables.tf'
            $content = [IO.File]::ReadAllText($variablesPath)
            $content | Should -Match 'default\s*=\s*null'
            $content | Should -Match '!var.enable_telemetry \|\| var.location != null'
            foreach ($config in @('avm.tflint.hcl', 'avm.tflint_module.hcl')) {
                $arguments = @('--config', (Join-Path $ConfigDir $config), '--only=avm_interface_location', '--format=json')
                $lint = Invoke-AvmProcess -FilePath $Tflint -WorkingDirectory $Root -ArgumentList $arguments -IgnoreExitCode
                $lint.ExitCode | Should -Be 0 -Because ($lint.StdOut + $lint.StdErr)
            }
            [IO.File]::WriteAllText($variablesPath, $content.Replace(
                '!var.enable_telemetry || var.location != null', 'var.location == null || var.location != null'))
            $invalid = Invoke-AvmProcess -FilePath $Tflint -WorkingDirectory $Root -IgnoreExitCode -ArgumentList @(
                '--config', (Join-Path $ConfigDir 'avm.tflint.hcl'), '--only=avm_interface_location', '--format=json'
            )
            $invalid.ExitCode | Should -Not -Be 0
            ($invalid.StdOut | ConvertFrom-Json).issues.rule.name | Should -Contain 'avm_interface_location'
        }
    }

It 'lints sibling composition in the staged repository without changing the checkout' {
        $root = Join-Path $TestDrive 'sibling-composition'
        $sources = [ordered]@{
            '.' = './modules/part'
            'modules/part' = '../part-component'
            'modules/part-component' = $null
            'examples/default' = '../..'
        }
        foreach ($scope in $sources.Keys) {
            $directory = Join-Path $root $scope
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            $value = '"fixture-id"'
            $main = ''
            if ($sources[$scope]) {
                $main = "module `"child`" {`n  source = `"$($sources[$scope])`"`n}`n"
                $value = 'module.child.resource_id'
            }
            $main += @"
output "resource_id" {
  value = $value
  description = "The composed fixture identifier."
}
"@
            [System.IO.File]::WriteAllText((Join-Path $directory 'main.tf'), $main)
            [System.IO.File]::WriteAllText((Join-Path $directory 'terraform.tf'), @'
terraform {
  required_version = ">= 1.9.0"
}
'@)
        }
        $before = @(Get-ChildItem -LiteralPath $root -File -Recurse |
                Sort-Object FullName |
                Get-FileHash)
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ Root = $root } {
            param($Root)
            Invoke-AvmTerraformLint -Context ([pscustomobject]@{
                    Kind = 'terraform-module-repo'
                    Root = $Root
                    Ecosystem = 'terraform'
                    Source = 'integration'
                }) -ThrottleLimit 1
        }

        $result.FilesProcessed | Should -Be 8
        @($result.Issues | Where-Object Code -eq 'avm_terraform_module_source_required') | Should -BeNullOrEmpty
        $after = @(Get-ChildItem -LiteralPath $root -File -Recurse |
                Sort-Object FullName |
                Get-FileHash)
        $after.Path | Should -Be $before.Path
        $after.Hash | Should -Be $before.Hash
        @(Get-ChildItem -LiteralPath $root -Directory -Filter '.terraform' -Recurse -Force) | Should -BeNullOrEmpty
    }
}
