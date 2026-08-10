#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force

    # Use the running pwsh.exe as a cross-platform fixture binary. It's the
    # one external process every test host is guaranteed to have.
    $script:pwsh = (Get-Process -Id $PID).Path
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmProcess' {
    It 'captures stdout and reports exit code 0 for a successful run' {
        $exe = $script:pwsh
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ E = $exe } {
            param($E)
            Invoke-AvmProcess -FilePath $E -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', "Write-Output 'hello-avm'")
        }
        $result.ExitCode | Should -Be 0
        $result.StdOut.TrimEnd() | Should -Be 'hello-avm'
        $result.StdErr | Should -BeNullOrEmpty
        $result.TimedOut | Should -BeFalse
        $result.Duration.TotalMilliseconds | Should -BeGreaterThan 0
    }

    It 'captures stderr separately from stdout' {
        $exe = $script:pwsh
        $script = "[Console]::Out.WriteLine('to-stdout'); [Console]::Error.WriteLine('to-stderr')"
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ E = $exe; S = $script } {
            param($E, $S)
            Invoke-AvmProcess -FilePath $E -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $S)
        }
        $result.ExitCode | Should -Be 0
        $result.StdOut.TrimEnd() | Should -Be 'to-stdout'
        $result.StdErr.TrimEnd() | Should -Be 'to-stderr'
    }

    It 'stays quiet by default while retaining both captured values' {
        $exe = $script:pwsh
        $script = "[Console]::Out.WriteLine('live-out'); [Console]::Error.WriteLine('live-error')"
        $observed = InModuleScope 'Avm.Authoring' -Parameters @{ E = $exe; S = $script } {
            param($E, $S)
            $saved = @{
                Actions = $env:GITHUB_ACTIONS
                Runner  = $env:RUNNER_DEBUG
                Verbose = $env:AVM_VERBOSE
            }
            $env:GITHUB_ACTIONS = ''
            $env:RUNNER_DEBUG = ''
            $env:AVM_VERBOSE = ''
            try {
                $messages = @()
                $result = Invoke-AvmProcess `
                    -FilePath $E `
                    -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $S) `
                    -Label 'quiet fixture' `
                    -StreamOutput `
                    -InformationVariable messages
                [pscustomobject]@{
                    Result   = $result
                    Messages = @($messages | ForEach-Object { [string]$_.MessageData })
                }
            }
            finally {
                $env:GITHUB_ACTIONS = $saved.Actions
                $env:RUNNER_DEBUG = $saved.Runner
                $env:AVM_VERBOSE = $saved.Verbose
            }
        }
        $observed.Result.StdOut.TrimEnd() | Should -Be 'live-out'
        $observed.Result.StdErr.TrimEnd() | Should -Be 'live-error'
        $observed.Messages | Should -Not -Contain 'live-out'
        $observed.Messages | Should -Not -Contain 'live-error'
        ($observed.Messages -join "`n") | Should -Match 'quiet fixture'
    }

    It 'streams child output live when verbose is enabled' {
        $exe = $script:pwsh
        $script = "[Console]::Out.WriteLine('live-out'); [Console]::Error.WriteLine('live-error')"
        $observed = InModuleScope 'Avm.Authoring' -Parameters @{ E = $exe; S = $script } {
            param($E, $S)
            $saved = @{ Actions = $env:GITHUB_ACTIONS; Verbose = $env:AVM_VERBOSE }
            $env:GITHUB_ACTIONS = ''
            $env:AVM_VERBOSE = '1'
            try {
                $messages = @()
                $result = Invoke-AvmProcess `
                    -FilePath $E `
                    -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $S) `
                    -Label 'verbose fixture' `
                    -StreamOutput `
                    -InformationVariable messages
                [pscustomobject]@{
                    Result   = $result
                    Messages = @($messages | ForEach-Object { [string]$_.MessageData })
                }
            }
            finally {
                $env:GITHUB_ACTIONS = $saved.Actions
                $env:AVM_VERBOSE = $saved.Verbose
            }
        }
        $observed.Result.StdOut.TrimEnd() | Should -Be 'live-out'
        $observed.Messages | Should -Contain 'live-out'
        $observed.Messages | Should -Contain 'live-error'
    }

    It 'wraps output in a collapsible group under GitHub Actions' {
        $exe = $script:pwsh
        $script = "[Console]::Out.WriteLine('grouped-out')"
        $messages = InModuleScope 'Avm.Authoring' -Parameters @{ E = $exe; S = $script } {
            param($E, $S)
            $saved = @{ Actions = $env:GITHUB_ACTIONS; Verbose = $env:AVM_VERBOSE }
            $env:GITHUB_ACTIONS = 'true'
            $env:AVM_VERBOSE = ''
            try {
                $captured = @()
                Invoke-AvmProcess `
                    -FilePath $E `
                    -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $S) `
                    -Label 'grouped fixture' `
                    -StreamOutput `
                    -InformationVariable captured | Out-Null
                @($captured | ForEach-Object { [string]$_.MessageData })
            }
            finally {
                $env:GITHUB_ACTIONS = $saved.Actions
                $env:AVM_VERBOSE = $saved.Verbose
            }
        }
        @($messages) | Should -Contain '::group::grouped fixture'
        @($messages) | Should -Contain '::endgroup::'
        @($messages) | Should -Contain 'grouped-out'
    }

    It 'suppresses grouped output in an aggregate command unless runner debug is enabled' {
        $exe = $script:pwsh
        $script = "[Console]::Out.WriteLine('nested-out')"
        $observed = InModuleScope 'Avm.Authoring' -Parameters @{ E = $exe; S = $script } {
            param($E, $S)
            $saved = @{
                Actions = $env:GITHUB_ACTIONS
                Runner  = $env:RUNNER_DEBUG
                Verbose = $env:AVM_VERBOSE
            }
            $env:GITHUB_ACTIONS = 'true'
            $env:RUNNER_DEBUG = ''
            $env:AVM_VERBOSE = ''
            try {
                $quietMessages = @()
                $quietResult = Invoke-AvmNestedCommand {
                    Invoke-AvmProcess `
                        -FilePath $E `
                        -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $S) `
                        -Label 'nested fixture' `
                        -StreamOutput
                } -InformationVariable quietMessages

                $env:RUNNER_DEBUG = '1'
                $debugMessages = @()
                $debugResult = Invoke-AvmNestedCommand {
                    Invoke-AvmProcess `
                        -FilePath $E `
                        -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $S) `
                        -Label 'nested fixture' `
                        -StreamOutput
                } -InformationVariable debugMessages

                [pscustomobject]@{
                    QuietResult   = $quietResult
                    QuietMessages = @($quietMessages | ForEach-Object { [string]$_.MessageData })
                    DebugResult   = $debugResult
                    DebugMessages = @($debugMessages | ForEach-Object { [string]$_.MessageData })
                }
            }
            finally {
                $env:GITHUB_ACTIONS = $saved.Actions
                $env:RUNNER_DEBUG = $saved.Runner
                $env:AVM_VERBOSE = $saved.Verbose
            }
        }

        $observed.QuietResult.StdOut.TrimEnd() | Should -Be 'nested-out'
        @($observed.QuietMessages).Count | Should -Be 0
        $observed.DebugResult.StdOut.TrimEnd() | Should -Be 'nested-out'
        @($observed.DebugMessages) | Should -Contain '::group::nested fixture'
        @($observed.DebugMessages) | Should -Contain 'nested-out'
        @($observed.DebugMessages) | Should -Contain '::endgroup::'
    }

    It 'leaves caller-rendered progress ungrouped under GitHub Actions' {
        $exe = $script:pwsh
        $script = "[Console]::Out.WriteLine('raw-noise')"
        $messages = InModuleScope 'Avm.Authoring' -Parameters @{ E = $exe; S = $script } {
            param($E, $S)
            $saved = @{ Actions = $env:GITHUB_ACTIONS; Verbose = $env:AVM_VERBOSE }
            $env:GITHUB_ACTIONS = 'true'
            $env:AVM_VERBOSE = ''
            try {
                $captured = @()
                Invoke-AvmProcess `
                    -FilePath $E `
                    -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $S) `
                    -Label 'hooked fixture' `
                    -StreamOutput `
                    -OnStdOutLine { param($line) Write-AvmLog -Message "rendered:$line" -Level Info } `
                    -InformationVariable captured | Out-Null
                @($captured | ForEach-Object { [string]$_.MessageData })
            }
            finally {
                $env:GITHUB_ACTIONS = $saved.Actions
                $env:AVM_VERBOSE = $saved.Verbose
            }
        }
        @($messages) | Should -Not -Contain '::group::hooked fixture'
        @($messages) | Should -Not -Contain '::endgroup::'
        @($messages) | Should -Contain 'rendered:raw-noise'
        @($messages) | Should -Not -Contain 'raw-noise'
    }

    It 'replays the captured output when a quiet run fails' {
        $exe = $script:pwsh
        $script = "[Console]::Out.WriteLine('failing-detail'); exit 9"
        $messages = InModuleScope 'Avm.Authoring' -Parameters @{ E = $exe; S = $script } {
            param($E, $S)
            $saved = @{ Actions = $env:GITHUB_ACTIONS; Verbose = $env:AVM_VERBOSE }
            $env:GITHUB_ACTIONS = ''
            $env:AVM_VERBOSE = ''
            try {
                $captured = @()
                Invoke-AvmProcess `
                    -FilePath $E `
                    -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $S) `
                    -Label 'failing fixture' `
                    -StreamOutput `
                    -IgnoreExitCode `
                    -InformationVariable captured | Out-Null
                @($captured | ForEach-Object { [string]$_.MessageData })
            }
            finally {
                $env:GITHUB_ACTIONS = $saved.Actions
                $env:AVM_VERBOSE = $saved.Verbose
            }
        }
        ($messages -join "`n") | Should -Match 'FAILED: failing fixture'
        ($messages -join "`n") | Should -Match 'failing-detail'
    }

    It 'reports StartTime, EndTime and DurationMs on the result' {
        $exe = $script:pwsh
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ E = $exe } {
            param($E)
            Invoke-AvmProcess -FilePath $E -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', "Write-Output 'timed'")
        }
        $result.StartTime | Should -BeOfType ([datetime])
        $result.EndTime | Should -BeOfType ([datetime])
        $result.EndTime | Should -BeGreaterOrEqual $result.StartTime
        $result.DurationMs | Should -BeGreaterOrEqual 0
    }

    It 'throws AvmProcessException on a non-zero exit' {
        $exe = $script:pwsh
        $err = InModuleScope 'Avm.Authoring' -Parameters @{ E = $exe } {
            param($E)
            try {
                Invoke-AvmProcess -FilePath $E -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', 'exit 7')
                return $null
            }
            catch { return $_.Exception }
        }
        $err | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmProcessException'
        $err.Code | Should -Be 'AVM1020'
        $err.ExitCode | Should -Be 7
        $err.FileName | Should -Be $exe
    }

    It 'with -IgnoreExitCode returns the result instead of throwing' {
        $exe = $script:pwsh
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ E = $exe } {
            param($E)
            Invoke-AvmProcess -FilePath $E -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', 'exit 3') -IgnoreExitCode
        }
        $result.ExitCode | Should -Be 3
    }

    It 'throws AvmProcessException when the binary does not exist' {
        $bogus = Join-Path $TestDrive 'nosuchexe.exe'
        $err = InModuleScope 'Avm.Authoring' -Parameters @{ B = $bogus } {
            param($B)
            try {
                Invoke-AvmProcess -FilePath $B -ArgumentList @()
                return $null
            }
            catch { return $_.Exception }
        }
        $err | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmProcessException'
    }

    It 'kills the process and throws TimeoutException on -TimeoutSec' {
        $exe = $script:pwsh
        $err = InModuleScope 'Avm.Authoring' -Parameters @{ E = $exe } {
            param($E)
            try {
                Invoke-AvmProcess -FilePath $E -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 30') -TimeoutSec 1
                return $null
            }
            catch { return $_.Exception }
        }
        $err | Should -Not -BeNullOrEmpty
        $err.GetType().FullName | Should -Be 'System.TimeoutException'
    }

    It 'passes argv tokens verbatim (no shell, no quoting)' {
        $exe = $script:pwsh
        # Write a script file that echoes a parameter back unchanged.
        $scriptPath = Join-Path $TestDrive 'echo-arg.ps1'
        Set-Content -LiteralPath $scriptPath -Value 'param([string] $X) Write-Output $X' -Encoding utf8

        # Spaces and semicolons would be interpreted by a shell; argv handling
        # must keep them as a single literal token.
        $tricky = 'a b ; c'
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ E = $exe; S = $scriptPath; T = $tricky } {
            param($E, $S, $T)
            Invoke-AvmProcess -FilePath $E -ArgumentList @(
                '-NoProfile', '-NonInteractive', '-File', $S, '-X', $T
            )
        }
        $result.ExitCode | Should -Be 0
        $result.StdOut.TrimEnd() | Should -Be $tricky
    }

    It 'honours EnvVars overrides' {
        $exe = $script:pwsh
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ E = $exe } {
            param($E)
            Invoke-AvmProcess -FilePath $E -ArgumentList @(
                '-NoProfile', '-NonInteractive', '-Command', "Write-Output `$env:AVM_TEST_PROC"
            ) -EnvVars @{ AVM_TEST_PROC = 'present' }
        }
        $result.StdOut.TrimEnd() | Should -Be 'present'
    }

    It 'preserves the order of a rapid multi-line stdout burst' {
        $exe = $script:pwsh
        # Emit 200 numbered lines in a single fast burst. The previous
        # Register-ObjectEvent capture dispatched OutputDataReceived callbacks
        # through the runspace event queue and could append them out of order,
        # scrambling rapid bursts. ReadToEndAsync reads the stream on a single
        # task, preserving order; this guards that regression.
        $script = '1..200 | ForEach-Object { [Console]::Out.WriteLine($_) }'
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ E = $exe; S = $script } {
            param($E, $S)
            Invoke-AvmProcess -FilePath $E -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $S)
        }
        $result.ExitCode | Should -Be 0
        $lines = @($result.StdOut -split "`r?`n" | Where-Object { $_ -ne '' })
        $lines.Count | Should -Be 200
        $expected = 1..200 | ForEach-Object { [string]$_ }
        ($lines -join ',') | Should -Be ($expected -join ',')
    }

    It 'captures a multi-line JSON payload in order so it round-trips through ConvertFrom-Json' {
        $exe = $script:pwsh
        # Mirror the shape of `terraform validate -json`: a small multi-line
        # JSON document emitted as a fast burst of lines. The old capture
        # scrambled the lines, producing invalid JSON that failed to parse with
        # "Additional text encountered after finished reading JSON content".
        $script = @'
[Console]::Out.WriteLine('{')
[Console]::Out.WriteLine('  "format_version": "1.0",')
[Console]::Out.WriteLine('  "valid": true,')
[Console]::Out.WriteLine('  "error_count": 0,')
[Console]::Out.WriteLine('  "warning_count": 0,')
[Console]::Out.WriteLine('  "diagnostics": []')
[Console]::Out.WriteLine('}')
'@
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ E = $exe; S = $script } {
            param($E, $S)
            Invoke-AvmProcess -FilePath $E -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $S)
        }
        $result.ExitCode | Should -Be 0
        $parsed = $result.StdOut.Trim() | ConvertFrom-Json
        $parsed.format_version | Should -Be '1.0'
        $parsed.valid | Should -BeTrue
        @($parsed.diagnostics).Count | Should -Be 0
    }

    It 'F33: invokes -OnStdOutLine per stdout line and suppresses the raw echo' {
        $exe = $script:pwsh
        $script = "Write-Output 'alpha'; Write-Output 'beta'"
        $saved = $env:GITHUB_ACTIONS
        try {
            $env:GITHUB_ACTIONS = $null
            $captured = InModuleScope 'Avm.Authoring' -Parameters @{ E = $exe; S = $script } {
                param($E, $S)
                $seen = [System.Collections.Generic.List[string]]::new()
                $hook = { param($line) $seen.Add($line) }
                $null = Invoke-AvmProcess -FilePath $E `
                    -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $S) `
                    -StreamOutput -OnStdOutLine $hook -Verbose 6>$null 4>$null
                , $seen.ToArray()
            }

            $captured | Should -Contain 'alpha'
            $captured | Should -Contain 'beta'
        }
        finally {
            $env:GITHUB_ACTIONS = $saved
        }
    }

    It 'F33: still captures stdout on the result when -OnStdOutLine is supplied' {
        $exe = $script:pwsh
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ E = $exe } {
            param($E)
            $hook = { param($line) }
            Invoke-AvmProcess -FilePath $E `
                -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', "Write-Output 'kept'") `
                -StreamOutput -OnStdOutLine $hook
        }
        $result.ExitCode | Should -Be 0
        $result.StdOut.TrimEnd() | Should -Be 'kept'
    }

    It 'F57: renders the failing tool stderr in the exception message' {
        # -EncodedCommand keeps the expected text out of argv. With -Command the
        # script is echoed into the message verbatim, so the assertion would
        # match the echoed command line whether or not the diagnostic was
        # appended, and would pass against the unfixed code.
        $exe = $script:pwsh
        $script = "[Console]::Error.WriteLine('Argument or block definition required'); " +
        "[Console]::Error.WriteLine('  on broken.tf line 2'); exit 2"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
        $err = InModuleScope 'Avm.Authoring' -Parameters @{ E = $exe; S = $encoded } {
            param($E, $S)
            try {
                Invoke-AvmProcess -FilePath $E -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $S)
                return $null
            }
            catch { return $_.Exception }
        }
        $err | Should -Not -BeNullOrEmpty
        $err.Message | Should -Match 'Argument or block definition required'
        $err.Message | Should -Match 'broken\.tf line 2'
        # The prefix is load-bearing: callers and tests match on it.
        $err.Message | Should -Match 'Process exited with code 2'
    }

    It 'F57: falls back to stdout when the tool reports the cause there' {
        $exe = $script:pwsh
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("Write-Output 'stdout-only diagnostic'; exit 4"))
        $err = InModuleScope 'Avm.Authoring' -Parameters @{ E = $exe; S = $encoded } {
            param($E, $S)
            try {
                Invoke-AvmProcess -FilePath $E -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $S)
                return $null
            }
            catch { return $_.Exception }
        }
        $err.Message | Should -Match 'stdout-only diagnostic'
    }

    It 'F57: leaves the message unchanged when the tool said nothing' {
        $exe = $script:pwsh
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('exit 7'))
        $err = InModuleScope 'Avm.Authoring' -Parameters @{ E = $exe; S = $encoded } {
            param($E, $S)
            try {
                Invoke-AvmProcess -FilePath $E -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $S)
                return $null
            }
            catch { return $_.Exception }
        }
        $err.Message | Should -Match 'Process exited with code 7'
        $err.Message | Should -Not -Match '\r?\n'
    }
}

Describe 'Get-AvmProcessFailureDetail' {
    It 'F57: prefers stderr over stdout' {
        $text = InModuleScope 'Avm.Authoring' {
            Get-AvmProcessFailureDetail -StdOut 'from-stdout' -StdErr 'from-stderr'
        }
        $text | Should -Match 'from-stderr'
        $text | Should -Not -Match 'from-stdout'
    }

    It 'F57: falls back to stdout when stderr is blank' {
        $text = InModuleScope 'Avm.Authoring' {
            Get-AvmProcessFailureDetail -StdOut 'from-stdout' -StdErr "  `n  "
        }
        $text | Should -Match 'from-stdout'
    }

    It 'F57: returns an empty string when both streams are empty' {
        $text = InModuleScope 'Avm.Authoring' {
            Get-AvmProcessFailureDetail -StdOut '' -StdErr ''
        }
        $text | Should -BeExactly ''
    }

    It 'F57: drops blank lines and indents what it keeps' {
        $text = InModuleScope 'Avm.Authoring' {
            Get-AvmProcessFailureDetail -StdErr "first`n`n`nsecond"
        }
        $lines = @($text -split "`r?`n")
        $lines.Count | Should -Be 2
        $lines[0] | Should -BeExactly '  first'
        $lines[1] | Should -BeExactly '  second'
    }

    It 'F57: bounds a runaway diagnostic and says that it did' {
        $text = InModuleScope 'Avm.Authoring' {
            $flood = (1..500 | ForEach-Object { "line $_" }) -join "`n"
            Get-AvmProcessFailureDetail -StdErr $flood -MaxLines 20
        }
        $lines = @($text -split "`r?`n")
        # 20 kept plus the truncation marker.
        $lines.Count | Should -Be 21
        $text | Should -Match 'output truncated'
        $text | Should -Match 'line 20'
        $text | Should -Not -Match 'line 21\b'
    }
}
