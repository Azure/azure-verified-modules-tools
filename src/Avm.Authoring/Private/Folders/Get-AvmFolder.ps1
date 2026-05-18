function Get-AvmFolder {
    <#
    .SYNOPSIS
        Returns the on-disk path for one of Avm's standard user folders.

    .DESCRIPTION
        Resolves Avm's standard folders in an OS-aware way so that callers never
        hand-roll path construction. The folder is created (with chmod 0700 on
        Unix) unless -NoCreate is set.

        Precedence:

          1. If $env:AVM_HOME is set and non-empty, all folders live under
             $AVM_HOME/{config,cache,data,state,tools,logs}. This is the test
             override and the supported way to relocate the cache on shared
             hosts.

          2. Otherwise, OS conventions are used:
             - Windows: %APPDATA% (Config), %LOCALAPPDATA%\Avm\... (the rest).
             - macOS:   ~/Library/Application Support/Avm, ~/Library/Caches/Avm,
                        ~/Library/Logs/Avm.
             - Linux:   XDG base directories
                        ($XDG_CONFIG_HOME, $XDG_CACHE_HOME, $XDG_DATA_HOME,
                        $XDG_STATE_HOME), falling back to ~/.config, ~/.cache,
                        ~/.local/share, ~/.local/state.

        Temp is always [System.IO.Path]::GetTempPath().

    .PARAMETER Kind
        Which folder to resolve. Valid values:
        Config, Cache, Data, State, Tools, Logs, Temp.

    .PARAMETER NoCreate
        Return the resolved path without creating the directory if it does not
        already exist. The path is returned exactly as constructed (no normalisation).

    .EXAMPLE
        PS> Get-AvmFolder -Kind Cache

    .EXAMPLE
        PS> $env:AVM_HOME = '/tmp/avm-isolation'
        PS> Get-AvmFolder -Kind Tools
        /tmp/avm-isolation/tools
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Config', 'Cache', 'Data', 'State', 'Tools', 'Logs', 'Temp')]
        [string] $Kind,

        [switch] $NoCreate
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Kind -eq 'Temp') {
        return [System.IO.Path]::GetTempPath()
    }

    $avmHome = $env:AVM_HOME

    if (-not [string]::IsNullOrWhiteSpace($avmHome)) {
        $segment = switch ($Kind) {
            'Config' { 'config' }
            'Cache' { 'cache' }
            'Data' { 'data' }
            'State' { 'state' }
            'Tools' { 'tools' }
            'Logs' { 'logs' }
        }
        $path = Join-Path $avmHome $segment
    }
    elseif ($IsWindows) {
        $appData = [Environment]::GetFolderPath('ApplicationData')
        $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
        $path = switch ($Kind) {
            'Config' { Join-Path $appData 'Avm' }
            'Cache' { Join-Path (Join-Path $localAppData 'Avm') 'Cache' }
            'Data' { Join-Path $localAppData 'Avm' }
            'State' { Join-Path $localAppData 'Avm' }
            'Tools' { Join-Path (Join-Path $localAppData 'Avm') 'Tools' }
            'Logs' { Join-Path (Join-Path $localAppData 'Avm') 'Logs' }
        }
    }
    elseif ($IsMacOS) {
        $libraryRoot = Join-Path $HOME 'Library'
        $appSupport = Join-Path $libraryRoot 'Application Support'
        $caches = Join-Path $libraryRoot 'Caches'
        $logs = Join-Path $libraryRoot 'Logs'
        $path = switch ($Kind) {
            'Config' { Join-Path $appSupport 'Avm' }
            'Cache' { Join-Path $caches 'Avm' }
            'Data' { Join-Path $appSupport 'Avm' }
            'State' { Join-Path $appSupport 'Avm' }
            'Tools' { Join-Path (Join-Path $appSupport 'Avm') 'Tools' }
            'Logs' { Join-Path $logs 'Avm' }
        }
    }
    elseif ($IsLinux) {
        $configHome = if ([string]::IsNullOrWhiteSpace($env:XDG_CONFIG_HOME)) {
            Join-Path $HOME '.config'
        }
        else { $env:XDG_CONFIG_HOME }
        $cacheHome = if ([string]::IsNullOrWhiteSpace($env:XDG_CACHE_HOME)) {
            Join-Path $HOME '.cache'
        }
        else { $env:XDG_CACHE_HOME }
        $dataHome = if ([string]::IsNullOrWhiteSpace($env:XDG_DATA_HOME)) {
            Join-Path (Join-Path $HOME '.local') 'share'
        }
        else { $env:XDG_DATA_HOME }
        $stateHome = if ([string]::IsNullOrWhiteSpace($env:XDG_STATE_HOME)) {
            Join-Path (Join-Path $HOME '.local') 'state'
        }
        else { $env:XDG_STATE_HOME }

        $path = switch ($Kind) {
            'Config' { Join-Path $configHome 'avm' }
            'Cache' { Join-Path $cacheHome 'avm' }
            'Data' { Join-Path $dataHome 'avm' }
            'State' { Join-Path $stateHome 'avm' }
            'Tools' { Join-Path (Join-Path $dataHome 'avm') 'tools' }
            'Logs' { Join-Path (Join-Path $stateHome 'avm') 'logs' }
        }
    }
    else {
        throw [System.PlatformNotSupportedException]::new(
            'Unable to determine the current OS: $IsWindows, $IsLinux and $IsMacOS are all false.')
    }

    if (-not $NoCreate -and -not (Test-Path -LiteralPath $path)) {
        $null = New-Item -ItemType Directory -Path $path -Force
        if (-not $IsWindows) {
            # 0700 to match the spec's user-private cache contract. Ignore
            # chmod errors: if perms cannot be set, the next write will surface
            # a clearer permission error.
            & chmod 700 $path 2>$null
        }
    }

    if (Test-Path -LiteralPath $path) {
        (Get-Item -LiteralPath $path).FullName
    }
    else {
        $path
    }
}
