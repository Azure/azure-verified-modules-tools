#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmCheckConvention' {
    It 'is exported by the manifest' {
        (Get-Command Invoke-AvmCheckConvention -Module Avm.Authoring -ErrorAction Stop) |
            Should -Not -BeNullOrEmpty
    }

    It 'is wired into the verb registry as "avm check convention"' {
        $reg = InModuleScope 'Avm.Authoring' { Get-AvmVerbRegistry }
        $entry = $reg | Where-Object {
            $_.Path.Count -eq 2 -and $_.Path[0] -eq 'check' -and $_.Path[1] -eq 'convention'
        }
        $entry          | Should -Not -BeNullOrEmpty
        $entry.Cmdlet   | Should -Be 'Invoke-AvmCheckConvention'
    }

    It 'dispatches a bicep context to Invoke-AvmBicepCheckConvention' {
        $dir = Join-Path $TestDrive ("bicep-checkc-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{
                    Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmBicepCheckConvention {
                [pscustomobject]@{ Engine = 'bicep'; Status = 'pass'; Issues = @() }
            }
            Mock Invoke-AvmTerraformCheckConvention { throw 'wrong engine' }
            $result = Invoke-AvmCheckConvention -Path $D
            $result.Engine | Should -Be 'bicep'
            Should -Invoke Invoke-AvmBicepCheckConvention -Exactly 1
            Should -Invoke Invoke-AvmTerraformCheckConvention -Times 0 -Exactly
        }
    }

    It 'dispatches a terraform context to Invoke-AvmTerraformCheckConvention' {
        $dir = Join-Path $TestDrive ("tf-checkc-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContextInternal {
                [pscustomobject]@{
                    Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }

            Mock Invoke-AvmTerraformCheckConvention {
                [pscustomobject]@{ Engine = 'terraform'; Status = 'pass'; Issues = @() }
            }
            Mock Invoke-AvmBicepCheckConvention { throw 'wrong engine' }
            $result = Invoke-AvmCheckConvention -Path $D -Fix -FixableOnly
            $result.Engine | Should -Be 'terraform'
            Should -Invoke Invoke-AvmTerraformCheckConvention -Exactly 1 -ParameterFilter {
                $Fix -eq $true -and $FixableOnly -eq $true
            }
            Should -Invoke Invoke-AvmBicepCheckConvention -Times 0 -Exactly
        }
    }

    It 'reports an actionable failure when the bicep module layout is not known' {
        $result = InModuleScope 'Avm.Authoring' {
            Invoke-AvmBicepCheckConvention -Context ([pscustomobject]@{
                    Ecosystem = 'bicep'; Root = $TestDrive; Kind = 'bicep-module'
                })
        }
        $result.Status | Should -Be 'fail'
        $result.Issues.Code | Should -Contain 'avm.bicep.scope'
    }

    It 'fails closed when a Bicep monorepo contains no discoverable module scopes' {
        $result = InModuleScope 'Avm.Authoring' {
            Mock Get-AvmMetadataScope { @() }
            Invoke-AvmBicepCheckConvention -Context ([pscustomobject]@{
                    Ecosystem = 'bicep'; Root = $TestDrive; Kind = 'bicep-monorepo'
                })
        }
        $result.Status | Should -Be 'fail'
        $result.ScopesChecked | Should -Be 0
        $result.UncoveredFamilies.Count | Should -Be 0
        $result.Issues.Count | Should -Be 1
        $result.Issues[0].Code | Should -Be 'avm.bicep.scope'
        $result.Issues[0].Severity | Should -Be 'error'
    }

    It 'the terraform engine returns a real envelope and no longer throws AvmNotSupportedException' {
        $result = InModuleScope 'Avm.Authoring' {
            Invoke-AvmTerraformCheckConvention -Context ([pscustomobject]@{ Ecosystem = 'terraform'; Root = $TestDrive })
        }
        $result.Engine     | Should -Be 'terraform'
        $result.Tool       | Should -Be 'avm-rules/1'
        $result.ToolSource | Should -Be 'builtin'
        # Status is governed by Issue severities, never throws for missing config.
        @('pass', 'fail') | Should -Contain $result.Status
    }
}
