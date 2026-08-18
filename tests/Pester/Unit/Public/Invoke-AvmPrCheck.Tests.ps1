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
    BeforeEach {
        InModuleScope 'Avm.Authoring' {
            Mock Assert-AvmGitWorkingTreeClean {}
            Mock Resolve-AvmCommandTool { @() }
        }
    }

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

    It 'suppresses nested routine narration unless verbose or runner debug is enabled' {
        $dir = Join-Path $TestDrive ("prcheck-output-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
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
                Mock Invoke-AvmSync { throw [AvmNotSupportedException]::new('sync is terraform-only') }
                Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
                Mock Invoke-AvmTransform { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
                Mock Invoke-AvmLint {
                    Write-AvmLog 'nested lint info' -Level Info
                    Write-AvmLog 'nested lint pass' -Level Pass
                    Write-AvmLog 'nested lint warning' -Level Warning
                    [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' }
                }
                Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
                Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
                Mock Invoke-AvmTest { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
                Mock Invoke-AvmDocs { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }

                $defaultOutput = @(Invoke-AvmPrCheck -Path $D 3>&1 6>&1)

                $verboseOutput = @(Invoke-AvmPrCheck -Path $D -Verbose 4>$null 6>&1)

                $env:RUNNER_DEBUG = '1'
                $debugOutput = @(Invoke-AvmPrCheck -Path $D 4>$null 6>&1)

                [pscustomobject]@{
                    DefaultInfo = @(
                        $defaultOutput |
                            Where-Object { $_ -is [System.Management.Automation.InformationRecord] } |
                            ForEach-Object { [string]$_.MessageData }
                    )
                    DefaultWarnings = @(
                        $defaultOutput |
                            Where-Object { $_ -is [System.Management.Automation.WarningRecord] } |
                            ForEach-Object { [string]$_ }
                    )
                    VerboseInfo = @(
                        $verboseOutput |
                            Where-Object { $_ -is [System.Management.Automation.InformationRecord] } |
                            ForEach-Object { [string]$_.MessageData }
                    )
                    DebugInfo = @(
                        $debugOutput |
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

        ($observed.DefaultInfo -join "`n") | Should -Match 'step 4/8: lint'
        @($observed.DefaultWarnings) | Should -Contain 'nested lint warning'
        @($observed.DefaultInfo) | Should -Not -Contain 'nested lint info'
        @($observed.DefaultInfo) | Should -Not -Contain 'nested lint pass'
        @($observed.VerboseInfo) | Should -Contain 'nested lint info'
        @($observed.VerboseInfo) | Should -Contain 'nested lint pass'
        @($observed.DebugInfo) | Should -Contain 'nested lint info'
        @($observed.DebugInfo) | Should -Contain 'nested lint pass'
    }

    It 'rejects a dirty working tree before invoking any gauntlet step' {
        $dir = Join-Path $TestDrive ("prcheck-dirty-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $probe = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'terraform-module'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Assert-AvmGitWorkingTreeClean {
                throw [AvmConfigurationException]::new('Pr-check requires a clean working tree.')
            }
            Mock Invoke-AvmSync { throw 'No gauntlet step may run.' }

            try {
                $null = Invoke-AvmPrCheck -Path $D
            }
            catch {
                [pscustomobject]@{
                    ErrorName = $_.Exception.GetType().Name
                    Message = $_.Exception.Message
                }
            }

            Should -Invoke Assert-AvmGitWorkingTreeClean -Exactly 1 -ParameterFilter { $Path -eq $D }
            Should -Invoke Invoke-AvmSync -Exactly 0
        }

        $probe.ErrorName | Should -Be 'AvmConfigurationException'
        $probe.Message | Should -Match 'clean working tree'
    }

    It 'composes all eight steps in order on a passing chain; the terraform-only sync step is skipped for bicep' {
        $dir = Join-Path $TestDrive ("prcheck-pass-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmSync { throw [AvmNotSupportedException]::new('sync is terraform-only') }
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
        $result.Steps.Count               | Should -Be 8
        $result.Steps[0].Step             | Should -Be 'sync'
        $result.Steps[0].Status           | Should -Be 'skipped'
        $result.Steps[1].Step             | Should -Be 'format'
        $result.Steps[2].Step             | Should -Be 'transform'
        $result.Steps[3].Step             | Should -Be 'lint'
        $result.Steps[4].Step             | Should -Be 'check policy'
        $result.Steps[5].Step             | Should -Be 'check convention'
        $result.Steps[6].Step             | Should -Be 'validate'
        $result.Steps[7].Step             | Should -Be 'docs'
        ($result.Steps | Where-Object Step -ne 'sync' | ForEach-Object Status | Select-Object -Unique) | Should -Be 'pass'
    }

    It 'runs every managed-content step in drift mode so a CI auto-fix cannot report a pass' {
        $dir = Join-Path $TestDrive ("prcheck-drift-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmSync { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTransform { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmLint { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTest { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmDocs { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }

            Invoke-AvmPrCheck -Path $D | Out-Null

            # All four steps that rewrite tracked files must gate, or the fix is
            # made in the throwaway runner copy and thrown away with it.
            Should -Invoke Invoke-AvmSync -Exactly 1 -ParameterFilter { $CheckDrift -eq $true }
            Should -Invoke Invoke-AvmFormat -Exactly 1 -ParameterFilter { $CheckDrift -eq $true }
            Should -Invoke Invoke-AvmTransform -Exactly 1 -ParameterFilter { $CheckDrift -eq $true }
            Should -Invoke Invoke-AvmDocs -Exactly 1 -ParameterFilter { $CheckDrift -eq $true }
            Should -Invoke Invoke-AvmCheckConvention -Exactly 1 -ParameterFilter {
                -not $Fix -and -not $FixableOnly
            }
        }
    }

    It 'reports a stubbed engine (AvmNotSupportedException) as skipped and continues the chain' {
        $dir = Join-Path $TestDrive ("prcheck-skip-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmSync { throw [AvmNotSupportedException]::new('sync is terraform-only') }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmTransform { throw [AvmNotSupportedException]::new('transform not wired yet') }
            Mock Invoke-AvmLint { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmCheckPolicy { throw [AvmNotSupportedException]::new('check policy not wired yet') }
            Mock Invoke-AvmCheckConvention { throw [AvmNotSupportedException]::new('check convention not wired yet') }
            Mock Invoke-AvmTest { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmDocs { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Invoke-AvmPrCheck -Path $D
        }

        $result.Status                                  | Should -Be 'pass'
        $result.Steps.Count                             | Should -Be 8
        ($result.Steps | Where-Object Status -eq 'skipped').Count | Should -Be 4
        ($result.Steps | Where-Object Step -eq 'sync').Status              | Should -Be 'skipped'
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
            Mock Invoke-AvmSync { throw [AvmNotSupportedException]::new('sync is terraform-only') }
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
        $result.Steps.Count                           | Should -Be 8
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
            Mock Invoke-AvmSync { throw [AvmNotSupportedException]::new('sync is terraform-only') }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmTransform { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmLint { [pscustomobject]@{ Engine = 'bicep'; Status = 'fail' } }
            Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmTest { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmDocs { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Invoke-AvmPrCheck -Path $D -StopOnFail
        }

        # sync(skipped) -> format(pass) -> transform(pass) -> lint(fail) -> abort
        $result.Status                       | Should -Be 'fail'
        $result.Steps.Count                  | Should -Be 4
        $result.Steps[-1].Step               | Should -Be 'lint'
        $result.Steps[-1].Status             | Should -Be 'fail'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmCheckPolicy -Times 0 -Exactly
            Should -Invoke Invoke-AvmCheckConvention -Times 0 -Exactly
            Should -Invoke Invoke-AvmTest -Times 0 -Exactly
            Should -Invoke Invoke-AvmDocs -Times 0 -Exactly
        }
    }

    It 'aborts the chain and flips overall to error on a thrown non-Avm exception' {
        $dir = Join-Path $TestDrive ("prcheck-err-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'bicep-module'; Root = $D; Ecosystem = 'bicep'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmSync { throw [AvmNotSupportedException]::new('sync is terraform-only') }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmTransform { throw [System.InvalidOperationException]::new('engine blew up') }
            Mock Invoke-AvmLint { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmTest { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Mock Invoke-AvmDocs { [pscustomobject]@{ Engine = 'bicep'; Status = 'pass' } }
            Invoke-AvmPrCheck -Path $D
        }

        # sync(skipped) -> format(pass) -> transform(error) -> abort
        $result.Status                       | Should -Be 'error'
        $result.Steps.Count                  | Should -Be 3
        $result.Steps[-1].Step               | Should -Be 'transform'
        $result.Steps[-1].Status             | Should -Be 'error'
        $result.Steps[-1].Error              | Should -Match 'engine blew up'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmLint -Times 0 -Exactly
            Should -Invoke Invoke-AvmDocs -Times 0 -Exactly
        }
    }

    It 'composes all eight steps in order on a passing chain (terraform), running the drift-check sync first and forwarding the ecosystem to every step' {
        $dir = Join-Path $TestDrive ("prcheck-tf-pass-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'terraform-module'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmSync { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTransform { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmLint { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTest { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTestUnit { throw 'pr-check must not run the standalone unit tier' }
            Mock Invoke-AvmDocs { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            $r = Invoke-AvmPrCheck -Path $D -ThrottleLimit 5

            # sync runs first in drift-check mode: -CheckDrift is forwarded via
            # the step's ExtraArgs so CI treats stale governed files as a fail.
            Should -Invoke Invoke-AvmSync            -Exactly 1 -ParameterFilter { $Ecosystem -eq 'terraform' -and $CheckDrift }
            Should -Invoke Invoke-AvmFormat          -Exactly 1 -ParameterFilter { $Ecosystem -eq 'terraform' }
            Should -Invoke Invoke-AvmTransform       -Exactly 1 -ParameterFilter { $Ecosystem -eq 'terraform' }
            Should -Invoke Invoke-AvmLint            -Exactly 1 -ParameterFilter { $Ecosystem -eq 'terraform' -and $ThrottleLimit -eq 5 }
            Should -Invoke Invoke-AvmCheckPolicy     -Exactly 1 -ParameterFilter { $Ecosystem -eq 'terraform' -and $ThrottleLimit -eq 5 }
            Should -Invoke Invoke-AvmCheckConvention -Exactly 1 -ParameterFilter { $Ecosystem -eq 'terraform' }
            Should -Invoke Invoke-AvmTest            -Exactly 1 -ParameterFilter { $Ecosystem -eq 'terraform' }
            Should -Invoke Invoke-AvmTestUnit        -Times 0 -Exactly
            Should -Invoke Invoke-AvmDocs            -Exactly 1 -ParameterFilter { $Ecosystem -eq 'terraform' }

            $r
        }

        $result.Status                    | Should -Be 'pass'
        $result.Ecosystem                 | Should -Be 'terraform'
        $result.Steps.Count               | Should -Be 8
        $result.Steps[0].Step             | Should -Be 'sync'
        $result.Steps[1].Step             | Should -Be 'format'
        $result.Steps[2].Step             | Should -Be 'transform'
        $result.Steps[3].Step             | Should -Be 'lint'
        $result.Steps[4].Step             | Should -Be 'check policy'
        $result.Steps[5].Step             | Should -Be 'check convention'
        $result.Steps[6].Step             | Should -Be 'validate'
        $result.Steps[7].Step             | Should -Be 'docs'
        ($result.Steps | ForEach-Object Status | Select-Object -Unique) | Should -Be 'pass'
    }

    It 'renders deprecated interface notices while lint and pr-check remain pass' {
        $dir = Join-Path $TestDrive ("prcheck-tf-notice-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $observed = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'terraform-module'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmSync { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTransform { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmLint {
                [pscustomobject]@{
                    Engine = 'terraform'
                    Status = 'pass'
                    Issues = @([pscustomobject]@{
                            Severity = 'notice'
                            File     = 'variables.tf'
                            Line     = 7
                            Column   = 1
                            Code     = 'deprecated_lock_interface'
                            Message  = 'lock uses deprecated interface variant 1'
                        })
                }
            }
            Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTest { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmDocs { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }

            $result = Invoke-AvmPrCheck -Path $D
            [pscustomobject]@{
                Result = $result
                Lines  = @(ConvertTo-AvmResultLine -Result @($result) -Verb 'pr-check')
            }
        }

        $observed.Result.Status | Should -Be 'pass'
        $lintStep = $observed.Result.Steps | Where-Object Step -eq 'lint'
        $lintStep.Status | Should -Be 'pass'
        $lintStep.Result.Status | Should -Be 'pass'
        $lintStep.Result.Issues.Count | Should -Be 1
        $lintStep.Result.Issues[0].Code | Should -Be 'deprecated_lock_interface'
        ($observed.Lines -join "`n") | Should -Match 'notice variables\.tf:7:1 \[deprecated_lock_interface\]'
        ($observed.Lines -join "`n") | Should -Match 'lock uses deprecated interface variant 1'
    }

    It 'reports the stub terraform engines (transform/check policy/check convention) as skipped and keeps overall pass; the terraform sync step runs' {
        $dir = Join-Path $TestDrive ("prcheck-tf-skip-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'terraform-module'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmSync { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTransform { throw [AvmNotSupportedException]::new('transform not wired yet') }
            Mock Invoke-AvmLint { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmCheckPolicy { throw [AvmNotSupportedException]::new('check policy not wired yet') }
            Mock Invoke-AvmCheckConvention { throw [AvmNotSupportedException]::new('check convention not wired yet') }
            Mock Invoke-AvmTest { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmDocs { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Invoke-AvmPrCheck -Path $D
        }

        $result.Status                                                     | Should -Be 'pass'
        $result.Ecosystem                                                  | Should -Be 'terraform'
        $result.Steps.Count                                                | Should -Be 8
        ($result.Steps | Where-Object Status -eq 'skipped').Count          | Should -Be 3
        ($result.Steps | Where-Object Step -eq 'sync').Status              | Should -Be 'pass'
        ($result.Steps | Where-Object Step -eq 'transform').Status         | Should -Be 'skipped'
        ($result.Steps | Where-Object Step -eq 'check policy').Status      | Should -Be 'skipped'
        ($result.Steps | Where-Object Step -eq 'check convention').Status  | Should -Be 'skipped'
        ($result.Steps | Where-Object Step -eq 'docs').Status              | Should -Be 'pass'
    }
    It 'does not run the unit tier as part of pre-commit, which stays offline and init-free' {
        $dir = Join-Path $TestDrive ("precommit-nounit-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmSync { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTransform { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmDocs { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTestUnit { throw 'pre-commit must not run the unit tier' }
            Invoke-AvmPreCommit -Path $D
        }

        $result.Status | Should -Be 'pass'
        $result.Steps.Step | Should -Not -Contain 'unit test'

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmTestUnit -Times 0 -Exactly
        }
    }

    # F39: 'skipped' means the verb does not apply to this ecosystem. It must not
    # also mean 'your repo is misconfigured', because a skip renders as a benign
    # gauntlet pass - which is exactly how a step that never ran looks green.
    It 'F39: fails the gauntlet on a configuration error but skips an unsupported verb' {
        $dir = Join-Path $TestDrive ("prcheck-f39-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Mock Get-AvmModuleContext {
                [pscustomobject]@{
                    Kind = 'terraform-module-repo'; Root = $D; Ecosystem = 'terraform'; Source = 'path-heuristic'
                }
            }
            Mock Invoke-AvmSync { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmFormat { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTransform { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmLint { throw [AvmConfigurationException]::new('AVM_MIRROR is not a valid absolute URL') }
            Mock Invoke-AvmCheckPolicy { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmCheckConvention { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmTest { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Mock Invoke-AvmDocs { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass' } }
            Invoke-AvmPrCheck -Path $D
        }

        ($result.Steps | Where-Object Step -eq 'lint').Status | Should -Be 'fail'
        $result.Status | Should -Be 'fail'

        # 'fail' must not abort the chain the way 'error' does - the remaining
        # steps still run so one bad config does not mask the next.
        $result.Steps.Step | Should -Contain 'docs'
    }
}