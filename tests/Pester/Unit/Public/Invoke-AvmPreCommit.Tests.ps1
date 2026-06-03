#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmPreCommit' {
    It 'is exported by the manifest' {
        (Get-Command Invoke-AvmPreCommit -Module Avm.Authoring -ErrorAction Stop) |
            Should -Not -BeNullOrEmpty
    }

    It 'is wired into the verb registry as "avm pre-commit"' {
        $reg = InModuleScope 'Avm.Authoring' { Get-AvmVerbRegistry }
        $entry = $reg | Where-Object { $_.Path.Count -eq 1 -and $_.Path[0] -eq 'pre-commit' }
        $entry          | Should -Not -BeNullOrEmpty
        $entry.Cmdlet   | Should -Be 'Invoke-AvmPreCommit'
    }

    It 'composes all four steps in the expected order on a passing chain (bicep)' {
        $dir = Join-Path $TestDrive ("precommit-bicep-pass-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmLint   { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmTest   { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmDocs   { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Invoke-AvmPreCommit -Path $D
        }

        $result.Status                    | Should -Be 'pass'
        $result.Ecosystem                 | Should -Be 'bicep'
        $result.Steps.Count               | Should -Be 4
        $result.Steps[0].Step             | Should -Be 'format'
        $result.Steps[1].Step             | Should -Be 'lint'
        $result.Steps[2].Step             | Should -Be 'test'
        $result.Steps[3].Step             | Should -Be 'docs'
        ($result.Steps | ForEach-Object Status | Select-Object -Unique) | Should -Be 'pass'
    }

    It 'composes all six steps in the expected order on a passing chain (terraform) and forwards the ecosystem to every step' {
        $dir = Join-Path $TestDrive ("precommit-tf-pass-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'terraform-module'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTransform       { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmFormat          { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmLint            { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTest            { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmDocs            { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            $r = Invoke-AvmPreCommit -Path $D

            Should -Invoke Invoke-AvmCheckConvention -Times 1 -ParameterFilter { $Ecosystem -eq 'terraform' }
            Should -Invoke Invoke-AvmTransform       -Times 1 -ParameterFilter { $Ecosystem -eq 'terraform' }
            Should -Invoke Invoke-AvmFormat          -Times 1 -ParameterFilter { $Ecosystem -eq 'terraform' }
            Should -Invoke Invoke-AvmLint            -Times 1 -ParameterFilter { $Ecosystem -eq 'terraform' }
            Should -Invoke Invoke-AvmTest            -Times 1 -ParameterFilter { $Ecosystem -eq 'terraform' }
            Should -Invoke Invoke-AvmDocs            -Times 1 -ParameterFilter { $Ecosystem -eq 'terraform' }

            $r
        }

        $result.Status                    | Should -Be 'pass'
        $result.Ecosystem                 | Should -Be 'terraform'
        $result.Steps.Count               | Should -Be 6
        $result.Steps[0].Step             | Should -Be 'check convention'
        $result.Steps[1].Step             | Should -Be 'transform'
        $result.Steps[2].Step             | Should -Be 'format'
        $result.Steps[3].Step             | Should -Be 'lint'
        $result.Steps[4].Step             | Should -Be 'test'
        $result.Steps[5].Step             | Should -Be 'docs'
        ($result.Steps | ForEach-Object Status | Select-Object -Unique) | Should -Be 'pass'
    }

    It 'reports a stubbed engine (AvmConfigurationException) as skipped and continues the chain (terraform)' {
        $dir = Join-Path $TestDrive ("precommit-tf-skip-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'terraform-module'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTransform       { throw [AvmConfigurationException]::new('transform engine not wired yet') }
            Mock Invoke-AvmFormat          { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmLint            { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTest            { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmDocs            { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Invoke-AvmPreCommit -Path $D
        }

        $result.Status                                                 | Should -Be 'pass'
        $result.Steps.Count                                            | Should -Be 6
        ($result.Steps | Where-Object Status -eq 'skipped').Count      | Should -Be 1
        ($result.Steps | Where-Object Step -eq 'transform').Status     | Should -Be 'skipped'
        ($result.Steps | Where-Object Step -eq 'transform').Error      | Should -Match 'not wired'
    }

    It 'flips overall to fail when any step returns Status=fail but continues by default' {
        $dir = Join-Path $TestDrive ("precommit-fail-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'terraform-module'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTransform       { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmFormat          { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmLint            { [pscustomobject]@{ Engine = 'terraform'; Status = 'fail' } }
            Mock Invoke-AvmTest            { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmDocs            { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Invoke-AvmPreCommit -Path $D
        }

        $result.Status                                        | Should -Be 'fail'
        $result.Steps.Count                                   | Should -Be 6
        ($result.Steps | Where-Object Step -eq 'lint').Status | Should -Be 'fail'
        ($result.Steps | Where-Object Step -eq 'docs').Status | Should -Be 'pass'
    }

    It '-StopOnFail aborts the chain after the first Status=fail' {
        $dir = Join-Path $TestDrive ("precommit-stop-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'terraform-module'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTransform       { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmFormat          { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmLint            { [pscustomobject]@{ Engine = 'terraform'; Status = 'fail' } }
            Mock Invoke-AvmTest            { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmDocs            { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Invoke-AvmPreCommit -Path $D -StopOnFail
        }

        $result.Status                       | Should -Be 'fail'
        $result.Steps.Count                  | Should -Be 4
        $result.Steps[-1].Step               | Should -Be 'lint'
        $result.Steps[-1].Status             | Should -Be 'fail'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmTest -Times 0
            Should -Invoke Invoke-AvmDocs -Times 0
        }
    }

    It 'aborts the chain and flips overall to error on a thrown non-AvmConfigurationException' {
        $dir = Join-Path $TestDrive ("precommit-err-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'terraform-module'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTransform       { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmFormat          { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmLint            { throw [System.InvalidOperationException]::new('engine blew up') }
            Mock Invoke-AvmTest            { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmDocs            { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Invoke-AvmPreCommit -Path $D
        }

        $result.Status                       | Should -Be 'error'
        $result.Steps.Count                  | Should -Be 4
        $result.Steps[-1].Step               | Should -Be 'lint'
        $result.Steps[-1].Status             | Should -Be 'error'
        $result.Steps[-1].Error              | Should -Match 'engine blew up'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmTest -Times 0
            Should -Invoke Invoke-AvmDocs -Times 0
        }
    }
}
