#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmTestE2e' {
    It 'is exported by the manifest' {
        (Get-Command Invoke-AvmTestE2e -Module Avm.Authoring -ErrorAction Stop) |
            Should -Not -BeNullOrEmpty
    }

    It 'is wired into the verb registry as "avm test e2e"' {
        $reg = InModuleScope 'Avm.Authoring' { Get-AvmVerbRegistry }
        $entry = $reg | Where-Object { $_.Path.Count -eq 2 -and $_.Path[0] -eq 'test' -and $_.Path[1] -eq 'e2e' }
        $entry        | Should -Not -BeNullOrEmpty
        $entry.Cmdlet | Should -Be 'Invoke-AvmTestE2e'
    }

    It 'dispatches a terraform context to Invoke-AvmTerraformTestE2e' {
        $dir = Join-Path $TestDrive ("tf-e2e-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $ctx = [pscustomobject]@{
                Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
            }
            Mock Get-AvmModuleContext { $ctx }
            Mock Invoke-AvmTerraformTestE2e {
                param($Context)
                [pscustomobject]@{ Engine = 'terraform'; Status = 'pass'; FilesProcessed = 1; Issues = @() }
            }
            Invoke-AvmTestE2e -Path $D
        }
        $result.Engine | Should -Be 'terraform'
        $result.Status | Should -Be 'pass'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmTerraformTestE2e -Exactly 1
        }
    }

    It 'forwards -AllowPathFallback to the engine' {
        $dir = Join-Path $TestDrive ("apf-e2e-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $ctx = [pscustomobject]@{
                Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
            }
            Mock Get-AvmModuleContext { $ctx }
            Mock Invoke-AvmTerraformTestE2e {
                [pscustomobject]@{ Engine = 'terraform'; Status = 'pass'; FilesProcessed = 0; Issues = @() }
            }
            Invoke-AvmTestE2e -Path $D -AllowPathFallback | Out-Null

            Should -Invoke Invoke-AvmTerraformTestE2e -Exactly 1 -ParameterFilter { $AllowPathFallback.IsPresent }
        }
    }

    It 'routes a bicep context and explicit deployment inputs to the Bicep engine' {
        $dir = Join-Path $TestDrive ("bicep-e2e-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $ctx = [pscustomobject]@{
                Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
            }
            Mock Get-AvmModuleContext { $ctx }
            Mock Invoke-AvmTerraformTestE2e { throw 'Terraform must not run' }
            Mock Invoke-AvmBicepTestE2e {
                [pscustomobject]@{ Engine = 'bicep'; Status = 'pass'; RunsPassed = 1 }
            }
            $result = Invoke-AvmTestE2e -Path $D -Example 'defaults' -Recurse `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -Location 'westus' -ResourceGroupPrefix 'avm-test' `
                -Tokens @{ namePrefix = 'demo' } -Parameters @{ sku = 'Standard_LRS' } `
                -SkipModuleVersionCheck

            $result.Engine | Should -Be 'bicep'
            Should -Invoke Invoke-AvmBicepTestE2e -Exactly 1 -ParameterFilter {
                $Example[0] -eq 'defaults' -and $Recurse.IsPresent -and
                $SubscriptionId -eq '00000000-0000-0000-0000-000000000001' -and
                $Location -eq 'westus' -and $ResourceGroupPrefix -eq 'avm-test' -and
                $Tokens.namePrefix -eq 'demo' -and $Parameters.sku -eq 'Standard_LRS'
            }
            Should -Invoke Invoke-AvmTerraformTestE2e -Exactly 0
        }
    }

    It 'rejects ecosystem-specific options before invoking the wrong engine' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-AvmModuleContext {
                [pscustomobject]@{ Root = '.'; Ecosystem = $Ecosystem }
            }
            Mock Invoke-AvmBicepTestE2e { throw 'Bicep engine must not run' }
            Mock Invoke-AvmTerraformTestE2e { throw 'Terraform engine must not run' }
            { Invoke-AvmTestE2e -Ecosystem bicep -MaxRetry 1 -SkipModuleVersionCheck } |
                Should -Throw -ExpectedMessage '*MaxRetry*only supported for Terraform*'
            { Invoke-AvmTestE2e -Ecosystem terraform -ResourceGroupPrefix 'avm' `
                    -SkipModuleVersionCheck } |
                Should -Throw -ExpectedMessage '*not supported for Terraform*'
            { Invoke-AvmTestE2e -Ecosystem terraform -WhatIf `
                    -SkipModuleVersionCheck } |
                Should -Throw -ExpectedMessage '*not supported for Terraform*'
            Should -Invoke Invoke-AvmBicepTestE2e -Exactly 0
            Should -Invoke Invoke-AvmTerraformTestE2e -Exactly 0
        }
    }

    It 'forwards -Ecosystem to Get-AvmModuleContext' {
        $dir = Join-Path $TestDrive ("eco-fwd-e2e-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $script:eco = $null
            Mock Get-AvmModuleContext {
                param($Path, $Ecosystem)
                $script:eco = $Ecosystem
                [pscustomobject]@{
                    Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmTerraformTestE2e {
                [pscustomobject]@{ Engine = 'terraform'; Status = 'pass'; FilesProcessed = 0; Issues = @() }
            }
            Invoke-AvmTestE2e -Path $D -Ecosystem 'terraform' | Out-Null
            $script:eco | Should -Be 'terraform'
        }
    }
}

Describe 'Invoke-AvmTestE2e per-example targeting (F26/F27)' {
    It 'forwards -Example to the engine' {
        $dir = Join-Path $TestDrive ("fwd-ex-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $ctx = [pscustomobject]@{
                Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
            }
            Mock Get-AvmModuleContext { $ctx }
            Mock Invoke-AvmTerraformTestE2e {
                [pscustomobject]@{ Engine = 'terraform'; Status = 'pass'; FilesProcessed = 1; Issues = @() }
            }
            Invoke-AvmTestE2e -Path $D -Example 'example-a' | Out-Null

            Should -Invoke Invoke-AvmTerraformTestE2e -Exactly 1 -ParameterFilter {
                $Example.Count -eq 1 -and $Example[0] -eq 'example-a'
            }
        }
    }

    It 'forwards -List to the engine' {
        $dir = Join-Path $TestDrive ("fwd-list-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $ctx = [pscustomobject]@{
                Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
            }
            Mock Get-AvmModuleContextInternal { $ctx }
            Mock Test-AvmModuleVersion { throw 'Offline listing must not query PowerShell Gallery' }
            Mock Invoke-AvmTerraformTestE2e { '["example-a"]' }
            $out = Invoke-AvmTestE2e -Path $D -List

            $out | Should -Be '["example-a"]'
            Should -Invoke Invoke-AvmTerraformTestE2e -Exactly 1 -ParameterFilter { $List.IsPresent }
            Should -Invoke Test-AvmModuleVersion -Exactly 0
        }
    }

    It 'lists Bicep cases through the CLI without a Gallery check or Azure tools' {
        $root = Join-Path $TestDrive ('offline-e2e-' + [guid]::NewGuid().ToString('N'))
        $caseDir = Join-Path $root 'tests' 'e2e' 'defaults'
        $null = New-Item -ItemType Directory -Path $caseDir -Force
        Set-Content -LiteralPath (Join-Path $root 'main.bicep') `
            -Value 'param name string' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $caseDir 'main.test.bicep') `
            -Value 'param name string' -Encoding utf8NoBOM
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $root } {
            param($R)
            Mock Test-AvmModuleVersion { throw 'Offline listing must not check the Gallery' }
            Mock Resolve-AvmTool { throw 'Offline listing must not resolve Bicep' }
            $result = Invoke-Avm 'test' 'e2e' '--ecosystem' 'bicep' `
                '--path' $R '--list'
            $result | Should -Be '["tests/e2e/defaults"]'
            Should -Invoke Test-AvmModuleVersion -Exactly 0
            Should -Invoke Resolve-AvmTool -Exactly 0
        }
    }

    It 'binds the kebab-case CLI flags --example and --list' {
        $reg = InModuleScope 'Avm.Authoring' { Get-AvmVerbRegistry }
        $entry = $reg | Where-Object { $_.Path.Count -eq 2 -and $_.Path[0] -eq 'test' -and $_.Path[1] -eq 'e2e' }
        $cmd = Get-Command $entry.Cmdlet -Module Avm.Authoring
        $cmd.Parameters.ContainsKey('Example') | Should -BeTrue
        $cmd.Parameters.ContainsKey('List')    | Should -BeTrue
        $cmd.Parameters['Example'].ParameterType.FullName | Should -Be 'System.String[]'
        $cmd.Parameters['List'].SwitchParameter           | Should -BeTrue
    }
}
