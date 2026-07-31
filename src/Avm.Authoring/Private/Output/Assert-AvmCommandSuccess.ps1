function Assert-AvmCommandSuccess {
    <#
    .SYNOPSIS
        Fail the CLI cleanly when a verb reports 'fail' or 'error'.

    .DESCRIPTION
        F24: a detected failure is not a tooling crash, so it must not surface
        as a PowerShell source-position stack trace. The clean summary is
        written first, then the terminating error is raised from a dynamically
        created script block. A script block built with
        [scriptblock]::Create has no backing script file, so the default
        ConciseView renders only 'OperationStopped: <message>' instead of the
        module's own source line.

        The error remains a script-terminating throw so the hosting process
        still exits non-zero (F02).

        F41: exactly one GitHub Actions annotation is emitted per failed
        command, anchored on the failing file when the diagnostic carries a
        position. Annotations are capped at 10 per step, so every other line the
        CLI writes about the failure stays plain narration and cannot crowd the
        actionable one out.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Verb,

        [Parameter(Mandatory)]
        [string] $Status,

        [Parameter(Mandatory)]
        [object] $Result
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $detail = Get-AvmFailureDetail -Result $Result
    $exception = [AvmCommandException]::new($Verb, $Status, $Result, $detail)
    $summary = 'avm {0} failed ({1}).' -f $Verb, $Status

    if ([string]::IsNullOrWhiteSpace($detail)) {
        Write-AvmLog $summary -Level Error
    }
    else {
        Write-AvmLog $summary -Level Info

        $position = Get-AvmFailurePosition -Result $Result
        $anchor = @{}
        if ($null -ne $position) {
            $anchor['File'] = [string]$position.File
            if ([int]$position.Line -gt 0) { $anchor['Line'] = [int]$position.Line }
            if ([int]$position.Column -gt 0) { $anchor['Column'] = [int]$position.Column }
        }

        Write-AvmLog ('  {0}' -f $detail) -Level Error @anchor
    }

    & ([scriptblock]::Create('param($e) throw $e')) $exception
}

function Assert-AvmCleanFailure {
    <#
    .SYNOPSIS
        Re-raise a typed AVM exception without a source-position stack trace.

    .DESCRIPTION
        F24: every AvmException subclass carries an actionable message, so the
        dispatcher reports it as a one-line failure rather than letting the
        default ConciseView print the module file, line number and the throw
        source line. The error stays script-terminating so the hosting process
        exits non-zero.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Verb,

        [Parameter(Mandatory)]
        [object] $Exception
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    Write-AvmLog ('avm {0} failed: {1}' -f $Verb, $Exception.Message) -Level Error

    & ([scriptblock]::Create('param($e) throw $e')) $Exception
}
