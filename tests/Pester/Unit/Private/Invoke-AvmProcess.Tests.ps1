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
}
