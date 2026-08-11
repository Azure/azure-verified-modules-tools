function Invoke-AvmParallel {
    <#
    .SYNOPSIS
        Execute independent work with a bounded runspace pool.

    .DESCRIPTION
        Imports the current module into each worker, preserves input order, and
        replays information, warning, verbose, and debug streams deterministically.
        A throttle of one executes in the caller's runspace so Pester mocks and
        verbose live output retain their normal behavior.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Function')]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $InputObject,

        [Parameter(Mandatory, ParameterSetName = 'Function')]
        [ValidateNotNullOrEmpty()]
        [string] $FunctionName,

        [Parameter(Mandatory, ParameterSetName = 'Script')]
        [scriptblock] $ScriptBlock,

        [AllowNull()]
        $Argument,

        [ValidateRange(1, 32)]
        [int] $ThrottleLimit = 1
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($InputObject.Count -eq 0) {
        return
    }

    if ($ThrottleLimit -eq 1 -or $InputObject.Count -eq 1) {
        foreach ($item in $InputObject) {
            if ($PSCmdlet.ParameterSetName -eq 'Function') {
                & $FunctionName $item $Argument
            }
            else {
                & $ScriptBlock $item $Argument
            }
        }
        return
    }

    $modulePath = $MyInvocation.MyCommand.Module.Path
    $moduleManifest = Join-Path `
        -Path (Split-Path -Parent $modulePath) `
        -ChildPath 'Avm.Authoring.psd1'
    $workerCount = [Math]::Min($ThrottleLimit, $InputObject.Count)
    $nestedCommand = Test-AvmNestedCommandContext
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(
        1,
        $workerCount)
    $jobs = [System.Collections.Generic.List[object]]::new()
    $orderedResults = [object[]]::new($InputObject.Count)
    $workerScript = @'
param(
    [string] $ModuleManifest,
    [string] $FunctionName,
    [string] $ScriptText,
    $InputObject,
    $Argument,
    [string] $WorkerVerbosePreference,
    [string] $WorkerDebugPreference,
    [bool] $NestedCommand
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
$VerbosePreference = [System.Management.Automation.ActionPreference]$WorkerVerbosePreference
$DebugPreference = [System.Management.Automation.ActionPreference]$WorkerDebugPreference

Import-Module -Name $ModuleManifest -ErrorAction Stop

if (-not [string]::IsNullOrWhiteSpace($FunctionName)) {
    $module = Get-Module -Name 'Avm.Authoring' | Select-Object -First 1
    & $module {
        param($Name, $Item, $SharedArgument, $IsNested)
        if ($IsNested) {
            $script:AvmNestedCommandDepth++
        }
        try {
            & $Name $Item $SharedArgument
        }
        finally {
            if ($IsNested) {
                $script:AvmNestedCommandDepth--
            }
        }
    } $FunctionName $InputObject $Argument $NestedCommand
}
else {
    $worker = [scriptblock]::Create($ScriptText)
    & $worker $InputObject $Argument
}
'@

    try {
        $pool.Open()
        for ($index = 0; $index -lt $InputObject.Count; $index++) {
            $pipeline = [powershell]::Create()
            $pipeline.RunspacePool = $pool
            $workerFunction = if ($PSCmdlet.ParameterSetName -eq 'Function') {
                $FunctionName
            }
            else {
                ''
            }
            $workerText = if ($PSCmdlet.ParameterSetName -eq 'Script') {
                $ScriptBlock.ToString()
            }
            else {
                ''
            }
            $null = $pipeline.AddScript($workerScript)
            $null = $pipeline.AddArgument($moduleManifest)
            $null = $pipeline.AddArgument($workerFunction)
            $null = $pipeline.AddArgument($workerText)
            $null = $pipeline.AddArgument($InputObject[$index])
            $null = $pipeline.AddArgument($Argument)
            $null = $pipeline.AddArgument([string]$VerbosePreference)
            $null = $pipeline.AddArgument([string]$DebugPreference)
            $null = $pipeline.AddArgument($nestedCommand)
            $jobs.Add([pscustomobject]@{
                    Index      = $index
                    Pipeline   = $pipeline
                    AsyncState = $pipeline.BeginInvoke()
                })
        }

        foreach ($job in $jobs) {
            $failure = $null
            $output = @()
            try {
                $output = @($job.Pipeline.EndInvoke($job.AsyncState))
            }
            catch {
                $failure = $_.Exception
                while (
                    $null -ne $failure.InnerException -and
                    $failure -is [System.Management.Automation.RuntimeException]
                ) {
                    $failure = $failure.InnerException
                }
            }

            $errors = @($job.Pipeline.Streams.Error)
            if ($null -eq $failure -and $errors.Count -gt 0) {
                $failure = $errors[0].Exception
            }
            $orderedResults[$job.Index] = [pscustomobject]@{
                Output      = $output
                Failure     = $failure
                Information = @($job.Pipeline.Streams.Information)
                Warnings    = @($job.Pipeline.Streams.Warning)
                Verbose     = @($job.Pipeline.Streams.Verbose)
                Debug       = @($job.Pipeline.Streams.Debug)
            }
        }
    }
    finally {
        foreach ($job in $jobs) {
            $job.Pipeline.Dispose()
        }
        $pool.Dispose()
    }

    foreach ($result in $orderedResults) {
        foreach ($record in $result.Information) {
            Write-Information `
                -MessageData $record.MessageData `
                -Tags $record.Tags `
                -InformationAction Continue
        }
        foreach ($record in $result.Warnings) {
            Write-Warning $record.Message
        }
        foreach ($record in $result.Verbose) {
            Write-Verbose $record.Message -Verbose
        }
        foreach ($record in $result.Debug) {
            Write-Debug $record.Message -Debug
        }
        if ($null -ne $result.Failure) {
            throw $result.Failure
        }
    }

    foreach ($result in $orderedResults) {
        foreach ($item in $result.Output) {
            Write-Output $item
        }
    }
}
