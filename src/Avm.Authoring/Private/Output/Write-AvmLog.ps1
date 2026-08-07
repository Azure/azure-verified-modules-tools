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

function Test-AvmColorEnabled {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ($null -ne [System.Environment]::GetEnvironmentVariable('NO_COLOR')) {
        return $false
    }
    $colorForce = [System.Environment]::GetEnvironmentVariable('CLICOLOR_FORCE')
    if (-not [string]::IsNullOrWhiteSpace($colorForce) -and $colorForce.Trim() -ne '0') {
        return $true
    }

    try {
        return -not [Console]::IsOutputRedirected -and -not [Console]::IsErrorRedirected
    }
    catch {
        return $false
    }
}

function Format-AvmLogText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text,

        [Parameter(Mandatory)]
        [ValidateSet('Debug', 'Verbose', 'Info', 'Pass', 'Install', 'Warning', 'Error')]
        [string] $Level
    )

    if (-not (Test-AvmColorEnabled)) {
        return $Text
    }

    $code = switch ($Level) {
        'Pass' { '32' }
        'Install' { '36' }
        'Warning' { '33' }
        'Error' { '31' }
        'Verbose' { '90' }
        'Debug' { '90' }
        default { '' }
    }
    if (-not $code) {
        return $Text
    }

    $escape = [char]27
    return "$escape[$($code)m$Text$escape[0m"
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

        [ValidateSet('Debug', 'Verbose', 'Info', 'Pass', 'Install', 'Warning', 'Error')]
        [string] $Level = 'Info',

        [AllowEmptyString()]
        [string] $File = '',

        [int] $Line = 0,

        [int] $Column = 0
    )

    begin {
        Set-StrictMode -Version 3.0
        $ErrorActionPreference = 'Stop'
        $actions = Test-AvmGitHubActionsContext
    }

    process {
        $text = if ($null -eq $Message) { '' } else { $Message }
        $position = Format-AvmAnnotationProperty -File $File -Line $Line -Column $Column
        $displayText = if ($actions) { $text } else { Format-AvmLogText -Text $text -Level $Level }

        switch ($Level) {
            'Debug' {
                if ($actions) {
                    Write-Information ('::debug::{0}' -f (ConvertTo-AvmAnnotationText -Text $text)) -InformationAction Continue
                }
                else {
                    Write-Debug $displayText
                }
            }
            'Verbose' {
                if ($actions -and -not (Test-AvmVerboseEnabled)) {
                    Write-Information ('::debug::{0}' -f (ConvertTo-AvmAnnotationText -Text $text)) -InformationAction Continue
                }
                else {
                    Write-Verbose $displayText -Verbose:(Test-AvmVerboseEnabled)
                }
            }
            'Warning' {
                if ($actions) {
                    Write-Information ('::warning{0}::{1}' -f $position, (ConvertTo-AvmAnnotationText -Text $text)) -InformationAction Continue
                }
                else {
                    Write-Warning $displayText
                }
            }
            'Error' {
                if ($actions) {
                    Write-Information ('::error{0}::{1}' -f $position, (ConvertTo-AvmAnnotationText -Text $text)) -InformationAction Continue
                }
                else {
                    Write-Information $displayText -InformationAction Continue
                }
            }
            'Pass' {
                Write-Information $displayText -InformationAction Continue
            }
            'Install' {
                Write-Information $displayText -InformationAction Continue
            }
            default {
                Write-Information $displayText -InformationAction Continue
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

    # Console indentation is load-bearing locally but leaks into the annotation
    # payload in GitHub Actions, so it is stripped on this branch only.
    return $Text.TrimStart().Replace("`r", '').Replace("`n", '%0A')
}

function ConvertTo-AvmAnnotationPath {
    <#
    .SYNOPSIS
        Normalise a diagnostic path into the form GitHub anchors annotations on.

    .DESCRIPTION
        An annotation is only rendered inline on the failing line in the PR
        Files-changed view when its path is repo-relative and uses forward
        slashes. Terraform emits OS paths, so a Windows run yields
        'tests\unit\x.tftest.hcl', which GitHub cannot match against the diff.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    $normalised = $Path.Trim().Replace('\', '/')

    $roots = @($env:GITHUB_WORKSPACE, (Get-Location).Path) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($root in $roots) {
        $prefix = $root.Replace('\', '/').TrimEnd('/') + '/'
        if ($normalised.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $normalised = $normalised.Substring($prefix.Length)
            break
        }
    }

    while ($normalised.StartsWith('./')) {
        $normalised = $normalised.Substring(2)
    }

    return $normalised
}

function Format-AvmAnnotationProperty {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $File = '',

        [int] $Line = 0,

        [int] $Column = 0
    )

    $path = ConvertTo-AvmAnnotationPath -Path $File
    if ([string]::IsNullOrWhiteSpace($path)) {
        return ''
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add('file={0}' -f $path.Replace(',', '%2C'))
    if ($Line -gt 0) {
        $parts.Add('line={0}' -f $Line)
        if ($Column -gt 0) {
            $parts.Add('col={0}' -f $Column)
        }
    }

    return ' ' + ($parts -join ',')
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
