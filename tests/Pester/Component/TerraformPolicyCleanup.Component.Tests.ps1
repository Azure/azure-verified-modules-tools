#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: Terraform policy cleanup workers' -Tag 'Component' {
    It 'retains shared cleanup status across real workers: primary failure <PrimaryFails>, post failure <PostFails>' -TestCases @(
        @{ PrimaryFails = $false; PostFails = $true }
        @{ PrimaryFails = $false; PostFails = $false }
        @{ PrimaryFails = $true; PostFails = $true }
        @{ PrimaryFails = $true; PostFails = $false }
    ) {
        param($PrimaryFails, $PostFails)
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $root = Join-Path $caseRoot 'module'
        $cache = Join-Path $caseRoot 'cache'
        $bundle = Join-Path $caseRoot 'bundle'
        $null = New-Item -ItemType Directory -Path $bundle -Force
        Set-Content -LiteralPath (Join-Path $bundle 'avm_exceptions.rego.bak') -Value 'package avmsec'
        foreach ($name in @('first', 'second')) {
            $exampleRoot = Join-Path $root 'examples' $name
            $null = New-Item -ItemType Directory -Path $exampleRoot -Force
            Set-Content -LiteralPath (Join-Path $exampleRoot 'main.tf') -Value 'locals {}'
        }
        InModuleScope Avm.Authoring -Parameters @{
            Root = $root; Cache = $cache; Bundle = $bundle; PostFails = $PostFails; PrimaryFails = $PrimaryFails
        } {
            param($Root, $Cache, $Bundle, $PostFails, $PrimaryFails)
            $realParallel = ${function:Invoke-AvmParallel}
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = $Name; Version = 'test'; Source = 'cache'; Path = 'never-executed' }
            }
            Mock Resolve-AvmPolicyBundle { [pscustomobject]@{ Path = $Bundle } }
            Mock Get-AvmFolder { $Cache }
            Mock Write-AvmLog
            Mock Invoke-AvmParallel {
                & $realParallel -InputObject $InputObject -ThrottleLimit $ThrottleLimit -Argument @{
                    PostFails = $PostFails; PrimaryFails = $PrimaryFails
                } -ScriptBlock {
                    param($Example, $Failures)
                    $module = Get-Module Avm.Authoring
                    & $module {
                        param($Example, $Failures)
                        function Invoke-AvmScriptHook {
                            param($HookPath, $WorkingDirectory, $EnvVars, $Label)
                            if ($HookPath -like '*post.ps1' -and $Failures.PostFails -and $Example.Name -eq 'second') {
                                throw [AvmConfigurationException]::new('synthetic post failure')
                            }
                        }
                        function ConvertFrom-AvmDotEnv { param($Path) @{} }
                        function Lock-AvmTerraformPluginCache { param($WorkingDirectory, $EnvVars) $null }
                        function Initialize-AvmTerraformPolicyStage {
                            param($TerraformPath, $ConftestPath, $WorkingDirectory, $StageRoot, $EnvVars)
                        }
                        function Invoke-AvmProcess {
                            param($FilePath, $ArgumentList, $WorkingDirectory, $EnvVars, $Label, [switch] $IgnoreExitCode)
                            if ($ArgumentList[0] -eq 'plan' -and $Failures.PrimaryFails -and $Example.Name -eq 'second') {
                                throw [AvmProcessException]::new('synthetic primary failure')
                            }
                            $output = if ($ArgumentList[0] -eq 'show') { '{}' } else { '[]' }
                            [pscustomobject]@{ ExitCode = 0; StdOut = $output; StdErr = '' }
                        }
                        Invoke-AvmTerraformPolicyExample -Example $Example -Options ([pscustomobject]@{
                            TerraformPath = 'never-executed'; ConftestPath = 'never-executed'
                            AprlPath = 'synthetic'; AvmsecPath = 'synthetic'; DefaultExceptions = 'synthetic'
                        })
                    } $Example $Failures
                }
            }
            $caught = $null
            $result = $null
            try {
                $result = Invoke-AvmTerraformCheckPolicy -Context ([pscustomobject]@{
                    Ecosystem = 'terraform'; Root = $Root
                }) -ThrottleLimit 2
            }
            catch {
                $caught = $_
            }
            Should -Invoke Invoke-AvmParallel -Exactly 1 -ParameterFilter { $ThrottleLimit -eq 2 }
            $stages = @(Get-ChildItem -LiteralPath (Join-Path $Cache 'policy-stage') -Directory)
            if ($PostFails) {
                $expectedType = if ($PrimaryFails) { 'AvmProcessException' } else { 'AvmConfigurationException' }
                $caught.Exception.GetType().Name | Should -Be $expectedType
                if ($PrimaryFails) {
                    $caught.Exception.Data['AvmPolicyPostError'].Exception.GetType().Name |
                        Should -Be 'AvmConfigurationException'
                }
                $result | Should -BeNullOrEmpty
                $stages.Count | Should -Be 1
                $caught.Exception.Data['AvmPolicyStagePath'] | Should -Be $stages[0].FullName
                foreach ($index in @(0, 1)) {
                    Test-Path -LiteralPath (Join-Path $stages[0].FullName "$index" 'module') | Should -BeTrue
                }
            }
            else {
                if ($PrimaryFails) {
                    $caught.Exception.GetType().Name | Should -Be 'AvmProcessException'
                    $result | Should -BeNullOrEmpty
                }
                else {
                    $caught | Should -BeNullOrEmpty
                    $result.Status | Should -Be 'pass'
                }
                $stages.Count | Should -Be 0
            }
        }
    }
}
