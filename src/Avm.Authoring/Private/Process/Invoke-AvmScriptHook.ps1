function Invoke-AvmScriptHook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $HookPath,

        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [hashtable] $EnvVars = @{},

        [string] $Label
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not (Test-Path -LiteralPath $HookPath -PathType Leaf)) {
        Write-AvmLog ("script-hook: not found; skipping {0}" -f $HookPath) -Level Verbose | Out-Null
        return
    }

    $extension = [System.IO.Path]::GetExtension($HookPath)
    if ($extension -eq '.sh') {
        throw [AvmConfigurationException]::new(
            "Shell hook '$HookPath' is not supported. Refactor the hook to a PowerShell '.ps1' file.")
    }
    if ($extension -ne '.ps1') {
        throw [AvmConfigurationException]::new("Unsupported script hook extension: '$HookPath'.")
    }

    Write-AvmLog ("script-hook: running {0} in {1}" -f $HookPath, $WorkingDirectory) -Level Verbose | Out-Null
    $null = Invoke-AvmProcess `
        -FilePath ([System.Environment]::ProcessPath) `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $HookPath) `
        -WorkingDirectory $WorkingDirectory `
        -EnvVars $EnvVars `
        -Label $Label
}
