#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmPrCheck' {
    It 'is exported by the manifest' {
        (Get-Command Invoke-AvmPrCheck -Module Avm.Authoring -ErrorAction Stop) |
            Should -Not -BeNullOrEmpty
    }

    It 'is wired into the verb registry as "avm pr-check"' {
        $reg = InModuleScope 'Avm.Authoring' { Get-AvmVerbRegistry }
        $entry = $reg | Where-Object { $_.Path.Count -eq 1 -and $_.Path[0] -eq 'pr-check' }
        $entry          | Should -Not -BeNullOrEmpty
        $entry.Cmdlet   | Should -Be 'Invoke-AvmPrCheck'
    }

    It 'composes all seven steps in the expected order on a passing chain' {
        $dir = Join-Path $TestDrive ("prcheck-pass-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmTransform { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmLint { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmTest { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmDocs { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Invoke-AvmPrCheck -Path $D
        }

        $result.Status                    | Should -Be 'pass'
        $result.Ecosystem                 | Should -Be 'bicep'
        $result.Steps.Count               | Should -Be 7
        $result.Steps[0].Step             | Should -Be 'format'
        $result.Steps[1].Step             | Should -Be 'transform'
        $result.Steps[2].Step             | Should -Be 'lint'
        $result.Steps[3].Step             | Should -Be 'check policy'
        $result.Steps[4].Step             | Should -Be 'check convention'
        $result.Steps[5].Step             | Should -Be 'test'
        $result.Steps[6].Step             | Should -Be 'docs'
        ($result.Steps | ForEach-Object Status | Select-Object -Unique) | Should -Be 'pass'
    }

    It 'reports a stubbed engine (AvmConfigurationException) as skipped and continues the chain' {
        $dir = Join-Path $TestDrive ("prcheck-skip-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmTransform { throw [AvmConfigurationException]::new('transform not wired yet') }
            Mock Invoke-AvmLint { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmCheckPolicy { throw [AvmConfigurationException]::new('check policy not wired yet') }
            Mock Invoke-AvmCheckConvention { throw [AvmConfigurationException]::new('check convention not wired yet') }
            Mock Invoke-AvmTest { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmDocs { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Invoke-AvmPrCheck -Path $D
        }

        $result.Status                                  | Should -Be 'pass'
        $result.Steps.Count                             | Should -Be 7
        ($result.Steps | Where-Object Status -eq 'skipped').Count | Should -Be 3
        ($result.Steps | Where-Object Step -eq 'transform').Status         | Should -Be 'skipped'
        ($result.Steps | Where-Object Step -eq 'check policy').Status      | Should -Be 'skipped'
        ($result.Steps | Where-Object Step -eq 'check convention').Status  | Should -Be 'skipped'
        ($result.Steps | Where-Object Step -eq 'docs').Status              | Should -Be 'pass'
    }

    It 'flips overall to fail when any step returns Status=fail but continues by default' {
        $dir = Join-Path $TestDrive ("prcheck-fail-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmTransform { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmLint { [pscustomobject]@{ Engine = 'bicep'; Status = 'fail' } }
            Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmTest { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmDocs { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Invoke-AvmPrCheck -Path $D
        }

        $result.Status                                | Should -Be 'fail'
        $result.Steps.Count                           | Should -Be 7
        ($result.Steps | Where-Object Step -eq 'lint').Status | Should -Be 'fail'
        ($result.Steps | Where-Object Step -eq 'docs').Status | Should -Be 'pass'
    }

    It '-StopOnFail aborts the chain after the first Status=fail' {
        $dir = Join-Path $TestDrive ("prcheck-stop-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmTransform { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmLint { [pscustomobject]@{ Engine = 'bicep'; Status = 'fail' } }
            Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmTest { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmDocs { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Invoke-AvmPrCheck -Path $D -StopOnFail
        }

        $result.Status                       | Should -Be 'fail'
        $result.Steps.Count                  | Should -Be 3
        $result.Steps[-1].Step               | Should -Be 'lint'
        $result.Steps[-1].Status             | Should -Be 'fail'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmCheckPolicy -Times 0
            Should -Invoke Invoke-AvmCheckConvention -Times 0
            Should -Invoke Invoke-AvmTest -Times 0
            Should -Invoke Invoke-AvmDocs -Times 0
        }
    }

    It 'aborts the chain and flips overall to error on a thrown non-AvmConfigurationException' {
        $dir = Join-Path $TestDrive ("prcheck-err-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmTransform { throw [System.InvalidOperationException]::new('engine blew up') }
            Mock Invoke-AvmLint { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmTest { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmDocs { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Invoke-AvmPrCheck -Path $D
        }

        $result.Status                       | Should -Be 'error'
        $result.Steps.Count                  | Should -Be 2
        $result.Steps[-1].Step               | Should -Be 'transform'
        $result.Steps[-1].Status             | Should -Be 'error'
        $result.Steps[-1].Error              | Should -Match 'engine blew up'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmLint -Times 0
            Should -Invoke Invoke-AvmDocs -Times 0
        }
    }
}
