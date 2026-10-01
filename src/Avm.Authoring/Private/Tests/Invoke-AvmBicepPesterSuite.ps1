function Invoke-AvmBicepPesterSuite {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)]
        [string[]] $Files,

        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [ValidateSet('Unit', 'E2e')]
        [string] $Mode = 'Unit',

        [string[]] $ModulePaths = @(),

        [string] $RepositoryRoot = '',

        [AllowEmptyCollection()]
        [string[]] $Tag = @(),

        [AllowEmptyCollection()]
        [string[]] $TestName = @(),

        [System.Collections.IDictionary] $TestInputData,

        [hashtable] $EnvVars = @{ GITHUB_ACTIONS = $null; GITHUB_STEP_SUMMARY = $null },

        [int] $TimeoutSec = 0
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $runnerPath = Join-Path -Path $PSScriptRoot -ChildPath '..' `
        -AdditionalChildPath '..', 'Resources', 'bicep', 'Invoke-AvmPesterSuite.ps1'
    $runDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) `
        -ChildPath ('avm-pester-{0}' -f [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $runDirectory -ErrorAction Stop
    $inputPath = Join-Path $runDirectory 'input.json'
    $resultPath = Join-Path $runDirectory 'result.json'
    try {
        $inputData = [pscustomobject]@{
            Mode           = $Mode
            Files          = $Files
            ModulePaths    = $ModulePaths
            RepositoryRoot = $RepositoryRoot
            Tag            = $Tag
            TestName       = $TestName
            TestInputData  = $TestInputData
        }
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
            if ($issue -isnot [System.Collections.IDictionary] -or
                -not $issue.Contains('File') -or -not $issue.Contains('Line') -or
                -not $issue.Contains('Code') -or -not $issue.Contains('Message') -or
                ($issue['Line'] -isnot [int] -and $issue['Line'] -isnot [long]) -or
                -not ([string]$issue['Code']).StartsWith(
                    'avm.bicep.pester-', [System.StringComparison]::Ordinal)) {
                throw [AvmProcessException]::new('Bicep Pester runner returned an invalid test diagnostic.')
            }
        }
        return $summary
    }
    finally {
        foreach ($path in @($inputPath, $resultPath)) {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Remove-Item -LiteralPath $path -Force
            }
        }
        Remove-Item -LiteralPath $runDirectory -Force
    }
}
