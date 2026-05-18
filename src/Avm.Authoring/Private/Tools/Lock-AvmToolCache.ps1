function Lock-AvmToolCache {
    <#
    .SYNOPSIS
        Acquire a cross-process exclusive lock for a tool's cache directory.

    .DESCRIPTION
        Returns the open FileStream once the lock is held. The caller MUST
        Dispose the stream (typically in a finally block) to release the
        lock. If another process holds the lock this function retries up to
        TimeoutSec; on timeout it throws TimeoutException.

        The lock file lives at '<Data>/tools/<tool>/.lock'. The .lock file is
        left on disk after release; that is intentional and matches the spec.

    .PARAMETER LockFile
        Absolute path to the .lock file. Parent directory is created if it
        does not exist.

    .PARAMETER TimeoutSec
        Maximum time to wait for the lock. Default 60 seconds.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileStream])]
    param(
        [Parameter(Mandatory)] [string] $LockFile,
        [int] $TimeoutSec = 60
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $dir = Split-Path -Parent $LockFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        try {
            return [System.IO.File]::Open(
                $LockFile,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None)
        }
        catch [System.IO.IOException] {
            if ((Get-Date) -ge $deadline) {
                throw [System.TimeoutException]::new(
                    "Could not acquire lock '$LockFile' within $TimeoutSec seconds.")
            }
            Start-Sleep -Milliseconds 250
        }
    }
}
