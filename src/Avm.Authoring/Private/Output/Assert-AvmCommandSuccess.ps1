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

    Write-AvmLog ('avm {0} failed ({1}).' -f $Verb, $Status) -Level Error
    if (-not [string]::IsNullOrWhiteSpace($detail)) {
        Write-AvmLog ('  {0}' -f $detail) -Level Error
    }

    & ([scriptblock]::Create('param($e) throw $e')) $exception
}
