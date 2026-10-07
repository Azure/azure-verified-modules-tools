function Invoke-AvmBicepPesterSuite {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)]
        [string[]] $Files,

        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [string] $ModuleRoot,

        [ValidateSet('Unit', 'E2e', 'Convention')]
        [string] $Mode = 'Unit',

        [string[]] $ModulePaths = @(),

        [string] $RepositoryRoot = '',

        [AllowEmptyCollection()]
        [string[]] $Tag = @(),

        [AllowEmptyCollection()]
        [string[]] $TestName = @(),

        [System.Collections.IDictionary] $TestInputData,

        [System.Collections.IDictionary] $ConventionData,

        [hashtable] $EnvVars = @{ GITHUB_ACTIONS = $null; GITHUB_STEP_SUMMARY = $null },

        [int] $TimeoutSec = 0,

        [switch] $InProcess
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if (-not $ModuleRoot) { $ModuleRoot = $WorkingDirectory }
    $pester = Import-AvmPowerShellModule -Name Pester -ModuleRoot $ModuleRoot

    $runnerPath = Join-Path -Path $PSScriptRoot -ChildPath '..' `
        -AdditionalChildPath '..', 'Resources', 'bicep', 'Invoke-AvmPesterSuite.ps1'
    $inputData = @{
        Mode           = $Mode
        Files          = $Files
        ModulePaths    = $ModulePaths
        RepositoryRoot = $RepositoryRoot
        Tag            = $Tag
        TestName       = $TestName
        TestInputData  = $TestInputData
        Convention     = $ConventionData
        PesterPath     = Join-Path $pester.ModuleBase 'Pester.psd1'
        PesterVersion  = $pester.Version.ToString()
    }
    if ($Mode -eq 'Convention' -and -not $InProcess) {
        throw [System.ArgumentException]::new('Convention suites must run in process.')
    }
    $runDirectory = $null
    $inputPath = $null
    $resultPath = $null
    try {
        if ($InProcess) {
            $run = Invoke-AvmBicepTestScript -Path $runnerPath -WorkingDirectory $WorkingDirectory `
                -Parameters @{ InputData = $inputData } -EnvVars $EnvVars -Confirm:$false
            if ($run.Output.Count -ne 1 -or
                $run.Output[0] -isnot [System.Collections.IDictionary]) {
                throw [AvmProcessException]::new('The in-process Bicep Pester runner did not return a valid summary.')
            }
            $raw = ConvertTo-Json -InputObject $run.Output[0] -Depth 8 -Compress
        }
        else {
            $runDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) `
                -ChildPath ('avm-pester-{0}' -f [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $runDirectory -ErrorAction Stop
            $inputPath = Join-Path $runDirectory 'input.json'
            $resultPath = Join-Path $runDirectory 'result.json'
            [System.IO.File]::WriteAllText(
                $inputPath, ($inputData | ConvertTo-Json -Depth 100 -Compress),
                [System.Text.UTF8Encoding]::new($false))
            $pwshPath = [System.Environment]::ProcessPath
            if ([string]::IsNullOrWhiteSpace($pwshPath)) {
                $pwshPath = (Get-Command -Name 'pwsh' -CommandType Application -ErrorAction Stop).Source
            }
            $processResult = Invoke-AvmProcess -FilePath $pwshPath `
                -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $runnerPath, '-InputPath', $inputPath, '-ResultPath', $resultPath) `
                -WorkingDirectory $WorkingDirectory -EnvVars $EnvVars -TimeoutSec $TimeoutSec -IgnoreExitCode
            if ($processResult.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
                $detail = Add-AvmProcessFailureDetail `
                    -Message "Bicep Pester runner failed (exit $($processResult.ExitCode))." `
                    -StdOut $processResult.StdOut -StdErr $processResult.StdErr
                throw [AvmProcessException]::new($detail)
            }
            $raw = Get-Content -LiteralPath $resultPath -Raw -Encoding utf8
        }
        if (-not (Test-Json -Json $raw -ErrorAction SilentlyContinue)) {
            throw [AvmProcessException]::new('Bicep Pester runner returned invalid JSON.')
        }
        $summary = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($summary -isnot [System.Collections.IDictionary]) {
            throw [AvmProcessException]::new('Bicep Pester runner did not return a summary object.')
        }
        foreach ($key in @('Version', 'Total', 'Passed', 'Failed', 'Skipped', 'Inconclusive', 'Filtered', 'Issues')) {
            if (-not $summary.Contains($key)) {
                throw [AvmProcessException]::new("Bicep Pester runner returned a summary without '$key'.")
            }
        }
        if ([string]::IsNullOrWhiteSpace([string]$summary.Version) -or
            $summary.Issues -isnot [array]) {
            throw [AvmProcessException]::new('Bicep Pester runner returned an invalid summary.')
        }
        foreach ($key in @('Total', 'Passed', 'Failed', 'Skipped', 'Inconclusive', 'Filtered')) {
            if ($summary[$key] -isnot [int] -and $summary[$key] -isnot [long] -or
                $summary[$key] -lt 0 -or $summary[$key] -gt [int]::MaxValue) {
                throw [AvmProcessException]::new("Bicep Pester runner returned an invalid '$key' count.")
            }
        }
        foreach ($issue in @($summary.Issues)) {
            $nativeConvention = $Mode -ceq 'Convention' -and
            $issue -is [System.Collections.IDictionary] -and
            $issue.Contains('NativeConvention') -and $issue['NativeConvention'] -is [bool] -and
            $issue['NativeConvention'] -and [string]$issue['Code'] -cmatch '^(?:avm\.bicep\.[a-zA-Z0-9.-]+|AVM_METADATA_[A-Z_]+)$' -and
            $issue['Severity'] -cin @('error', 'warning')
            if ($issue -isnot [System.Collections.IDictionary] -or
                -not $issue.Contains('File') -or -not $issue.Contains('Line') -or
                -not $issue.Contains('Code') -or -not $issue.Contains('Message') -or
                ($issue['Line'] -isnot [int] -and $issue['Line'] -isnot [long]) -or
                (-not $nativeConvention -and -not ([string]$issue['Code']).StartsWith(
                    'avm.bicep.pester-', [System.StringComparison]::Ordinal))) {
                throw [AvmProcessException]::new('Bicep Pester runner returned an invalid test diagnostic.')
            }
        }
        return $summary
    }
    finally {
        foreach ($path in @($inputPath, $resultPath)) {
            if ($null -ne $path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
                Remove-Item -LiteralPath $path -Force
            }
        }
        if ($null -ne $runDirectory) { Remove-Item -LiteralPath $runDirectory -Force }
    }
}
