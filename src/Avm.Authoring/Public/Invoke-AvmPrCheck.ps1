function Invoke-AvmPrCheck {
    <#
    .SYNOPSIS
        Run the pull-request linting and drift gauntlet against the resolved module:
        metadata -> sync -> format -> transform -> lint -> check policy ->
        check convention -> validate -> docs.

    .DESCRIPTION
        Composition cmdlet. Resolves the module context once with
        Get-AvmModuleContext, then invokes the full Phase 1 verb chain in
        sequence against that same module root. Each step's structured
        result is captured. The overall Status is 'pass' only when every
        executed step reports Status='pass' (or didn't throw, for verbs
        that don't carry a Status field).

        This is the broader sibling of Invoke-AvmPreCommit. It adds the
        credentialled policy evaluation and read-only drift checks used to
        verify that pre-commit output is current. Before any step runs, git
        status must report a clean working tree.
        Metadata validation runs after tool resolution but before the other steps.
        Missing or invalid root or child metadata aborts the chain without
        changing module files or reading indexes, regardless of StopOnFail.

        The 'validate' step is a build-validation pass ('terraform
        validate' / 'bicep build'), not a test run. Unit tests remain a
        separate CI job so a failure produces one actionable signal and
        fork contributors receive results without environment approval.
        The convention step requires a tests/unit/*.tftest.hcl fixture,
        preventing an empty unit tier from reading as a green gauntlet.

        After metadata validation, the managed-files sync step (terraform
        only) in **drift-check mode** (-CheckDrift): unlike pre-commit,
        which reconciles the governed files by writing them, pr-check
        writes nothing and instead treats any needed add/update/remove
        as Status='fail'. This makes stale governed files a hard CI
        failure so the module is refreshed before merge rather than
        silently rewritten in CI. For Bicep the sync step is unsupported and
        skipped. Bicep policy runs the required and advisory PSRule baselines
        when its repository config and selected test sources are available;
        missing inputs fail the check. Bicep policy, convention, and docs
        must report inspectable results rather than skipping. Convention
        coverage is still incomplete and fails the run until the remaining
        checks are covered.

        The sync step also gates on the managed-files release recorded in
        '.avm/managed-files-version.json': governed files are compared against
        that pinned release, and a superseded major version is reported as a
        drift issue so the run fails until the repository adopts it with
        'avm pre-commit -Upgrade'.

        Status semantics (same as Invoke-AvmPreCommit):
          - 'pass'    : step returned Status='pass' (or didn't throw for
                        format).
          - 'fail'    : step returned Status='fail'.
          - 'error'   : step threw an unexpected exception; the chain aborts.
          - 'skipped' : step threw AvmNotSupportedException because it does
                        not apply to the selected ecosystem.
          - configuration exceptions are failures, not skips.

        By default the gauntlet is fail-soft: a step that returns
        Status='fail' does NOT abort subsequent steps - the caller gets
        the full picture in one run. A step that THROWS (non-
        AvmConfigurationException) IS fatal and aborts the rest of the
        chain. Set -StopOnFail to abort on the first Status='fail'
        instead.

        Routed by the dispatcher: 'avm pr-check'.

    .PARAMETER Path
        Working directory whose enclosing module to validate. Defaults to
        the current location.

    .PARAMETER Ecosystem
        Force the ecosystem selector. Defaults to 'auto'.

    .PARAMETER AllowPathFallback
        When set, accept a PATH-resolved tool binary that self-reports the
        lock-pinned version. Forwarded to each step.

    .PARAMETER StopOnFail
        When set, abort the chain on the first step whose Status is 'fail'.
        A throwing step is always fatal regardless of this flag.

    .PARAMETER ThrottleLimit
        Maximum number of independent Terraform transform targets, lint scopes,
        or policy examples to process at once. Defaults to four.

    .OUTPUTS
        pscustomobject with:
          - Path        : the resolved module root
          - Ecosystem   : bicep | terraform
          - Status      : pass | fail | error
          - Steps       : array of { Step, Status, Error?, Result?, DurationMs }
          - DurationMs  : total wall-clock cost

    .EXAMPLE
        avm pr-check

    .EXAMPLE
        Invoke-AvmPrCheck -Path C:\repos\my-module -StopOnFail
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string] $Path = $PWD.Path,

        [ValidateSet('auto', 'bicep', 'terraform')]
        [string] $Ecosystem = 'auto',

        [switch] $AllowPathFallback,

        [switch] $StopOnFail,

        [ValidateRange(1, 32)]
        [int] $ThrottleLimit = 4,

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck

    $startTime = [datetime]::UtcNow
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $context = Get-AvmModuleContext -Path $Path -Ecosystem $Ecosystem
    Write-AvmLog ("pr-check: module root = {0}; ecosystem = {1}" -f $context.Root, $context.Ecosystem) -Level Verbose | Out-Null
    Assert-AvmGitWorkingTreeClean -Path $context.Root
    $null = Resolve-AvmCommandTool -Command 'pr-check' -Ecosystem $context.Ecosystem -AllowPathFallback:$AllowPathFallback

    $stepDefs = @(
        [pscustomobject]@{
            Name        = 'metadata'
            Cmdlet      = 'Test-AvmMetadataModules'
            ContextOnly = $true
            ExtraArgs   = @{ Context = $context }
        }
        [pscustomobject]@{ Name = 'sync'; Cmdlet = 'Invoke-AvmSync'; ExtraArgs = @{ CheckDrift = $true } }
        [pscustomobject]@{ Name = 'format'; Cmdlet = 'Invoke-AvmFormat'; ExtraArgs = @{ CheckDrift = $true } }
        [pscustomobject]@{
            Name = 'transform'; Cmdlet = 'Invoke-AvmTransform'
            ExtraArgs = @{ CheckDrift = $true; ThrottleLimit = $ThrottleLimit }
        }
        [pscustomobject]@{
            Name = 'lint'; Cmdlet = 'Invoke-AvmLint'
            ExtraArgs = @{ ThrottleLimit = $ThrottleLimit }
        }
        [pscustomobject]@{
            Name = 'check policy'; Cmdlet = 'Invoke-AvmCheckPolicy'
            ExtraArgs = @{ ThrottleLimit = $ThrottleLimit }
        }
        [pscustomobject]@{ Name = 'check convention'; Cmdlet = 'Invoke-AvmCheckConvention' }
        [pscustomobject]@{ Name = 'validate'; Cmdlet = 'Invoke-AvmTest' }
        [pscustomobject]@{ Name = 'docs'; Cmdlet = 'Invoke-AvmDocs'; ExtraArgs = @{ CheckDrift = $true } }
    )

    $steps = New-Object System.Collections.Generic.List[object]
    $overall = 'pass'
    $stepIndex = 0

    foreach ($def in $stepDefs) {
        $stepStatus = 'pass'
        $stepError = $null
        $stepResult = $null
        $requiredBicepStep = $context.Ecosystem -eq 'bicep' -and
        $def.Name -in @('check policy', 'check convention', 'docs')
        $stepIndex++
        $stepStart = [datetime]::UtcNow
        $stepSw = [System.Diagnostics.Stopwatch]::StartNew()

        Write-AvmLog ('step {0}/{1}: {2} (started {3})' -f $stepIndex, $stepDefs.Count, $def.Name, (Format-AvmTimestamp -Timestamp $stepStart)) -Level Info | Out-Null

        try {
            $extraArgs = if ($def.PSObject.Properties.Name -contains 'ExtraArgs' -and $def.ExtraArgs) { $def.ExtraArgs } else { @{} }
            $stepParameters = @{}
            if (-not $def.PSObject.Properties['ContextOnly'] -or -not $def.ContextOnly) {
                $stepParameters = @{
                    Path              = $context.Root
                    Ecosystem         = $context.Ecosystem
                    AllowPathFallback = $AllowPathFallback
                }
            }
            $stepResult = Invoke-AvmNestedCommand {
                & $def.Cmdlet @stepParameters @extraArgs
            }

            $hasStatus = $stepResult -and $stepResult.PSObject.Properties.Name -contains 'Status'
            if ($hasStatus) {
                $stepStatus = $stepResult.Status
            }
            if ($requiredBicepStep) {
                if (-not $hasStatus) {
                    $stepStatus = 'fail'
                    $stepError = "Required Bicep $($def.Name) returned no status; keep the registry static-validation jobs until this check runs."
                }
                elseif ($stepStatus -isnot [string]) {
                    $stepStatus = 'fail'
                    $stepError = "Required Bicep $($def.Name) returned an invalid status; keep the registry static-validation jobs until this check runs."
                }
                elseif ($stepStatus -eq 'skipped') {
                    $stepStatus = 'fail'
                    $stepError = "Required Bicep $($def.Name) returned skipped; keep the registry static-validation jobs until this check runs."
                }
                elseif ($stepStatus -notin @('pass', 'fail', 'error')) {
                    $stepError = "Required Bicep $($def.Name) returned an invalid status; keep the registry static-validation jobs until this check runs."
                    $stepStatus = 'fail'
                }
            }
            if ($context.Ecosystem -eq 'bicep' -and $def.Name -eq 'docs' -and
                $stepStatus -eq 'pass') {
                $fields = @($stepResult.PSObject.Properties.Name)
                $validShape = 'FilesSelected' -in $fields -and
                'FilesProcessed' -in $fields -and
                'NotRendered' -in $fields -and
                'Issues' -in $fields -and
                $stepResult.FilesSelected -is [int] -and
                $stepResult.FilesProcessed -is [int] -and
                $stepResult.FilesSelected -ge 0 -and
                $stepResult.FilesProcessed -ge 0 -and
                $stepResult.NotRendered -is [array] -and
                $stepResult.Issues -is [array]
                if (-not $validShape) {
                    $stepStatus = 'fail'
                    $stepError = 'avm.bicep.docs-result: Bicep docs reported pass without valid render counts, NotRendered, and Issues; keep the registry README check.'
                }
                elseif ($stepResult.FilesSelected -ne $stepResult.FilesProcessed) {
                    $stepStatus = 'fail'
                    $stepError = "avm.bicep.docs-result: Bicep docs rendered $($stepResult.FilesProcessed) of $($stepResult.FilesSelected) selected READMEs; keep the registry README check."
                }
                elseif (@($stepResult.Issues | Where-Object {
                            $null -eq $_ -or
                            $_.PSObject.Properties.Name -notcontains 'Severity' -or
                            $_.Severity -isnot [string] -or
                            $_.Severity -notin @('warning', 'notice', 'info')
                        }).Count -gt 0) {
                    $stepStatus = 'fail'
                    $stepError = 'avm.bicep.docs-result: Bicep docs reported pass with an error or unclassified issue; keep the registry README check.'
                }
            }
        }
        catch [AvmNotSupportedException] {
            if ($requiredBicepStep) {
                $stepStatus = 'fail'
                $stepError = "Required Bicep $($def.Name) is not implemented: $($_.Exception.Message)"
            }
            else {
                $stepStatus = 'skipped'
                $stepError = $_.Exception.Message
            }
        }
        catch [AvmConfigurationException] {
            # The repo is misconfigured, not unsupported. This must fail rather
            # than skip: a skip renders as a benign gauntlet pass, which is how
            # a step that never actually ran gets to look green.
            $stepStatus = 'fail'
            $stepError = $_.Exception.Message
        }
        catch {
            $stepStatus = 'error'
            $stepError = $_.Exception.Message
        }
        $stepSw.Stop()
        $stepEnd = $stepStart.AddMilliseconds($stepSw.Elapsed.TotalMilliseconds)

        $completionLevel = if ($stepStatus -eq 'pass') { 'Pass' } elseif ($stepStatus -in @('fail', 'error')) { 'Fail' } else { 'Info' }
        Write-AvmLog ('step {0}/{1}: {2} -> {3} ({4})' -f $stepIndex, $stepDefs.Count, $def.Name, $stepStatus, (Format-AvmDuration -Duration $stepSw.Elapsed)) -Level $completionLevel | Out-Null

        if ($stepStatus -in @('fail', 'error') -and -not [string]::IsNullOrWhiteSpace($stepError)) {
            # F41: narration only. Assert-AvmCommandSuccess promotes the same
            # text to the single GitHub Actions annotation for the run.
            Write-AvmLog ('  {0}: {1}' -f $def.Name, $stepError) -Level Fail | Out-Null
        }

        $steps.Add([pscustomobject][ordered]@{
                Step       = $def.Name
                Status     = $stepStatus
                Error      = $stepError
                Result     = $stepResult
                StartTime  = $stepStart
                EndTime    = $stepEnd
                DurationMs = [int]$stepSw.Elapsed.TotalMilliseconds
            })

        if ($stepStatus -eq 'fail' -or $stepStatus -eq 'error') { $overall = $stepStatus }
        if ($stepStatus -eq 'error') { break }
        if ($def.Name -eq 'metadata' -and $stepStatus -ne 'pass') { break }
        if ($StopOnFail -and $stepStatus -eq 'fail') { break }
    }

    $sw.Stop()

    return [pscustomobject][ordered]@{
        Path       = $context.Root
        Ecosystem  = $context.Ecosystem
        Status     = $overall
        Steps      = $steps.ToArray()
        StartTime  = $startTime
        EndTime    = $startTime.AddMilliseconds($sw.Elapsed.TotalMilliseconds)
        DurationMs = [int]$sw.Elapsed.TotalMilliseconds
    }
}
