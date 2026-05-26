function Install-AvmStubLauncher {
    <#
    .SYNOPSIS
        Materialise PowerShell stubs under tests/fixtures/bin/ as launcher
        binaries on disk so they resolve via Get-Command -CommandType Application.

    .DESCRIPTION
        For each '<tool>.ps1' file in -StubDir, writes a thin shim into -LauncherDir
        that invokes 'pwsh -NoProfile -File <stub> <args>'. On Windows the shim is
        '<tool>.cmd' (picked up via the default PATHEXT). On Linux/macOS it is a
        bash script named '<tool>' (no extension) with the exec bit set.

        The returned LauncherDir is intended to be prepended to $env:PATH so the
        AvmTool PATH-fallback path resolves the stubs as if they were the real
        binaries (terraform, tflint, terraform-docs, etc.).

    .PARAMETER StubDir
        Directory containing one or more '<tool>.ps1' stub files.

    .PARAMETER LauncherDir
        Directory to materialise the launchers into. Created if missing. Any
        existing launcher files for matched stubs are overwritten.

    .OUTPUTS
        [string] The absolute path of LauncherDir.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $StubDir,

        [Parameter(Mandatory)]
        [string] $LauncherDir
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not (Test-Path -LiteralPath $StubDir)) {
        throw [System.IO.DirectoryNotFoundException]::new("StubDir not found: $StubDir")
    }

    if (-not (Test-Path -LiteralPath $LauncherDir)) {
        $null = New-Item -ItemType Directory -Path $LauncherDir -Force
    }

    $stubs = @(Get-ChildItem -LiteralPath $StubDir -Filter '*.ps1' -File)
    if ($stubs.Count -eq 0) {
        throw "No '*.ps1' stubs found in $StubDir"
    }

    foreach ($stub in $stubs) {
        $toolName = [System.IO.Path]::GetFileNameWithoutExtension($stub.Name)
        $stubPath = $stub.FullName

        if ($IsWindows) {
            $launcherPath = Join-Path $LauncherDir "$toolName.cmd"
            $cmd = @(
                '@echo off',
                "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$stubPath`" %*",
                'exit /b %ERRORLEVEL%'
            ) -join "`r`n"
            Set-Content -LiteralPath $launcherPath -Value $cmd -Encoding ASCII -NoNewline
        }
        else {
            $launcherPath = Join-Path $LauncherDir $toolName
            $bash = @(
                '#!/usr/bin/env bash',
                "exec pwsh -NoProfile -File `"$stubPath`" `"`$@`""
            ) -join "`n"
            Set-Content -LiteralPath $launcherPath -Value $bash -Encoding utf8NoBOM -NoNewline
            $mode = [System.IO.UnixFileMode]::UserRead `
                -bor [System.IO.UnixFileMode]::UserWrite `
                -bor [System.IO.UnixFileMode]::UserExecute `
                -bor [System.IO.UnixFileMode]::GroupRead `
                -bor [System.IO.UnixFileMode]::GroupExecute `
                -bor [System.IO.UnixFileMode]::OtherRead `
                -bor [System.IO.UnixFileMode]::OtherExecute
            [System.IO.File]::SetUnixFileMode($launcherPath, $mode)
        }
    }

    return (Resolve-Path -LiteralPath $LauncherDir).Path
}
