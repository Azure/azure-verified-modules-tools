$script:AvmGitHubDiagnosticCounts = @{ Warning = 0; Error = 0 }
$script:AvmGitHubDiagnosticOverflow = [System.Collections.Generic.List[object]]::new()
$script:AvmParallelDiagnosticTransfer = $false

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

function Test-AvmNestedCommandContext {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    return $script:AvmNestedCommandDepth -gt 0
}

function Invoke-AvmNestedCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock] $ScriptBlock
    )

    $script:AvmNestedCommandDepth++
    try {
        & $ScriptBlock
    }
    finally {
        $script:AvmNestedCommandDepth--
    }
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
    if (Test-AvmGitHubActionsContext) {
        return $false
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
        [ValidateSet('Debug', 'Verbose', 'Info', 'Pass', 'Fail', 'Install', 'Warning', 'Error')]
        [string] $Level
    )

    if (-not (Test-AvmColorEnabled)) {
        return $Text
    }

    $code = switch ($Level) {
        'Pass' { '32' }
        'Fail' { '31' }
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
        return '{0}m {1:00}s' -f $Duration.Minutes, $Duration.Seconds
    }

    return '{0}h {1:00}m {2:00}s' -f [math]::Floor($Duration.TotalHours), $Duration.Minutes, $Duration.Seconds
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

        [ValidateSet('Debug', 'Verbose', 'Info', 'Pass', 'Fail', 'Install', 'Warning', 'Error')]
        [string] $Level = 'Info',

        [AllowEmptyString()]
        [string] $File = '',

        [int] $Line = 0,

        [int] $Column = 0,

        [string] $SourceRoot = (Get-Location).Path
    )

    begin {
        Set-StrictMode -Version 3.0
        $ErrorActionPreference = 'Stop'
        $actions = Test-AvmGitHubActionsContext
    }

    process {
        if (
            (Test-AvmNestedCommandContext) -and
            $Level -in @('Info', 'Pass') -and
            -not (Test-AvmVerboseEnabled)
        ) {
            return
        }

        if ($script:AvmParallelDiagnosticTransfer -and $Level -in @('Warning', 'Error')) {
            Write-Information -Tags 'AvmDiagnostic' -MessageData @{
                Message    = $Message
                Level      = $Level
                File       = $File
                Line       = $Line
                Column     = $Column
                SourceRoot = $SourceRoot
            } -InformationAction Continue
            return
        }

        $text = if ($null -eq $Message) { '' } else { $Message }
        $position = Format-AvmAnnotationProperty -File $File -Line $Line -Column $Column -SourceRoot $SourceRoot
        $diagnosticText = if ($Level -in @('Warning', 'Error')) {
            Format-AvmDiagnosticText -Text $text -File $File -Line $Line -Column $Column -SourceRoot $SourceRoot
        }
        else {
            $text
        }
        $displayText = Format-AvmLogText -Text $diagnosticText -Level $Level

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
                    if ($script:AvmGitHubDiagnosticCounts.Warning -lt 10) {
                        $script:AvmGitHubDiagnosticCounts.Warning++
                        Write-Information ('::warning{0}::{1}' -f $position, (ConvertTo-AvmAnnotationText -Text $diagnosticText)) -InformationAction Continue
                    }
                    else {
                        Add-AvmGitHubDiagnosticOverflow -Level Warning -Message $diagnosticText -File $File -Line $Line -Column $Column -SourceRoot $SourceRoot
                        # Legacy ##[ commands are recognised even after a line prefix.
                        Write-Information ('Warning: {0}' -f $diagnosticText.ReplaceLineEndings("`nWarning: ").Replace('##[', '##%5B')) -InformationAction Continue
                    }
                }
                else {
                    Write-Warning $displayText
                }
            }
            'Error' {
                if ($actions) {
                    if ($script:AvmGitHubDiagnosticCounts.Error -lt 10) {
                        $script:AvmGitHubDiagnosticCounts.Error++
                        Write-Information ('::error{0}::{1}' -f $position, (ConvertTo-AvmAnnotationText -Text $diagnosticText)) -InformationAction Continue
                    }
                    else {
                        Add-AvmGitHubDiagnosticOverflow -Level Error -Message $diagnosticText -File $File -Line $Line -Column $Column -SourceRoot $SourceRoot
                        Write-Information ('Error: {0}' -f $diagnosticText.ReplaceLineEndings("`nError: ").Replace('##[', '##%5B')) -InformationAction Continue
                    }
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
    return $Text.TrimStart().Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
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
        Relative diagnostics use their source directory, while known
        repository-relative paths retain their workspace anchor.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Path,

        [string] $SourceRoot = (Get-Location).Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    $normalised = $Path.Trim().Replace('\', '/')

    $root = if ([string]::IsNullOrWhiteSpace($env:GITHUB_WORKSPACE)) { $SourceRoot } else { $env:GITHUB_WORKSPACE }
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $prefix = $root.Replace('\', '/').TrimEnd('/') + '/'

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_WORKSPACE) -and $normalised -notmatch '^(?:[A-Za-z]:/|/)') {
        $sourcePrefix = [IO.Path]::GetRelativePath($root, $SourceRoot).Replace('\', '/').TrimEnd('/') + '/'
        $sourcePath = [IO.Path]::GetFullPath($normalised, $SourceRoot)
        $repositoryPath = [IO.Path]::GetFullPath($normalised, $root)
        $alreadyRepositoryRelative = $sourcePrefix -ne './' -and -not $sourcePrefix.StartsWith('../') -and $normalised.StartsWith($sourcePrefix, $comparison)
        $repositoryFile = $normalised -notmatch '(^|/)\.\.(/|$)' -and -not (Test-Path -LiteralPath $sourcePath) -and (Test-Path -LiteralPath $repositoryPath)
        if ($alreadyRepositoryRelative -or $repositoryFile) {
            $normalised = $repositoryPath.Replace('\', '/')
        }
        else {
            $normalised = $sourcePath.Replace('\', '/')
        }
    }
    elseif ([IO.Path]::IsPathFullyQualified($normalised)) {
        $normalised = [IO.Path]::GetFullPath($normalised).Replace('\', '/')
    }

    if ($normalised.StartsWith($prefix, $comparison)) {
        $normalised = $normalised.Substring($prefix.Length)
    }

    while ($normalised.StartsWith('./')) {
        $normalised = $normalised.Substring(2)
    }

    return $normalised
}

function Format-AvmDiagnosticText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text,

        [AllowEmptyString()]
        [string] $File = '',

        [int] $Line = 0,

        [int] $Column = 0,

        [string] $SourceRoot = (Get-Location).Path
    )

    $path = ConvertTo-AvmAnnotationPath -Path $File -SourceRoot $SourceRoot
    if ([string]::IsNullOrWhiteSpace($path) -and $Line -le 0) {
        return $Text
    }

    $location = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($path)) {
        $location.Add($path)
    }
    if ($Line -gt 0) {
        $location.Add('line {0}' -f $Line)
    }
    if ($Line -gt 0 -and $Column -gt 0) {
        $location.Add('column {0}' -f $Column)
    }

    return '{0} ({1})' -f $Text, ($location -join ', ')
}

function Format-AvmAnnotationProperty {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $File = '',

        [int] $Line = 0,

        [int] $Column = 0,

        [string] $SourceRoot = (Get-Location).Path
    )

    $path = ConvertTo-AvmAnnotationPath -Path $File -SourceRoot $SourceRoot
    if ([string]::IsNullOrWhiteSpace($path)) {
        return ''
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    $escapedPath = (ConvertTo-AvmAnnotationText -Text $path).Replace(':', '%3A').Replace(',', '%2C')
    $parts.Add('file={0}' -f $escapedPath)
    if ($Line -gt 0) {
        $parts.Add('line={0}' -f $Line)
        if ($Column -gt 0) {
            $parts.Add('col={0}' -f $Column)
        }
    }

    return ' ' + ($parts -join ',')
}

function Add-AvmGitHubDiagnosticOverflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Warning', 'Error')]
        [string] $Level,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Message,

        [AllowEmptyString()]
        [string] $File = '',

        [int] $Line = 0,

        [int] $Column = 0,

        [string] $SourceRoot = (Get-Location).Path
    )

    $diagnostic = [pscustomobject]@{
        Level   = $Level
        Message = $Message
        File    = ConvertTo-AvmAnnotationPath -Path $File -SourceRoot $SourceRoot
        Line    = $Line
        Column  = $Column
    }
    $script:AvmGitHubDiagnosticOverflow.Add($diagnostic)
}

function ConvertTo-AvmMarkdownText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text
    )

    $singleLine = $Text.ReplaceLineEndings(' ')
    return [regex]::Replace(
        $singleLine,
        '([\\`*_{}\[\]<>()#+\-.!|])',
        {
            param($match)
            '\' + $match.Value
        }
    )
}

function Write-AvmGitHubDiagnosticSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Diagnostics,

        [Parameter(Mandatory)]
        [string] $Reason
    )

    if ($Diagnostics.Count -eq 0) {
        return
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('### Additional AVM diagnostics')
    $lines.Add('')
    $lines.Add((ConvertTo-AvmMarkdownText -Text $Reason))
    $lines.Add('')
    foreach ($diagnostic in $Diagnostics) {
        $level = ([string]$diagnostic.Level).ToLowerInvariant()
        $message = ConvertTo-AvmMarkdownText -Text ([string]$diagnostic.Message)
        $lines.Add(('- **{0}:** {1}' -f $level, $message))
    }

    if ([string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        return
    }

    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ($lines -join "`n") -Encoding utf8 -ErrorAction Stop
}

function Send-AvmGitHubDiagnosticOverflow {
    [CmdletBinding()]
    param()

    if (-not (Test-AvmGitHubActionsContext) -or $script:AvmGitHubDiagnosticOverflow.Count -eq 0) {
        return
    }

    $diagnostics = @($script:AvmGitHubDiagnosticOverflow.ToArray())
    $script:AvmGitHubDiagnosticOverflow.Clear()
    $located = @(
        $diagnostics | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.File) -and
            $_.Line -gt 0 -and
            $_.File -notmatch '^(?:[A-Za-z]:/|/|\.\./)'
        }
    )
    $unlocated = @(
        $diagnostics | Where-Object {
            [string]::IsNullOrWhiteSpace($_.File) -or
            $_.Line -le 0 -or
            $_.File -match '^(?:[A-Za-z]:/|/|\.\./)'
        }
    )
    $reason = ''
    $published = $false

    if (
        $located.Count -gt 0 -and
        -not [string]::IsNullOrWhiteSpace($env:GH_TOKEN) -and
        $env:GITHUB_REPOSITORY -match '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -and
        $env:AVM_GITHUB_CHECK_RUN_ID -match '^[1-9][0-9]*$'
    ) {
        try {
            $endpoint = 'repos/{0}/check-runs/{1}' -f $env:GITHUB_REPOSITORY, $env:AVM_GITHUB_CHECK_RUN_ID
            $checkRun = Invoke-AvmGitHubApi -Endpoint $endpoint
            $output = if ($checkRun -is [System.Collections.IDictionary]) { $checkRun['output'] } else { $null }
            $title = if ($output -is [System.Collections.IDictionary] -and $output['title']) {
                [string]$output['title']
            }
            else {
                'AVM diagnostics'
            }
            $summary = if ($output -is [System.Collections.IDictionary] -and $output['summary']) {
                [string]$output['summary']
            }
            else {
                'Additional diagnostics emitted by Avm.Authoring.'
            }
            $annotations = @(
                foreach ($diagnostic in $located) {
                    $annotation = [ordered]@{
                        path             = [string]$diagnostic.File
                        start_line       = [int]$diagnostic.Line
                        end_line         = [int]$diagnostic.Line
                        annotation_level = if ($diagnostic.Level -eq 'Warning') { 'warning' } else { 'failure' }
                        message          = [string]$diagnostic.Message
                    }
                    if ($diagnostic.Column -gt 0) {
                        $annotation.start_column = [int]$diagnostic.Column
                        $annotation.end_column = [int]$diagnostic.Column
                    }
                    $annotation
                }
            )

            for ($offset = 0; $offset -lt $annotations.Count; $offset += 50) {
                $end = [Math]::Min($offset + 49, $annotations.Count - 1)
                $batch = @($annotations[$offset..$end])
                $body = @{
                    output = @{
                        title       = $title
                        summary     = $summary
                        annotations = $batch
                    }
                }
                $null = Invoke-AvmGitHubApi -Endpoint $endpoint -Method PATCH -Body $body
            }
            $published = $true
        }
        catch {
            $reason = if ($_.Exception -is [AvmGitHubException] -and $_.Exception.StatusCode -gt 0) {
                'Checks API publishing failed with HTTP {0}; diagnostics are listed below.' -f $_.Exception.StatusCode
            }
            else {
                'Checks API publishing failed; diagnostics are listed below.'
            }
        }
    }
    else {
        $reason = 'Checks API access was unavailable; diagnostics are listed below.'
    }

    if ($published -and $unlocated.Count -gt 0) {
        $reason = 'These diagnostics did not include a repository-relative file and line required for a Checks API annotation.'
        Write-AvmGitHubDiagnosticSummary -Diagnostics $unlocated -Reason $reason
    }
    elseif (-not $published) {
        Write-AvmGitHubDiagnosticSummary -Diagnostics $diagnostics -Reason $reason
    }
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
