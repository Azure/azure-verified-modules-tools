function Invoke-AvmPreCommit {
    <#
    .SYNOPSIS
        Run the standard pre-commit gauntlet against the resolved module:
        format -> lint -> test -> docs.

    .DESCRIPTION
        Composition cmdlet. Resolves the module context once with
        Get-AvmModuleContext, then invokes Invoke-AvmFormat, Invoke-AvmLint,
        Invoke-AvmTest, and Invoke-AvmDocs in sequence against that same
        module root. Each step's structured result is captured. The overall
        Status is 'pass' only when every executed step reports
        Status='pass' (format reports an implicit pass when no errors are
        thrown).

        Status semantics:
          - 'pass'    : step returned Status='pass' (or didn't throw for
                        format).
          - 'fail'    : step returned Status='fail'.
          - 'error'   : step threw any exception other than
                        AvmConfigurationException; the chain aborts.
          - 'skipped' : step threw AvmConfigurationException - the engine
                        is a deliberate placeholder for a future slice
                        (e.g. bicep-docs). The chain CONTINUES and
                        overall status is NOT marked failed by a skip.

        By default the gauntlet is fail-soft: a step that returns
        Status='fail' (e.g. lint diagnostics) does NOT abort subsequent
        steps - the caller gets the full picture in one run. A step that
        THROWS (non-AvmConfigurationException) IS fatal and aborts the
        rest of the chain. Set -StopOnFail to abort on the first
        Status='fail' instead.

        Routed by the dispatcher: 'avm pre-commit'.

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
          - Steps       : array of { Step, Status, Error?, Result? }
          - DurationMs  : total wall-clock cost

    .EXAMPLE
        avm pre-commit

    .EXAMPLE
        Invoke-AvmPreCommit -Path C:\repos\my-module -StopOnFail
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string] $Path = $PWD.Path,

        [ValidateSet('auto', 'bicep', 'terraform')]
        [string] $Ecosystem = 'auto',

        [switch] $AllowPathFallback,

        [switch] $StopOnFail
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $context = Get-AvmModuleContext -Path $Path -Ecosystem $Ecosystem

    $stepDefs = @(
        [pscustomobject]@{ Name = 'format'; Cmdlet = 'Invoke-AvmFormat' }
        [pscustomobject]@{ Name = 'lint'; Cmdlet = 'Invoke-AvmLint' }
        [pscustomobject]@{ Name = 'test'; Cmdlet = 'Invoke-AvmTest' }
        [pscustomobject]@{ Name = 'docs'; Cmdlet = 'Invoke-AvmDocs' }
    )

    $steps = New-Object System.Collections.Generic.List[object]
    $overall = 'pass'

    foreach ($def in $stepDefs) {
        $stepStatus = 'pass'
        $stepError = $null
        $stepResult = $null
        $stepSw = [System.Diagnostics.Stopwatch]::StartNew()

        try {
            $stepResult = & $def.Cmdlet `
                -Path $context.Root `
                -Ecosystem $context.Ecosystem `
                -AllowPathFallback:$AllowPathFallback

            # Engine result objects carry their own Status; format does not
            # (it has no concept of failure unless something throws).
            if ($stepResult -and $stepResult.PSObject.Properties.Name -contains 'Status') {
                $stepStatus = $stepResult.Status
            }
        }
        catch [AvmConfigurationException] {
            # Deliberate placeholder engine (e.g. bicep-docs). Continue the
            # chain; do not flip overall status.
            $stepStatus = 'skipped'
            $stepError = $_.Exception.Message
        }
        catch {
            $stepStatus = 'error'
            $stepError = $_.Exception.Message
        }
        $stepSw.Stop()

        $steps.Add([pscustomobject][ordered]@{
                Step       = $def.Name
                Status     = $stepStatus
                Error      = $stepError
                Result     = $stepResult
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
        DurationMs = [int]$sw.Elapsed.TotalMilliseconds
    }
}
