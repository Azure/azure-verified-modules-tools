#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Integration: TFLint module sources' -Tag 'Integration' -Skip:($env:AVM_OFFLINE -eq '1') {
    BeforeAll {
        $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring'
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

    It 'validates <Source> in the <Scope> scope' -ForEach @(
        @{ Scope = 'root'; Source = './modules/part'; Expected = 0 }
        @{ Scope = 'root'; Source = './modules/part/'; Expected = 0 }
        @{ Scope = 'root'; Source = '../part'; Expected = 1 }
        @{ Scope = 'root'; Source = './modules/part/nested'; Expected = 1 }
        @{ Scope = 'root'; Source = './modules/.'; Expected = 1 }
        @{ Scope = 'root'; Source = './modules/..'; Expected = 1 }
        @{ Scope = 'root'; Source = 'Azure/avm-res-keyvault-vault/azurerm'; Expected = 0 }
        @{ Scope = 'submodule'; Source = '../route-table-route'; Expected = 0 }
        @{ Scope = 'submodule'; Source = '../route-table-route/'; Expected = 0 }
        @{ Scope = 'submodule'; Source = '../network-security-group-security-rule'; Expected = 0 }
        @{ Scope = 'submodule'; Source = '../../other'; Expected = 1 }
        @{ Scope = 'submodule'; Source = '../part/nested'; Expected = 1 }
        @{ Scope = 'submodule'; Source = '../.'; Expected = 1 }
        @{ Scope = 'submodule'; Source = '../..'; Expected = 1 }
        @{ Scope = 'submodule'; Source = '../'; Expected = 1 }
        @{ Scope = 'submodule'; Source = '..\part'; Expected = 1 }
        @{ Scope = 'submodule'; Source = './modules/nested'; Expected = 1 }
        @{ Scope = 'submodule'; Source = 'Azure/avm-res-keyvault-vault/azurerm'; Expected = 0 }
    ) {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $directory = if ($Scope -eq 'root') { $root } else { Join-Path $root 'modules' 'part' }
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $encodedSource = ConvertTo-Json -InputObject $Source -Compress
        [System.IO.File]::WriteAllText(
            (Join-Path $directory 'main.tf'),
            "module `"child`" {`n  source = $encodedSource`n}`n")
        $configName = if ($Scope -eq 'root') { 'avm.tflint.hcl' } else { 'avm.tflint_module.hcl' }
        $run = InModuleScope 'Avm.Authoring' -Parameters @{
            Directory = $directory
            Config = (Join-Path $script:configDir $configName)
            Tool = $script:tflint
        } {
            param($Directory, $Config, $Tool)
            Invoke-AvmProcess -FilePath $Tool.Path `
                -ArgumentList @(
                    '--config', $Config,
                    '--format=json',
                    '--call-module-type=none',
                    '--only=avm_terraform_module_source_required'
                ) `
                -WorkingDirectory $Directory -IgnoreExitCode
        }

        $expectedExit = if ($Expected -eq 0) { 0 } else { 2 }
        $run.ExitCode | Should -Be $expectedExit -Because "$($run.StdErr)`n$($run.StdOut)"
        $payload = $run.StdOut | ConvertFrom-Json
        $payload.errors | Should -BeNullOrEmpty
        $issues = @($payload.issues)
        $issues.Count | Should -Be $Expected
        if ($Expected -gt 0) {
            $issues[0].rule.name | Should -Be 'avm_terraform_module_source_required'
            $issues[0].rule.severity | Should -Be 'error'
            $issues[0].range.filename | Should -Be 'main.tf'
            $issues[0].range.start.line | Should -Be 2
        }
    }

    It 'keeps the module source rule disabled for examples' {
        $root = Join-Path $TestDrive 'example-exemption'
        $directory = Join-Path $root 'examples' 'default'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $directory 'main.tf'), @'
module "example" {
  source = "../.."
}
'@)
        $run = InModuleScope 'Avm.Authoring' -Parameters @{
            Directory = $directory
            Config = (Join-Path $script:configDir 'avm.tflint_example.hcl')
            Tool = $script:tflint
        } {
            param($Directory, $Config, $Tool)
            Invoke-AvmProcess -FilePath $Tool.Path `
                -ArgumentList @('--config', $Config, '--format=json', '--call-module-type=none') `
                -WorkingDirectory $Directory -IgnoreExitCode
        }

        $run.ExitCode | Should -BeIn @(0, 2) -Because "$($run.StdErr)`n$($run.StdOut)"
        $payload = $run.StdOut | ConvertFrom-Json
        $payload.errors | Should -BeNullOrEmpty
        @($payload.issues | Where-Object { $_.rule.name -eq 'avm_terraform_module_source_required' }) |
            Should -BeNullOrEmpty
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
