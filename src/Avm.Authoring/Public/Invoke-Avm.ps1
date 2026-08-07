function Invoke-Avm {
    <#
    .SYNOPSIS
        Avm CLI dispatcher. The 'avm' alias is the user-facing entry point.

    .DESCRIPTION
        Routes a verb path like 'tool install foo' to the matching cmdlet by
        consulting Get-AvmVerbRegistry. Verb matching is case-sensitive and
        prefers the longest matching prefix; remaining arguments are passed
        through to the resolved cmdlet via splatting.

        The dispatcher is intentionally not declared as a [CmdletBinding] cmdlet
        so that unbound arguments such as '-Json' or '--json' flow through
        unchanged into $args rather than failing parameter binding at this layer.

    .EXAMPLE
        PS> avm

    .EXAMPLE
        PS> avm version

    .EXAMPLE
        PS> avm doctor --json

    .EXAMPLE
        PS> avm pre-commit --passthru
    #>
    [Alias('avm')]
    param(
        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $rawArguments = @($args)
    $verbPath = if ($rawArguments.Count -gt 0) {
        ([string[]]$rawArguments -join ' ')
    }
    else {
        'help'
    }

    try {
        $verboseRequested = Test-AvmDebugMode
        if (-not $verboseRequested) {
            $verboseRequested = @(
                $rawArguments |
                    Where-Object {
                        ([string]$_).ToLowerInvariant() -in @('-verbose', '--verbose')
                    }
            ).Count -gt 0
        }
        if ($verboseRequested) {
            $VerbosePreference = 'Continue'
            $PSDefaultParameterValues = if ($PSDefaultParameterValues) {
                $PSDefaultParameterValues.Clone()
            }
            else {
                @{}
            }
            $PSDefaultParameterValues['*:Verbose'] = $true
        }

        $isUpdateCommand = $rawArguments.Count -gt 0 -and [string]$rawArguments[0] -ceq 'update'
        if (-not $isUpdateCommand) {
            Test-AvmModuleVersion `
                -SkipModuleVersionCheck:$SkipModuleVersionCheck `
                -RefreshLatestVersion
            $PSDefaultParameterValues = if ($PSDefaultParameterValues) {
                $PSDefaultParameterValues.Clone()
            }
            else {
                @{}
            }
            $PSDefaultParameterValues['*:SkipModuleVersionCheck'] = $true
            $PSDefaultParameterValues['Test-AvmModuleVersion:SuppressSkipWarning'] = $true
        }

        # Honour .avm/.disable sentinel anywhere up the path: spec section 8.
        # The opt-out lets a repo turn the dispatcher off without uninstalling
        # the module. We honour it even for read-only verbs like 'avm version'
        # so the user can't accidentally rely on output that the maintainer
        # explicitly disabled.
        $sentinel = Test-AvmDisableSentinel
        if ($sentinel) {
            throw [AvmConfigurationException]::new(
                "avm is disabled in this repository (remove $sentinel to re-enable).")
        }

        $passThru = $false
        $arguments = @(
            foreach ($arg in $rawArguments) {
                $token = [string]$arg
                if ($token -in @('--passthru', '--pass-thru', '-PassThru', '-passthru')) {
                    $passThru = $true
                    continue
                }
                $arg
            }
        )
        $registry = @(Get-AvmVerbRegistry)

    # F09: bare 'avm', 'avm --help', 'avm -h' and 'avm help' all print the same
    # verb listing. A help token is only honoured when it is the sole argument
    # so it can never shadow a real verb path such as 'avm tool install'.
    $helpRequested = $arguments.Count -eq 0
    if (-not $helpRequested -and $arguments.Count -eq 1) {
        $first = [string]$arguments[0]
        if ($first -in @('--help', '-h', 'help')) { $helpRequested = $true }
    }

    if ($helpRequested) {
        Write-AvmLog 'Avm.Authoring CLI' -Level Info
        Write-AvmLog '' -Level Info
        Write-AvmLog 'Usage: avm <verb> [<args>]' -Level Info
        Write-AvmLog '' -Level Info
        Write-AvmLog 'Available verbs:' -Level Info
        foreach ($entry in $registry) {
            $verb = ($entry.Path -join ' ').PadRight(20)
            Write-AvmLog ('  {0}  {1}' -f $verb, $entry.Summary) -Level Info
        }
        return
    }

    # Find the longest verb-path prefix that matches the supplied arguments.
    $match = $null
    $matchLen = 0
    foreach ($entry in $registry) {
        $entryPath = @($entry.Path)
        $len = $entryPath.Count
        if ($arguments.Count -lt $len) { continue }
        $matched = $true
        for ($i = 0; $i -lt $len; $i++) {
            if ([string]$arguments[$i] -cne [string]$entryPath[$i]) {
                $matched = $false
                break
            }
        }
        if ($matched -and $len -gt $matchLen) {
            $match = $entry
            $matchLen = $len
        }
    }

    if (-not $match) {
        $supplied = ($arguments -join ' ')
        throw [System.ArgumentException]::new(
            "Unknown verb: '$supplied'. Run 'avm' with no arguments to list available verbs.")
    }

    $remaining = if ($arguments.Count -gt $matchLen) {
        $arguments[$matchLen..($arguments.Count - 1)]
    }
    else {
        @()
    }
    # An if/else expression that returns a single-element array is auto-
    # unwrapped to a scalar on assignment. Re-wrap here so that .Count and
    # indexer access stay safe under Set-StrictMode -Version 3.0.
    $remaining = @($remaining)

    $cmd = Get-Command -Name $match.Cmdlet -ErrorAction Stop

    # Translate the residual CLI-shaped args into named (hashtable) and
    # positional (array) splats. Array splatting alone does not reliably
    # promote '-foo' tokens to parameter names, so anything that looks like a
    # flag (single- or double-dash prefix, with optional '=value') is bound
    # by name. The lookup against $cmd.Parameters resolves parameter casing
    # via the dictionary's case-insensitive comparer, so callers may use
    # 'avm doctor --json' or 'avm doctor -Json' interchangeably.
    $bound = @{}
    $positional = [System.Collections.Generic.List[object]]::new()
    $i = 0
    while ($i -lt $remaining.Count) {
        $token = [string]$remaining[$i]
        $isFlag = ($token.Length -gt 1) -and ($token.StartsWith('-')) -and ($token -cne '--')

        if (-not $isFlag) {
            $positional.Add($remaining[$i])
            $i++
            continue
        }

        $name = if ($token.StartsWith('--')) { $token.Substring(2) } else { $token.Substring(1) }
        $inlineValue = $null
        $eq = $name.IndexOf('=')
        if ($eq -ge 0) {
            $inlineValue = $name.Substring($eq + 1)
            $name = $name.Substring(0, $eq)
        }

        if (-not $cmd.Parameters.ContainsKey($name)) {
            # Allow kebab-case flags ('--allow-path-fallback' -> 'AllowPathFallback').
            if ($name.Contains('-')) {
                $pascal = -join ($name -split '-' | ForEach-Object {
                        if ($_.Length -gt 0) { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) } else { '' }
                    })
                if ($cmd.Parameters.ContainsKey($pascal)) {
                    $name = $pascal
                }
            }
        }

        if (-not $cmd.Parameters.ContainsKey($name)) {
            throw [System.ArgumentException]::new(
                "Unknown parameter '$token' for $($match.Cmdlet).")
        }
        $param = $cmd.Parameters[$name]

        $canonical = $param.Name
        $isSwitch = $param.ParameterType -eq [System.Management.Automation.SwitchParameter]

        if ($isSwitch) {
            if ($null -ne $inlineValue) {
                $bound[$canonical] = [System.Convert]::ToBoolean($inlineValue)
            }
            else {
                $bound[$canonical] = $true
            }
            $i++
        }
        else {
            if ($null -ne $inlineValue) {
                $bound[$canonical] = $inlineValue
                $i++
            }
            elseif ($i + 1 -lt $remaining.Count) {
                $bound[$canonical] = $remaining[$i + 1]
                $i += 2
            }
            else {
                throw [System.ArgumentException]::new("Missing value for parameter '$token'.")
            }
        }
    }

        $verbPath = ($match.Path -join ' ')
        Write-AvmLog ('Starting avm {0}' -f $verbPath) -Level Info
        Write-AvmLog ('dispatch: cmdlet = {0}' -f $match.Cmdlet) -Level Verbose
        Write-AvmLog ('dispatch: positional arguments = {0}' -f ($positional -join ' | ')) -Level Verbose
        Write-AvmLog ('dispatch: bound parameters = {0}' -f (($bound.GetEnumerator() | Sort-Object Key | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join '; ')) -Level Verbose

        $result = & $cmd @bound @positional
    }
    catch [AvmException] {
        Assert-AvmCleanFailure -Verb $verbPath -Exception $_.Exception
    }

    $items = @($result | Where-Object { $null -ne $_ })
    $rendered = @($items | Where-Object { $null -ne $_.PSObject.Properties['Status'] })
    $passThrough = @($items | Where-Object { $null -eq $_.PSObject.Properties['Status'] })

    # F25: render once per invocation, not once per emitted object.
    if ($rendered.Count -gt 0) {
        Write-AvmResult -Result $rendered -Verb $verbPath
    }

    # F02: a gauntlet verb that reports Status 'fail' or 'error' must make the
    # hosting process exit non-zero, so wrapping git hooks and CI steps cannot
    # pass silently. Read-only verbs (e.g. 'version') emit no 'Status' property
    # and stream straight through untouched.
    foreach ($item in $rendered) {
        $status = ([string]$item.PSObject.Properties['Status'].Value).Trim()
        if ($status.ToLowerInvariant() -in @('fail', 'error')) {
            Assert-AvmCommandSuccess -Verb $verbPath -Status $status -Result $item
        }
    }

    # F23: the rendered summary is the interactive contract. Only hand the raw
    # result objects back when the caller asks for them; objects the renderer
    # did not consume (e.g. 'avm version') always stream through.
    if ($passThru) {
        return $result
    }

    return $passThrough
}
