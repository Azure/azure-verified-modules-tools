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
    BeforeEach {
        InModuleScope 'Avm.Authoring' {
            Mock Resolve-AvmCommandTool { @() }
        }
    }

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

    It 'suppresses nested routine narration by default and restores it in verbose mode' {
        $dir = Join-Path $TestDrive ("precommit-output-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $observed = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            $saved = @{
                Actions = $env:GITHUB_ACTIONS
                Runner  = $env:RUNNER_DEBUG
                Verbose = $env:AVM_VERBOSE
            }
            $env:GITHUB_ACTIONS = ''
            $env:RUNNER_DEBUG = ''
            $env:AVM_VERBOSE = ''
            try {
                Mock Get-AvmModuleContext {
                    [pscustomobject]@{
                        Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
                    }
                }
                Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
                Mock Invoke-AvmLint {
                    Write-AvmLog 'nested pre-commit info' -Level Info
                    Write-AvmLog 'nested pre-commit pass' -Level Pass
                    [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' }
                }
                Mock Invoke-AvmTest { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
                Mock Invoke-AvmDocs { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }

                $defaultOutput = @(Invoke-AvmPreCommit -Path $D 6>&1)

                $verboseOutput = @(Invoke-AvmPreCommit -Path $D -Verbose 4>$null 6>&1)

                [pscustomobject]@{
                    DefaultInfo = @(
                        $defaultOutput |
                            Where-Object { $_ -is [System.Management.Automation.InformationRecord] } |
                            ForEach-Object { [string]$_.MessageData }
                    )
                    VerboseInfo = @(
                        $verboseOutput |
                            Where-Object { $_ -is [System.Management.Automation.InformationRecord] } |
                            ForEach-Object { [string]$_.MessageData }
                    )
                }
            }
            finally {
                $env:GITHUB_ACTIONS = $saved.Actions
                $env:RUNNER_DEBUG = $saved.Runner
                $env:AVM_VERBOSE = $saved.Verbose
            }
        }

        ($observed.DefaultInfo -join "`n") | Should -Match 'step 2/4: lint'
        @($observed.DefaultInfo) | Should -Not -Contain 'nested pre-commit info'
        @($observed.DefaultInfo) | Should -Not -Contain 'nested pre-commit pass'
        @($observed.VerboseInfo) | Should -Contain 'nested pre-commit info'
        @($observed.VerboseInfo) | Should -Contain 'nested pre-commit pass'
    }

    It 'accepts every managed-files sync option on the CLI surface' {
        $command = Get-Command Invoke-AvmPreCommit -Module Avm.Authoring
        foreach ($parameterName in @(
                'ManagedFilesRepo'
                'ManagedFilesRef'
                'ManagedFilesPath'
                'ManagedFilesLocalPath'
                'ConfigRepo'
                'ConfigRef'
                'ConfigPath'
                'ConfigLocalPath'
                'RepoId'
            )) {
            $command.Parameters.ContainsKey($parameterName) | Should -BeTrue
            $command.Parameters[$parameterName].ParameterType | Should -Be ([string])
        }
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
        $result.Steps[2].Step             | Should -Be 'validate'
        $result.Steps[3].Step             | Should -Be 'docs'
        ($result.Steps | ForEach-Object Status | Select-Object -Unique) | Should -Be 'pass'
        InModuleScope 'Avm.Authoring' {
            Should -Invoke Resolve-AvmCommandTool -Exactly 1 -ParameterFilter {
                $Command -eq 'pre-commit' -and $Ecosystem -eq 'bicep'
            }
        }
    }

    It 'stamps StartTime, EndTime and DurationMs on the envelope and every step' {
        $dir = Join-Path $TestDrive ("precommit-timing-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
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

        $result.StartTime  | Should -BeOfType ([datetime])
        $result.EndTime    | Should -BeOfType ([datetime])
        $result.EndTime    | Should -BeGreaterOrEqual $result.StartTime
        $result.DurationMs | Should -BeGreaterOrEqual 0

        foreach ($step in $result.Steps) {
            $step.StartTime  | Should -BeOfType ([datetime])
            $step.EndTime    | Should -BeOfType ([datetime])
            $step.EndTime    | Should -BeGreaterOrEqual $step.StartTime
            $step.DurationMs | Should -BeGreaterOrEqual 0
        }
    }

    It 'composes all five steps in the expected order on a passing chain (terraform) and forwards the ecosystem to every step' {
        $dir = Join-Path $TestDrive ("precommit-tf-pass-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'terraform-module'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmSync            { [pscustomobject]@{ Engine = 'terraform'; Tool = 'managed-files'; Status = 'pass' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTransform       { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmFormat          { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmDocs            { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            # lint + test are pr-check-only on the terraform chain; pre-commit
            # must never call them. Mock them so the -Times 0 guard is meaningful.
            Mock Invoke-AvmLint            { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTest            { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            $r = Invoke-AvmPreCommit -Path $D

            Should -Invoke Invoke-AvmSync            -Exactly 1 -ParameterFilter { $Ecosystem -eq 'terraform' }
            Should -Invoke Invoke-AvmCheckConvention -Exactly 1 -ParameterFilter {
                $Ecosystem -eq 'terraform' -and $Fix -eq $true -and $FixableOnly -eq $true
            }
            Should -Invoke Invoke-AvmTransform       -Exactly 1 -ParameterFilter { $Ecosystem -eq 'terraform' }
            Should -Invoke Invoke-AvmFormat          -Exactly 1 -ParameterFilter { $Ecosystem -eq 'terraform' }
            Should -Invoke Invoke-AvmDocs            -Exactly 1 -ParameterFilter { $Ecosystem -eq 'terraform' }

            # pre-commit is the auto-fix surface: format and docs must rewrite
            # the working tree, never gate on drift the way pr-check does.
            Should -Invoke Invoke-AvmFormat -Times 0 -Exactly -ParameterFilter { $CheckDrift -eq $true }
            Should -Invoke Invoke-AvmDocs   -Times 0 -Exactly -ParameterFilter { $CheckDrift -eq $true }

            # lint + test are pr-check-only on the terraform chain; pre-commit must not call them.
            Should -Invoke Invoke-AvmLint -Times 0 -Exactly
            Should -Invoke Invoke-AvmTest -Times 0 -Exactly

            $r
        }

        $result.Status                    | Should -Be 'pass'
        $result.Ecosystem                 | Should -Be 'terraform'
        $result.Steps.Count               | Should -Be 5
        $result.Steps[0].Step             | Should -Be 'sync'
        $result.Steps[1].Step             | Should -Be 'check convention'
        $result.Steps[2].Step             | Should -Be 'transform'
        $result.Steps[3].Step             | Should -Be 'format'
        $result.Steps[4].Step             | Should -Be 'docs'
        ($result.Steps | ForEach-Object Status | Select-Object -Unique) | Should -Be 'pass'
    }

    It 'forwards explicitly supplied managed-files options only to the terraform sync step' {
        $dir = Join-Path $TestDrive ("precommit-tf-sync-options-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'terraform-module'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmSync            { [pscustomobject]@{ Engine = 'terraform'; Tool = 'managed-files'; Status = 'pass' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTransform       { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmFormat          { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmDocs            { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }

            $r = Invoke-AvmPreCommit `
                -Path $D `
                -Ecosystem terraform `
                -ManagedFilesRepo 'Contoso/managed-files' `
                -ManagedFilesRef 'refs/tags/v1.2.3' `
                -ManagedFilesPath 'distribution/managed-files' `
                -ManagedFilesLocalPath 'D:\managed-files' `
                -ConfigRepo 'Contoso/config' `
                -ConfigRef 'refs/tags/v4.5.6' `
                -ConfigPath 'config/repository' `
                -ConfigLocalPath 'D:\repository-config' `
                -RepoId 'avm-res-foo'

            Should -Invoke Invoke-AvmSync -Exactly 1 -ParameterFilter {
                $ManagedFilesRepo -eq 'Contoso/managed-files' -and
                $ManagedFilesRef -eq 'refs/tags/v1.2.3' -and
                $ManagedFilesPath -eq 'distribution/managed-files' -and
                $ManagedFilesLocalPath -eq 'D:\managed-files' -and
                $ConfigRepo -eq 'Contoso/config' -and
                $ConfigRef -eq 'refs/tags/v4.5.6' -and
                $ConfigPath -eq 'config/repository' -and
                $ConfigLocalPath -eq 'D:\repository-config' -and
                $RepoId -eq 'avm-res-foo'
            }
            Should -Invoke Invoke-AvmCheckConvention -Exactly 1
            Should -Invoke Invoke-AvmTransform -Exactly 1
            Should -Invoke Invoke-AvmFormat -Exactly 1
            Should -Invoke Invoke-AvmDocs -Exactly 1

            $r
        }

        $result.Status | Should -Be 'pass'
        $result.Steps.Step | Should -Be @('sync', 'check convention', 'transform', 'format', 'docs')
    }

    It 'reports a stubbed engine (AvmNotSupportedException) as skipped and continues the chain (terraform)' {
        $dir = Join-Path $TestDrive ("precommit-tf-skip-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'terraform-module'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmSync            { [pscustomobject]@{ Engine = 'terraform'; Tool = 'managed-files'; Status = 'pass' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTransform       { throw [AvmNotSupportedException]::new('transform engine not wired yet') }
            Mock Invoke-AvmFormat          { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmDocs            { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Invoke-AvmPreCommit -Path $D
        }

        $result.Status                                                 | Should -Be 'pass'
        $result.Steps.Count                                            | Should -Be 5
        ($result.Steps | Where-Object Status -eq 'skipped').Count      | Should -Be 1
        ($result.Steps | Where-Object Step -eq 'transform').Status     | Should -Be 'skipped'
        ($result.Steps | Where-Object Step -eq 'transform').Error      | Should -Match 'not wired'
    }

    # F39b: a plain AvmConfigurationException means the repo is misconfigured, not
    # that the verb is unsupported. Skipping it renders as a benign gauntlet pass -
    # exactly how a step that never actually ran gets to look green.
    It 'F39: fails the gauntlet on a configuration error but skips an unsupported verb' {
        $dir = Join-Path $TestDrive ("precommit-f39-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'terraform-module'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmSync            { throw [AvmConfigurationException]::new('managed-files repo id could not be resolved') }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTransform       { throw [AvmNotSupportedException]::new('transform engine not wired yet') }
            Mock Invoke-AvmFormat          { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmDocs            { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Invoke-AvmPreCommit -Path $D
        }

        ($result.Steps | Where-Object Step -eq 'sync').Status      | Should -Be 'fail'
        ($result.Steps | Where-Object Step -eq 'transform').Status | Should -Be 'skipped'
        $result.Status                                            | Should -Be 'fail'

        # 'fail' must not abort the chain the way 'error' does - the remaining
        # steps still run so one bad config does not mask the next.
        $result.Steps.Step | Should -Contain 'docs'
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
            Mock Invoke-AvmSync            { [pscustomobject]@{ Engine = 'terraform'; Tool = 'managed-files'; Status = 'pass' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTransform       { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmFormat          { [pscustomobject]@{ Engine = 'terraform'; Status = 'fail' } }
            Mock Invoke-AvmDocs            { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Invoke-AvmPreCommit -Path $D
        }

        $result.Status                                          | Should -Be 'fail'
        $result.Steps.Count                                     | Should -Be 5
        ($result.Steps | Where-Object Step -eq 'format').Status | Should -Be 'fail'
        ($result.Steps | Where-Object Step -eq 'docs').Status   | Should -Be 'pass'
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
            Mock Invoke-AvmSync            { [pscustomobject]@{ Engine = 'terraform'; Tool = 'managed-files'; Status = 'pass' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTransform       { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmFormat          { [pscustomobject]@{ Engine = 'terraform'; Status = 'fail' } }
            Mock Invoke-AvmDocs            { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Invoke-AvmPreCommit -Path $D -StopOnFail
        }

        $result.Status                       | Should -Be 'fail'
        $result.Steps.Count                  | Should -Be 4
        $result.Steps[-1].Step               | Should -Be 'format'
        $result.Steps[-1].Status             | Should -Be 'fail'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmDocs -Times 0 -Exactly
        }
    }

    It 'aborts the chain and flips overall to error on a thrown non-Avm exception' {
        $dir = Join-Path $TestDrive ("precommit-err-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'terraform-module'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmSync            { [pscustomobject]@{ Engine = 'terraform'; Tool = 'managed-files'; Status = 'pass' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTransform       { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmFormat          { throw [System.InvalidOperationException]::new('engine blew up') }
            Mock Invoke-AvmDocs            { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Invoke-AvmPreCommit -Path $D
        }

        $result.Status                       | Should -Be 'error'
        $result.Steps.Count                  | Should -Be 4
        $result.Steps[-1].Step               | Should -Be 'format'
        $result.Steps[-1].Status             | Should -Be 'error'
        $result.Steps[-1].Error              | Should -Match 'engine blew up'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmDocs -Times 0 -Exactly
        }
    }
}
