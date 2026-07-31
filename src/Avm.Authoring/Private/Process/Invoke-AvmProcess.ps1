function Invoke-AvmProcess {
    <#
    .SYNOPSIS
        Run an external binary, capture stdout/stderr separately, and surface
        a structured result. The only subprocess primitive used by the CLI.

    .DESCRIPTION
        Wraps System.Diagnostics.Process with argv-array arguments (no shell,
        no quoting), separate stdout/stderr capture via per-stream asynchronous
        reads (ReadToEndAsync), and an optional timeout. Throws
        AvmProcessException on non-zero exit unless -IgnoreExitCode is supplied.
        On timeout the process tree is killed and a TimeoutException is thrown.

        Per spec section 9 the CLI never invokes a shell and never quotes
        arguments; every argument is passed verbatim through
        ProcessStartInfo.ArgumentList.

    .PARAMETER FilePath
        Absolute path to the executable. Callers are expected to resolve via
        the tool resolver or Get-Command before invoking.

    .PARAMETER ArgumentList
        Verbatim argv tokens. Empty array runs the binary with no args.

    .PARAMETER WorkingDirectory
        Working directory for the child process. Defaults to the current
        location's provider path.

    .PARAMETER EnvVars
        Per-invocation environment overrides. Existing parent-process vars
        are inherited; entries in this hashtable take precedence. A $null
        value removes the variable for the child.

    .PARAMETER TimeoutSec
        Maximum runtime in seconds. 0 (default) means no timeout.

    .PARAMETER IgnoreExitCode
        Suppress the AvmProcessException throw on non-zero exit. The exit
        code is still returned on the result object.

    .PARAMETER StreamOutput
        Narrate the invocation. Child output is always captured; it is emitted
        live only when verbose/debug logging is on or when running under GitHub
        Actions (where it is wrapped in a collapsed group). Otherwise the run is
        quiet with a periodic heartbeat, and the full captured output is
        replayed if the process fails.

    .PARAMETER Label
        Friendly name for the invocation used in narration. Defaults to the
        executable leaf plus its arguments.

    .PARAMETER OnStdOutLine
        Scriptblock invoked with each stdout line as it arrives. When supplied
        the caller owns stdout rendering, so raw stdout lines are not echoed
        even when live streaming is on, and the invocation is not wrapped in a
        collapsed GitHub Actions group: the caller's lines are already the
        curated progress view and must stay visible. Requires -StreamOutput.

    .PARAMETER SuccessExitCode
        Exit codes treated as success for narration and failure replay. Does
        not affect the AvmProcessException throw, which is governed by
        -IgnoreExitCode.

    .OUTPUTS
        pscustomobject with FileName, ArgumentList, ExitCode, StdOut, StdErr,
        Duration, DurationMs, StartTime, EndTime, TimedOut.

    .EXAMPLE
        PS> Invoke-AvmProcess -FilePath 'terraform' -ArgumentList @('version')
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [string[]] $ArgumentList = @(),
        [string] $WorkingDirectory,
        [hashtable] $EnvVars,
        [int] $TimeoutSec = 0,
        [switch] $IgnoreExitCode,
        [switch] $StreamOutput,
        [string] $Label,
        [scriptblock] $OnStdOutLine,
        [int[]] $SuccessExitCode = @(0)
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not $WorkingDirectory) {
        $WorkingDirectory = (Get-Location).ProviderPath
    }

    $displayLabel = if (-not [string]::IsNullOrWhiteSpace($Label)) {
        $Label
    }
    else {
        $leaf = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
        $joined = if ($ArgumentList.Count -gt 0) { '{0} {1}' -f $leaf, ($ArgumentList -join ' ') } else { $leaf }
        if ($joined.Length -gt 140) { $joined.Substring(0, 137) + '...' } else { $joined }
    }

    $inActions = Test-AvmGitHubActionsContext
    $narrate = [bool]$StreamOutput
    $hasLineHook = $null -ne $OnStdOutLine
    $live = $narrate -and ($inActions -or (Test-AvmVerboseEnabled))
    $grouped = $narrate -and $inActions -and -not $hasLineHook
    $heartbeatSeconds = 30
    $nextHeartbeat = $heartbeatSeconds

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $WorkingDirectory

    # Decode child stdout / stderr as UTF-8 without BOM so output from tools
    # like terraform and bicep round-trips cleanly even when the host console
    # is set to a legacy code page (typical on Windows).
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardOutputEncoding = $utf8NoBom
    $psi.StandardErrorEncoding = $utf8NoBom

    foreach ($a in $ArgumentList) {
        $psi.ArgumentList.Add([string]$a)
    }

    if ($EnvVars) {
        foreach ($key in $EnvVars.Keys) {
            $value = $EnvVars[$key]
            if ($null -eq $value) {
                $null = $psi.Environment.Remove([string]$key)
            }
            else {
                $psi.Environment[[string]$key] = [string]$value
            }
        }
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    $process.EnableRaisingEvents = $false

    $started = $false
    $timedOut = $false
    $stdoutTask = $null
    $stderrTask = $null
    $stdoutBuilder = [System.Text.StringBuilder]::new()
    $stderrBuilder = [System.Text.StringBuilder]::new()
    $startTime = [datetime]::UtcNow
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    if ($grouped) {
        Enter-AvmLogGroup -Name $displayLabel
    }
    elseif ($narrate) {
        Write-AvmLog ('  run: {0}' -f $displayLabel) -Level Info
    }

    try {
        try {
            $null = $process.Start()
            $started = $true
        }
        catch [System.ComponentModel.Win32Exception] {
            throw [AvmProcessException]::new(
                "Failed to start '$FilePath': $($_.Exception.Message)",
                $FilePath, $ArgumentList, -1, '', $_.Exception.Message)
        }

        if ($StreamOutput) {
            $stdoutTask = $process.StandardOutput.ReadLineAsync()
            $stderrTask = $process.StandardError.ReadLineAsync()

            while ($null -ne $stdoutTask -or $null -ne $stderrTask) {
                $pending = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
                if ($null -ne $stdoutTask) { $pending.Add($stdoutTask) }
                if ($null -ne $stderrTask) { $pending.Add($stderrTask) }
                if ($pending.Count -gt 0) {
                    $null = [System.Threading.Tasks.Task]::WaitAny($pending.ToArray(), 100)
                }

                if ($null -ne $stdoutTask -and $stdoutTask.IsCompleted) {
                    $line = $stdoutTask.GetAwaiter().GetResult()
                    if ($null -eq $line) {
                        $stdoutTask = $null
                    }
                    else {
                        $null = $stdoutBuilder.AppendLine($line)
                        if ($hasLineHook) {
                            & $OnStdOutLine $line
                        }
                        elseif ($live) { Write-AvmLog $line -Level Info }
                        $stdoutTask = $process.StandardOutput.ReadLineAsync()
                    }
                }

                if ($null -ne $stderrTask -and $stderrTask.IsCompleted) {
                    $line = $stderrTask.GetAwaiter().GetResult()
                    if ($null -eq $line) {
                        $stderrTask = $null
                    }
                    else {
                        $null = $stderrBuilder.AppendLine($line)
                        if ($live) { Write-AvmLog $line -Level Info }
                        $stderrTask = $process.StandardError.ReadLineAsync()
                    }
                }

                if (-not $live -and $stopwatch.Elapsed.TotalSeconds -ge $nextHeartbeat) {
                    Write-AvmLog ('  ... still running: {0} ({1})' -f $displayLabel, (Format-AvmDuration -Duration $stopwatch.Elapsed)) -Level Info
                    $nextHeartbeat += $heartbeatSeconds
                }

                if (
                    $TimeoutSec -gt 0 -and
                    -not $timedOut -and
                    -not $process.HasExited -and
                    $stopwatch.Elapsed.TotalSeconds -ge $TimeoutSec
                ) {
                    $timedOut = $true
                    try { $process.Kill($true) }
                    catch { Write-AvmLog "Failed to kill timed-out process: $($_.Exception.Message)" -Level Verbose }
                }
            }
        }
        else {
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()

            if ($TimeoutSec -gt 0) {
                $exited = $process.WaitForExit([int]($TimeoutSec * 1000))
                if (-not $exited) {
                    $timedOut = $true
                    try { $process.Kill($true) }
                    catch { Write-AvmLog "Failed to kill timed-out process: $($_.Exception.Message)" -Level Verbose }
                }
            }
        }
        $process.WaitForExit()
    }
    finally {
        $stopwatch.Stop()
        if ($grouped) {
            Exit-AvmLogGroup
        }
    }
    $endTime = $startTime.AddMilliseconds($stopwatch.Elapsed.TotalMilliseconds)

    # Drain the async readers. After the process has exited (or been killed) the
    # child's pipe ends are closed, so these tasks complete with whatever was
    # buffered. Guard against a faulted task (e.g. a stream disposed abruptly on
    # kill) by falling back to an empty string.
    $stdOut = ''
    $stdErr = ''
    if ($started) {
        if ($StreamOutput) {
            $stdOut = $stdoutBuilder.ToString()
            $stdErr = $stderrBuilder.ToString()
        }
        else {
            try { $stdOut = $stdoutTask.GetAwaiter().GetResult() } catch { $stdOut = '' }
            try { $stdErr = $stderrTask.GetAwaiter().GetResult() } catch { $stdErr = '' }
        }
    }

    $exitCode = if ($started) { $process.ExitCode } else { -1 }
    $process.Dispose()

    if ($timedOut) {
        if ($narrate) {
            Write-AvmLog ('  TIMEOUT: {0} (after {1})' -f $displayLabel, (Format-AvmDuration -Duration $stopwatch.Elapsed)) -Level Error
        }
        throw [System.TimeoutException]::new(
            "Process '$FilePath' did not exit within $TimeoutSec seconds; killed.")
    }

    $succeeded = $SuccessExitCode -contains $exitCode

    if ($narrate) {
        $suffix = '(exit {0}, {1})' -f $exitCode, (Format-AvmDuration -Duration $stopwatch.Elapsed)
        if ($succeeded) {
            Write-AvmLog ('  done: {0} {1}' -f $displayLabel, $suffix) -Level Info
        }
        else {
            Write-AvmLog ('  FAILED: {0} {1}' -f $displayLabel, $suffix) -Level Error
            if ($hasLineHook) {
                foreach ($replayLine in (Get-AvmProcessReplayLine -Label $displayLabel -StdErr $stdErr)) {
                    Write-AvmLog $replayLine -Level Info
                }
            }
            elseif (-not $live) {
                foreach ($replayLine in (Get-AvmProcessReplayLine -Label $displayLabel -StdOut $stdOut -StdErr $stdErr)) {
                    Write-AvmLog $replayLine -Level Info
                }
            }
        }
    }

    $result = [pscustomobject][ordered]@{
        FileName     = $FilePath
        ArgumentList = $ArgumentList
        ExitCode     = $exitCode
        StdOut       = $stdOut
        StdErr       = $stdErr
        Duration     = $stopwatch.Elapsed
        DurationMs   = [int]$stopwatch.Elapsed.TotalMilliseconds
        StartTime    = $startTime
        EndTime      = $endTime
        TimedOut     = $timedOut
    }

    if (-not $IgnoreExitCode -and $exitCode -ne 0) {
        $argDisplay = if ($ArgumentList.Count -gt 0) { ' ' + ($ArgumentList -join ' ') } else { '' }
        $message = "Process exited with code $exitCode`: $FilePath$argDisplay"
        throw [AvmProcessException]::new($message, $FilePath, $ArgumentList, $exitCode, $stdOut, $stdErr)
    }

    return $result
}

function Get-AvmProcessReplayLine {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Label,

        [AllowEmptyString()]
        [string] $StdOut = '',

        [AllowEmptyString()]
        [string] $StdErr = ''
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $body = [System.Collections.Generic.List[string]]::new()
    foreach ($chunk in @($StdOut, $StdErr)) {
        if ([string]::IsNullOrWhiteSpace($chunk)) { continue }
        foreach ($line in $chunk -split "`r?`n") {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $body.Add('    ' + $line)
        }
    }

    if ($body.Count -eq 0) {
        return @()
    }

    $lines.Add(('  ---- captured output: {0} ----' -f $Label))
    $lines.AddRange($body)
    $lines.Add('  ---- end captured output ----')
    return $lines.ToArray()
}
