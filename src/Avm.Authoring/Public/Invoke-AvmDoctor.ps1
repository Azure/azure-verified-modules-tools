function Invoke-AvmDoctor {
    <#
    .SYNOPSIS
        Diagnoses the local environment for running Avm.Authoring.

    .DESCRIPTION
        Runs a fixed set of probes (PowerShell version, OS detection, AVM cache
        folder writability) and emits a structured result. The verb is fail-fast
        but does not throw: a failing check is reported in the Checks collection
        and reflected in the overall Status. Use the exit-code via the dispatcher
        when scripting.

        With -Install, additionally walks every entry in avm.pins and installs
        any missing tool into the per-user cache (atomic stage->verify->rename
        through Install-AvmToolFromPins). Tools that do not ship a release for
        the current platform are reported as 'Skip', not 'Fail'.

    .PARAMETER Json
        Emit the result as a single JSON document on stdout instead of as a
        pscustomobject. Matches the global '--json' contract from the spec.

    .PARAMETER Install
        After running diagnostics, install every tool in avm.pins that is not
        already cache-verified. Cache hits are reported as OK; per-platform
        unsupported tools are reported as Skip; any other install failure
        becomes a Fail without aborting the remaining tools.

    .PARAMETER Force
        Combined with -Install, reinstall every tool even if a verified copy is
        already in the cache.

    .PARAMETER PinsPath
        Override the bundled Resources/avm.pins.jsonc. Intended for tests.

    .PARAMETER Path
        Module root whose tool-version-overrides.json applies. Bicep monorepos
        use their recognized repository root. Defaults to the current directory.

    .PARAMETER SkipModuleVersionCheck
        Skip the PowerShell Gallery check that otherwise stops the command when a
        newer Avm.Authoring version is available. Writes a warning once.

    .EXAMPLE
        PS> Invoke-AvmDoctor

    .EXAMPLE
        PS> avm doctor --json

    .EXAMPLE
        PS> avm doctor --install
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [switch] $Json,

        [switch] $Install,

        [switch] $Force,

        [string] $PinsPath,

        [string] $Path = $PWD.Path,

        # Test-only escape hatch (see Test-AvmPins). Hidden from help
        # and tab-completion so it does not appear in the production surface.
        [Parameter(DontShow)]
        [switch] $AllowFileUrls,

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck

    $checks = New-Object System.Collections.Generic.List[pscustomobject]
    $lock = if ($PinsPath) {
        Read-AvmPins -Path $PinsPath -ModuleRoot $Path -AllowFileUrls:$AllowFileUrls
    }
    else {
        Read-AvmPins -ModuleRoot $Path
    }
    $tools = @(Get-AvmToolDefinition -Pins $lock)
    foreach ($tool in $tools) {
        Write-AvmToolVersionOverride -Tool $tool
        if ($tool.ContainsKey('versionOverride')) {
            $checks.Add([pscustomobject]@{
                    Name = "Version override ($($tool.name))"; Status = 'Warning'
                    Detail   = "Packaged $($tool.versionOverride.PackagedVersion) -> selected $($tool.version); $($tool.versionOverride.Path)"
                    Required = 'Pinned checksum verification is disabled for this tool.'
                })
        }
    }

    # PowerShell version
    $psVer = $PSVersionTable.PSVersion
    $psVerOk = ($psVer.Major -gt 7) -or ($psVer.Major -eq 7 -and $psVer.Minor -ge 4)
    $checks.Add([pscustomobject][ordered]@{
            Name     = 'PowerShell version'
            Status   = if ($psVerOk) { 'OK' } else { 'Fail' }
            Detail   = $psVer.ToString()
            Required = '>= 7.4'
        })

    # PowerShell edition
    $editionOk = ([string]$PSVersionTable.PSEdition) -ceq 'Core'
    $checks.Add([pscustomobject][ordered]@{
            Name     = 'PowerShell edition'
            Status   = if ($editionOk) { 'OK' } else { 'Fail' }
            Detail   = [string]$PSVersionTable.PSEdition
            Required = 'Core'
        })

    # OS detection
    $osName = if ($IsWindows) { 'windows' } elseif ($IsLinux) { 'linux' } elseif ($IsMacOS) { 'macos' } else { 'unknown' }
    $checks.Add([pscustomobject][ordered]@{
            Name     = 'Operating system'
            Status   = if ($osName -ne 'unknown') { 'OK' } else { 'Fail' }
            Detail   = $osName
            Required = 'windows | linux | macos'
        })

    # AVM folder writability. Probes are diagnostic and self-cleaning; the
    # caller's -WhatIf must not suppress them or the cache directories never
    # get probed (and Get-AvmFolder's internal New-Item never creates them).
    $origWhatIf = $WhatIfPreference
    $origConfirm = $ConfirmPreference
    try {
        $WhatIfPreference = $false
        $ConfirmPreference = 'None'
        foreach ($kind in @('Config', 'Cache', 'Data', 'Tools', 'Logs')) {
            try {
                $path = Get-AvmFolder -Kind $kind
                $probeName = ".avm-doctor-write-test-$([guid]::NewGuid().Guid.Substring(0, 8))"
                $probePath = Join-Path $path $probeName
                Set-Content -LiteralPath $probePath -Value 'probe' -NoNewline
                Remove-Item -LiteralPath $probePath -Force
                $checks.Add([pscustomobject][ordered]@{
                        Name     = "AVM folder ($kind)"
                        Status   = 'OK'
                        Detail   = $path
                        Required = 'Writable'
                    })
            }
            catch {
                $checks.Add([pscustomobject][ordered]@{
                        Name     = "AVM folder ($kind)"
                        Status   = 'Fail'
                        Detail   = $_.Exception.Message
                        Required = 'Writable'
                    })
            }
        }
    }
    finally {
        $WhatIfPreference = $origWhatIf
        $ConfirmPreference = $origConfirm
    }

    if ($Install) {
        $platform = Get-AvmToolPlatform

        foreach ($t in (Get-AvmToolDefinition -Pins $lock -IncludeDependencies)) {
            $checkName = "Install tool ($($t.name) $($t.version))"
            $required = "Installed for $platform"

            if (-not $PSCmdlet.ShouldProcess($t.name, 'Install managed tool')) {
                $checks.Add([pscustomobject][ordered]@{
                        Name     = $checkName
                        Status   = 'Skip'
                        Detail   = 'Skipped (ShouldProcess declined)'
                        Required = $required
                    })
                continue
            }

            try {
                $installResult = Install-AvmToolFromPins -Tool $t -Platform $platform -Force:$Force
                $checks.Add([pscustomobject][ordered]@{
                        Name     = $checkName
                        Status   = 'OK'
                        Detail   = "$($installResult.Action): $($installResult.Path)"
                        Required = $required
                    })
            }
            catch [AvmToolException] {
                # AVM1012 = tool has no release for the current platform.
                # That is expected (e.g. tflint on windows-arm64) and must
                # not turn the overall doctor result red.
                $status = if ($_.Exception.Code -eq 'AVM1012') { 'Skip' } else { 'Fail' }
                $checks.Add([pscustomobject][ordered]@{
                        Name     = $checkName
                        Status   = $status
                        Detail   = $_.Exception.Message
                        Required = $required
                    })
            }
            catch {
                $checks.Add([pscustomobject][ordered]@{
                        Name     = $checkName
                        Status   = 'Fail'
                        Detail   = $_.Exception.Message
                        Required = $required
                    })
            }
        }
    }

    $failed = @($checks | Where-Object { $_.Status -notin @('OK', 'Skip', 'Warning') })
    $result = [pscustomobject][ordered]@{
        Status = if ($failed.Count -eq 0) { 'OK' } else { 'Fail' }
        Failed = $failed.Count
        Checks = $checks.ToArray()
    }

    if ($Json) {
        $result | ConvertTo-Json -Depth 5
    }
    else {
        $result
    }
}
