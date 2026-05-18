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

    .PARAMETER Json
        Emit the result as a single JSON document on stdout instead of as a
        pscustomobject. Matches the global '--json' contract from the spec.

    .EXAMPLE
        PS> Invoke-AvmDoctor

    .EXAMPLE
        PS> avm doctor --json
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch] $Json
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $checks = New-Object System.Collections.Generic.List[pscustomobject]

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

    # AVM folder writability
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

    $failed = @($checks | Where-Object { $_.Status -ne 'OK' })
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
