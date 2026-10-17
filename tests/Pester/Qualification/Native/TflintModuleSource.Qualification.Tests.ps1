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
