function Install-AvmStubLauncher {
    <#
    .SYNOPSIS
        Materialise PowerShell stubs under tests/fixtures/bin/ as launcher
        binaries on disk so they resolve via Get-Command -CommandType Application.

    .DESCRIPTION
        For each '<tool>.ps1' file in -StubDir, writes a thin shim into -LauncherDir
        that invokes the matching stub. On Windows the shim is '<tool>.cmd'
        (picked up via the default PATHEXT). On Linux/macOS it is an executable
        PowerShell script named '<tool>' with a pwsh shebang.

        The returned LauncherDir is intended to be prepended to $env:PATH so the
        AvmTool PATH-fallback path resolves the stubs as if they were the real
        binaries (terraform, tflint, terraform-docs, etc.).

        Known Windows limitation: 'pwsh -File' splits any '-flag=value' argument at the
        first '=' or ':', so a stub receives '--config=C:\x' as two arguments
        ('--config=C' and '\x'). Quoting does not prevent this. Stubs must match
        on flag names only, and engines should prefer '--flag <value>' when the
        value is a path. Production code is unaffected - Invoke-AvmProcess uses
        ProcessStartInfo.ArgumentList and never routes through pwsh -File.

    .PARAMETER StubDir
        Directory containing one or more '<tool>.ps1' stub files.

    .PARAMETER LauncherDir
        Directory to materialise the launchers into. Created if missing. Any
        existing launcher files for matched stubs are overwritten.

    .PARAMETER PinsPath
        Path to avm.pins.jsonc. Each launcher injects the matching tool version
        into its stub process so fixture scripts never duplicate pin values.

    .OUTPUTS
        [string] The absolute path of LauncherDir.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $StubDir,

        [Parameter(Mandatory)]
        [string] $LauncherDir,

        [Parameter(Mandatory)]
        [string] $PinsPath
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not (Test-Path -LiteralPath $StubDir)) {
        throw [System.IO.DirectoryNotFoundException]::new("StubDir not found: $StubDir")
    }

    if (-not (Test-Path -LiteralPath $LauncherDir)) {
        $null = New-Item -ItemType Directory -Path $LauncherDir -Force
    }

    if (-not (Test-Path -LiteralPath $PinsPath -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new("PinsPath not found: $PinsPath")
    }

    $pins = Get-Content -LiteralPath $PinsPath -Raw | ConvertFrom-Json -AsHashtable
    $toolVersions = @{}
    foreach ($tool in @($pins.tools)) {
        $toolVersions[[string]$tool.name] = [string]$tool.version
    }

    $stubs = @(Get-ChildItem -LiteralPath $StubDir -Filter '*.ps1' -File)
    if ($stubs.Count -eq 0) {
        throw "No '*.ps1' stubs found in $StubDir"
    }

    foreach ($stub in $stubs) {
        $toolName = [System.IO.Path]::GetFileNameWithoutExtension($stub.Name)
        $stubPath = $stub.FullName
        if (-not $toolVersions.ContainsKey($toolName)) {
            throw [System.IO.InvalidDataException]::new(
                "Stub '$($stub.Name)' has no matching tool entry in $PinsPath")
        }
        $toolVersion = $toolVersions[$toolName]
        $pluginVersion = ''
        if ($toolName -eq 'tflint') {
            if (-not $pins.Contains('tflintPlugins') -or -not $pins.tflintPlugins.Contains('avm')) {
                throw [System.IO.InvalidDataException]::new(
                    "Stub '$($stub.Name)' requires tflintPlugins.avm in $PinsPath")
            }
            $pluginVersion = [string]$pins.tflintPlugins.avm
        }

        if ($IsWindows) {
            $launcherPath = Join-Path $LauncherDir "$toolName.cmd"
            $cmd = @(
                '@echo off',
                "set `"AVM_STUB_TOOL_VERSION=$toolVersion`"",
                "set `"AVM_STUB_TFLINT_AVM_PLUGIN_VERSION=$pluginVersion`"",
                "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$stubPath`" %*",
                'exit /b %ERRORLEVEL%'
            ) -join "`r`n"
            Set-Content -LiteralPath $launcherPath -Value $cmd -Encoding ASCII -NoNewline
        }
        else {
            $launcherPath = Join-Path $LauncherDir $toolName
            $escapedStubPath = $stubPath.Replace("'", "''")
            $pwsh = @(
                '#!/usr/bin/env pwsh',
                "`$env:AVM_STUB_TOOL_VERSION = '$toolVersion'",
                "`$env:AVM_STUB_TFLINT_AVM_PLUGIN_VERSION = '$pluginVersion'",
                "& '$escapedStubPath' @args",
                'exit $LASTEXITCODE'
            ) -join "`n"
            Set-Content -LiteralPath $launcherPath -Value $pwsh -Encoding utf8NoBOM -NoNewline
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
