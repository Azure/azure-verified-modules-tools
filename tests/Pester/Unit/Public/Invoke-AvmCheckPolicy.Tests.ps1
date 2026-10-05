#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmCheckPolicy' {
    It 'is exported by the manifest' {
        (Get-Command Invoke-AvmCheckPolicy -Module Avm.Authoring -ErrorAction Stop) |
            Should -Not -BeNullOrEmpty
    }

    It 'is wired into the verb registry as "avm check policy"' {
        $reg = InModuleScope 'Avm.Authoring' { Get-AvmVerbRegistry }
        $entry = $reg | Where-Object {
            $_.Path.Count -eq 2 -and $_.Path[0] -eq 'check' -and $_.Path[1] -eq 'policy'
        }
        $entry          | Should -Not -BeNullOrEmpty
        $entry.Cmdlet   | Should -Be 'Invoke-AvmCheckPolicy'
    }

    It 'dispatches a bicep context to Invoke-AvmBicepCheckPolicy' {
        $dir = Join-Path $TestDrive ("bicep-checkp-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmBicepCheckPolicy {
                [pscustomobject]@{ Engine = 'bicep'; Status = 'pass'; Issues = @() }
            }
            Mock Invoke-AvmTerraformCheckPolicy { throw 'wrong engine' }
            $result = Invoke-AvmCheckPolicy -Path $D
            $result.Engine | Should -Be 'bicep'
            Should -Invoke Invoke-AvmBicepCheckPolicy -Exactly 1
            Should -Invoke Invoke-AvmTerraformCheckPolicy -Times 0 -Exactly
        }
    }

    It 'dispatches a terraform context to Invoke-AvmTerraformCheckPolicy' {
        $dir = Join-Path $TestDrive ("tf-checkp-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmTerraformCheckPolicy {
                [pscustomobject]@{ Engine = 'terraform'; Status = 'pass'; Issues = @() }
            }
            Mock Invoke-AvmBicepCheckPolicy { throw 'wrong engine' }
            $result = Invoke-AvmCheckPolicy -Path $D -ThrottleLimit 6
            $result.Engine | Should -Be 'terraform'
            Should -Invoke Invoke-AvmTerraformCheckPolicy -Exactly 1 -ParameterFilter {
                $ThrottleLimit -eq 6
            }
            Should -Invoke Invoke-AvmBicepCheckPolicy -Times 0 -Exactly
        }
    }

    It 'fails closed if no Bicep policy test sources can be selected' {
        $result = InModuleScope 'Avm.Authoring' {
            Invoke-AvmBicepCheckPolicy -Context ([pscustomobject]@{
                    Ecosystem = 'bicep'; Kind = 'bicep-module'; Root = $TestDrive
                })
        }
        $result.Status | Should -Be 'fail'
        $result.ToolSource | Should -Be 'not-run'
        $result.RequiredBaselines.Count | Should -Be 2
        $result.AdvisoryBaselines.Count | Should -Be 2
        $result.Issues.Code | Should -Contain 'avm.bicep.psrule-input-missing'
    }

    It 'forwards Bicep selectors through both the public command and CLI' {
        InModuleScope Avm.Authoring {
            Mock Get-AvmModuleContext {
                [pscustomobject]@{ Root = $TestDrive; Ecosystem = 'bicep' }
            }
            Mock Invoke-AvmBicepCheckPolicy {
                [pscustomobject]@{ Status = 'pass'; Engine = 'bicep'; Issues = @() }
            }
            $example = 'tests/e2e/defaults/main.test.bicep'
            $null = Invoke-AvmCheckPolicy -Path $TestDrive -Example $example -Baseline Azure.Default -SkipModuleVersionCheck
            $null = Invoke-Avm check policy --path $TestDrive --example $example --baseline Azure.Default --passthru -SkipModuleVersionCheck
            Should -Invoke Invoke-AvmBicepCheckPolicy -Exactly 2 -ParameterFilter {
                $Example.Count -eq 1 -and $Example[0] -ceq 'tests/e2e/defaults/main.test.bicep' -and
                $Baseline.Count -eq 1 -and $Baseline[0] -ceq 'Azure.Default'
            }
            Should -Invoke Get-AvmModuleContext -Exactly 2 -ParameterFilter { $SkipModuleVersionCheck }
        }
    }

    It 'rejects Bicep selectors for Terraform instead of ignoring them' {
        InModuleScope Avm.Authoring {
            Mock Get-AvmModuleContext {
                [pscustomobject]@{ Root = $TestDrive; Ecosystem = 'terraform' }
            }
            Mock Invoke-AvmTerraformCheckPolicy { throw 'Must not evaluate.' }
            { Invoke-AvmCheckPolicy -Path $TestDrive -Baseline Azure.Default -SkipModuleVersionCheck } |
                Should -Throw '*only supported for Bicep*'
            Should -Invoke Invoke-AvmTerraformCheckPolicy -Exactly 0
        }
    }
}
