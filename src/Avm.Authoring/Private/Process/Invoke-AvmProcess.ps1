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

    .OUTPUTS
        pscustomobject with FileName, ArgumentList, ExitCode, StdOut, StdErr,
        Duration, TimedOut.

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
        [switch] $IgnoreExitCode
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not $WorkingDirectory) {
        $WorkingDirectory = (Get-Location).ProviderPath
    }

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
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
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

        # Capture stdout / stderr by reading each stream to end on its own
        # asynchronous task. A single reader per stream preserves the exact
        # order of the child's output. The previous Register-ObjectEvent
        # approach dispatched OutputDataReceived callbacks through the runspace
        # event queue, which reordered rapid multi-line bursts (e.g. terraform's
        # `validate -json` payload) and corrupted the captured text because the
        # shared StringBuilder was appended from multiple job threads. Using one
        # task per stream also avoids the full-buffer deadlock that a single
        # synchronous ReadToEnd would risk when a child writes heavily to both
        # streams at once.
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        if ($TimeoutSec -gt 0) {
            $exited = $process.WaitForExit([int]($TimeoutSec * 1000))
            if (-not $exited) {
                $timedOut = $true
                try { $process.Kill($true) }
                catch { Write-Verbose "Failed to kill timed-out process: $($_.Exception.Message)" }
            }
        }
        # Block until the process has fully exited (also after a kill) so the
        # exit code is readable and the async stream tasks reach EOF.
        $process.WaitForExit()
    }
    finally {
        $stopwatch.Stop()
    }

    # Drain the async readers. After the process has exited (or been killed) the
    # child's pipe ends are closed, so these tasks complete with whatever was
    # buffered. Guard against a faulted task (e.g. a stream disposed abruptly on
    # kill) by falling back to an empty string.
    $stdOut = ''
    $stdErr = ''
    if ($started) {
        try { $stdOut = $stdoutTask.GetAwaiter().GetResult() } catch { $stdOut = '' }
        try { $stdErr = $stderrTask.GetAwaiter().GetResult() } catch { $stdErr = '' }
    }

    $exitCode = if ($started) { $process.ExitCode } else { -1 }
    $process.Dispose()

    if ($timedOut) {
        throw [System.TimeoutException]::new(
            "Process '$FilePath' did not exit within $TimeoutSec seconds; killed.")
    }

    $result = [pscustomobject][ordered]@{
        FileName     = $FilePath
        ArgumentList = $ArgumentList
        ExitCode     = $exitCode
        StdOut       = $stdOut
        StdErr       = $stdErr
        Duration     = $stopwatch.Elapsed
        TimedOut     = $timedOut
    }

    if (-not $IgnoreExitCode -and $exitCode -ne 0) {
        $argDisplay = if ($ArgumentList.Count -gt 0) { ' ' + ($ArgumentList -join ' ') } else { '' }
        $message = "Process exited with code $exitCode`: $FilePath$argDisplay"
        throw [AvmProcessException]::new($message, $FilePath, $ArgumentList, $exitCode, $stdOut, $stdErr)
    }

    return $result
}
