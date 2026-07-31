function Test-AvmGitHubActionsContext {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    return -not [string]::IsNullOrWhiteSpace($env:GITHUB_ACTIONS)
}

function Test-AvmEnvironmentFlag {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    $raw = [System.Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $false
    }

    return @('1', 'true', 'yes', 'on') -contains $raw.Trim().ToLowerInvariant()
}

function Test-AvmDebugMode {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    # GitHub sets RUNNER_DEBUG=1 when a workflow is re-run with debug logging.
    return (Test-AvmEnvironmentFlag -Name 'RUNNER_DEBUG') -or (Test-AvmEnvironmentFlag -Name 'AVM_VERBOSE')
}

function Test-AvmVerboseEnabled {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (Test-AvmDebugMode) {
        return $true
    }

    $quiet = @('SilentlyContinue', 'Ignore')
    if ($quiet -notcontains [string]$VerbosePreference) {
        return $true
    }
    if ($quiet -notcontains [string]$DebugPreference) {
        return $true
    }

    return $false
}

function Format-AvmDuration {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [timespan] $Duration
    )

    if ($Duration.TotalSeconds -lt 1) {
        return '{0} ms' -f [int]$Duration.TotalMilliseconds
    }
    if ($Duration.TotalMinutes -lt 1) {
        return '{0:0.0}s' -f $Duration.TotalSeconds
    }
    if ($Duration.TotalHours -lt 1) {
        return '{0}m {1:00}s' -f [int]$Duration.TotalMinutes, $Duration.Seconds
    }

    return '{0}h {1:00}m {2:00}s' -f [int]$Duration.TotalHours, $Duration.Minutes, $Duration.Seconds
}

function Format-AvmTimestamp {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [datetime] $Timestamp
    )

    return $Timestamp.ToUniversalTime().ToString('HH:mm:ss', [cultureinfo]::InvariantCulture) + 'Z'
}

function Format-AvmTimingSuffix {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $InputObject
    )

    $props = $InputObject.PSObject.Properties

    $parts = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $props['DurationMs'] -and $null -ne $props['DurationMs'].Value) {
        $parts.Add((Format-AvmDuration -Duration ([timespan]::FromMilliseconds([double]$props['DurationMs'].Value))))
    }

    $hasStart = ($null -ne $props['StartTime']) -and ($null -ne $props['StartTime'].Value)
    $hasEnd = ($null -ne $props['EndTime']) -and ($null -ne $props['EndTime'].Value)
    if ($hasStart -and $hasEnd) {
        $from = Format-AvmTimestamp -Timestamp ([datetime]$props['StartTime'].Value)
        $to = Format-AvmTimestamp -Timestamp ([datetime]$props['EndTime'].Value)
        $parts.Add(('{0} -> {1}' -f $from, $to))
    }

    if ($parts.Count -eq 0) {
        return ''
    }

    return ' ({0})' -f ($parts -join '; ')
}

function Write-AvmLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [AllowEmptyString()]
        [string] $Message,

        [ValidateSet('Debug', 'Verbose', 'Info', 'Warning', 'Error')]
        [string] $Level = 'Info'
    )

    begin {
        Set-StrictMode -Version 3.0
        $ErrorActionPreference = 'Stop'
        $actions = Test-AvmGitHubActionsContext
    }

    process {
        $text = if ($null -eq $Message) { '' } else { $Message }

        switch ($Level) {
            'Debug' {
                if ($actions) {
                    Write-Information ('::debug::{0}' -f (ConvertTo-AvmAnnotationText -Text $text)) -InformationAction Continue
                }
                else {
                    Write-Debug $text
                }
            }
            'Verbose' {
                if ($actions -and -not (Test-AvmVerboseEnabled)) {
                    Write-Information ('::debug::{0}' -f (ConvertTo-AvmAnnotationText -Text $text)) -InformationAction Continue
                }
                else {
                    Write-Verbose $text -Verbose:(Test-AvmVerboseEnabled)
                }
            }
            'Warning' {
                if ($actions) {
                    Write-Information ('::warning::{0}' -f (ConvertTo-AvmAnnotationText -Text $text)) -InformationAction Continue
                }
                else {
                    Write-Warning $text
                }
            }
            'Error' {
                if ($actions) {
                    Write-Information ('::error::{0}' -f (ConvertTo-AvmAnnotationText -Text $text)) -InformationAction Continue
                }
                else {
                    Write-Information $text -InformationAction Continue
                }
            }
            default {
                Write-Information $text -InformationAction Continue
            }
        }
    }
}

function ConvertTo-AvmAnnotationText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }

    return $Text.Replace("`r", '').Replace("`n", '%0A')
}

function Enter-AvmLogGroup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    if (Test-AvmGitHubActionsContext) {
        Write-Information ('::group::{0}' -f (ConvertTo-AvmAnnotationText -Text $Name)) -InformationAction Continue
    }
}

function Exit-AvmLogGroup {
    [CmdletBinding()]
    param()

    if (Test-AvmGitHubActionsContext) {
        Write-Information '::endgroup::' -InformationAction Continue
    }
}
