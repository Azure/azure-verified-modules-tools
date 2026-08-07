function Invoke-AvmPrCheck {
    <#
    .SYNOPSIS
        Run the pull-request linting and drift gauntlet against the resolved module:
        sync -> format -> transform -> lint -> check policy ->
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

        The 'validate' step is a build-validation pass ('terraform
        validate' / 'bicep build'), not a test run. Unit tests remain a
        separate CI job so a failure produces one actionable signal and
        fork contributors receive results without environment approval.
        The convention step requires a tests/unit/*.tftest.hcl fixture,
        preventing an empty unit tier from reading as a green gauntlet.

        The chain opens with the managed-files sync step (terraform
        only) in **drift-check mode** (-CheckDrift): unlike pre-commit,
        which reconciles the governed files by writing them, pr-check
        writes nothing and instead treats any needed add/update/remove
        as Status='fail'. This makes stale governed files a hard CI
        failure so the module is refreshed before merge rather than
        silently rewritten in CI. For bicep the sync step throws
        AvmConfigurationException and is skipped.

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
        [pscustomobject]@{ Name = 'sync'; Cmdlet = 'Invoke-AvmSync'; ExtraArgs = @{ CheckDrift = $true } }
        [pscustomobject]@{ Name = 'format'; Cmdlet = 'Invoke-AvmFormat'; ExtraArgs = @{ CheckDrift = $true } }
        [pscustomobject]@{ Name = 'transform'; Cmdlet = 'Invoke-AvmTransform'; ExtraArgs = @{ CheckDrift = $true } }
        [pscustomobject]@{ Name = 'lint'; Cmdlet = 'Invoke-AvmLint' }
        [pscustomobject]@{ Name = 'check policy'; Cmdlet = 'Invoke-AvmCheckPolicy' }
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
        $stepIndex++
        $stepStart = [datetime]::UtcNow
        $stepSw = [System.Diagnostics.Stopwatch]::StartNew()

        Write-AvmLog ('step {0}/{1}: {2} (started {3})' -f $stepIndex, $stepDefs.Count, $def.Name, (Format-AvmTimestamp -Timestamp $stepStart)) -Level Info | Out-Null

        try {
            $extraArgs = if ($def.PSObject.Properties.Name -contains 'ExtraArgs' -and $def.ExtraArgs) { $def.ExtraArgs } else { @{} }
            $stepResult = & $def.Cmdlet `
                -Path $context.Root `
                -Ecosystem $context.Ecosystem `
                -AllowPathFallback:$AllowPathFallback `
                @extraArgs

            if ($stepResult -and $stepResult.PSObject.Properties.Name -contains 'Status') {
                $stepStatus = $stepResult.Status
            }
        }
        catch [AvmNotSupportedException] {
            # Verb genuinely does not apply to this ecosystem. Continue the
            # chain; do not flip overall status.
            $stepStatus = 'skipped'
            $stepError = $_.Exception.Message
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

        $completionLevel = if ($stepStatus -eq 'pass') { 'Pass' } else { 'Info' }
        Write-AvmLog ('step {0}/{1}: {2} -> {3} ({4})' -f $stepIndex, $stepDefs.Count, $def.Name, $stepStatus, (Format-AvmDuration -Duration $stepSw.Elapsed)) -Level $completionLevel | Out-Null

        if ($stepStatus -in @('fail', 'error') -and -not [string]::IsNullOrWhiteSpace($stepError)) {
            # F41: narration only. Assert-AvmCommandSuccess promotes the same
            # text to the single GitHub Actions annotation for the run.
            Write-AvmLog ('  {0}: {1}' -f $def.Name, $stepError) -Level Info | Out-Null
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
