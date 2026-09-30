function Invoke-AvmBicepTestUnit {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context,

        [switch] $AllowPathFallback,

        [AllowEmptyCollection()]
        [string[]] $Tag = @(),

        [AllowEmptyCollection()]
        [string[]] $TestName = @(),

        [switch] $Recurse,

        [string] $CompliancePath,

        [string] $RepositoryRoot
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Context.Ecosystem -ne 'bicep') {
        throw [System.ArgumentException]::new('Bicep unit tests require a Bicep module context.')
    }

    $scopes = @(Get-AvmBicepTestScope -Context $Context -Recurse:$Recurse)
    $modulePaths = [string[]]@($scopes | ForEach-Object { $_.Path })
    $files = [System.Collections.Generic.List[string]]::new()
    foreach ($scope in $scopes) {
        $tests = @(Get-ChildItem -LiteralPath $scope.Path -Directory -Force |
                Where-Object { $_.Name -ieq 'tests' })
        if ($tests.Count -eq 0) {
            continue
        }
        if ($tests.Count -ne 1 -or $tests[0].Name -cne 'tests' -or
            ($tests[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw [AvmConfigurationException]::new(
                "Expected a regular tests directory with exact casing in '$($scope.Path)'.")
        }
        $units = @(Get-ChildItem -LiteralPath $tests[0].FullName -Directory -Force |
                Where-Object { $_.Name -ieq 'unit' })
        if ($units.Count -eq 0) {
            continue
        }
        if ($units.Count -ne 1 -or $units[0].Name -cne 'unit' -or
            ($units[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw [AvmConfigurationException]::new(
                "Expected a regular tests/unit directory with exact casing in '$($scope.Path)'.")
        }
        $unitDirectory = $units[0].FullName
        foreach ($file in @(Get-ChildItem -LiteralPath $unitDirectory -Recurse -File -ErrorAction Stop |
                    Where-Object { $_.Name -match '(?i)\.tests\.ps1$' } |
                    Sort-Object -Property FullName -CaseSensitive)) {
            $files.Add($file.FullName)
        }
    }
    $unitFileCount = $files.Count

    $repoRoot = Get-AvmBicepTestRepositoryRoot -Context $Context -RepositoryRoot $RepositoryRoot
    $defaultSuite = Join-Path -Path $repoRoot -ChildPath 'utilities' `
        -AdditionalChildPath 'pipelines', 'staticValidation', 'compliance', 'module.tests.ps1'
    $suite = if (-not [string]::IsNullOrWhiteSpace($CompliancePath)) {
        $resolvedSuite = if ([System.IO.Path]::IsPathRooted($CompliancePath)) {
            $CompliancePath
        }
        else {
            Join-Path $repoRoot $CompliancePath
        }
        if (-not (Test-Path -LiteralPath $resolvedSuite -PathType Leaf)) {
            throw [AvmConfigurationException]::new("Bicep compliance suite not found: $resolvedSuite")
        }
        $item = Get-Item -LiteralPath $resolvedSuite -ErrorAction Stop
        $item.FullName
    }
    elseif (Test-Path -LiteralPath $defaultSuite -PathType Leaf) {
        $defaultSuite
    }
    else {
        $null
    }
    if ($Context.Kind -eq 'bicep-monorepo' -and $null -eq $suite -and $scopes.Count -gt 0) {
        throw [AvmConfigurationException]::new(
            "Bicep monorepo compliance suite not found at '$defaultSuite'. Pass -CompliancePath to select a suite.")
    }
    if ($null -ne $suite -and $scopes.Count -gt 0) {
        $files.Insert(0, $suite)
    }

    if ($files.Count -eq 0) {
        Write-AvmLog 'no Bicep unit or compliance tests found' -Level Warning
        return [pscustomobject][ordered]@{
            Engine           = 'bicep'
            Tool             = 'Pester'
            ToolPath         = $null
            ToolSource       = 'PowerShell'
            Status           = 'skipped'
            FilesProcessed   = 0
            UnitFiles        = 0
            ComplianceFile   = $null
            ModuleScopes     = $scopes.Count
            RunsTotal        = 0
            RunsPassed       = 0
            RunsFailed       = 0
            RunsSkipped      = 0
            RunsInconclusive = 0
            RunsFiltered     = 0
            Issues           = @()
        }
    }

    $envVars = @{ GITHUB_ACTIONS = $null; GITHUB_STEP_SUMMARY = $null }
    if ($null -ne $suite) {
        $bicep = Resolve-AvmTool -Name 'bicep' -AllowPathFallback:$AllowPathFallback
        $envVars['PATH'] = [System.IO.Path]::GetDirectoryName($bicep.Path) + [System.IO.Path]::PathSeparator + $env:PATH
    }

    $runnerPath = Join-Path -Path $PSScriptRoot -ChildPath '..' `
        -AdditionalChildPath '..', 'Resources', 'bicep', 'Invoke-AvmPesterSuite.ps1'
    $runDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) `
        -ChildPath ('avm-pester-{0}' -f [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $runDirectory -ErrorAction Stop
    $inputPath = Join-Path $runDirectory 'input.json'
    $resultPath = Join-Path $runDirectory 'result.json'
    try {
        $inputData = [pscustomobject]@{
            Files          = $files.ToArray()
            ModulePaths    = $modulePaths
            RepositoryRoot = $repoRoot
            Tag            = $Tag
            TestName       = $TestName
        }
        [System.IO.File]::WriteAllText(
            $inputPath, ($inputData | ConvertTo-Json -Depth 5 -Compress),
            [System.Text.UTF8Encoding]::new($false))

        $pwshPath = [System.Environment]::ProcessPath
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            $pwshPath = (Get-Command -Name 'pwsh' -CommandType Application -ErrorAction Stop).Source
        }
        $processResult = Invoke-AvmProcess -FilePath $pwshPath `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $runnerPath, '-InputPath', $inputPath, '-ResultPath', $resultPath) `
            -WorkingDirectory $repoRoot -EnvVars $envVars -IgnoreExitCode
        if ($processResult.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            $detail = Add-AvmProcessFailureDetail `
                -Message "Bicep Pester runner failed (exit $($processResult.ExitCode))." `
                -StdOut $processResult.StdOut -StdErr $processResult.StdErr
            throw [AvmProcessException]::new($detail)
        }
        $summary = Get-Content -LiteralPath $resultPath -Raw -Encoding utf8 |
            ConvertFrom-Json -AsHashtable -ErrorAction Stop
        foreach ($key in @('Version', 'Total', 'Passed', 'Failed', 'Skipped', 'Inconclusive', 'Filtered', 'Issues')) {
            if (-not $summary.Contains($key)) {
                throw [AvmProcessException]::new("Bicep Pester runner returned a summary without '$key'.")
            }
        }
    }
    finally {
        foreach ($path in @($inputPath, $resultPath)) {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Remove-Item -LiteralPath $path -Force
            }
        }
        Remove-Item -LiteralPath $runDirectory -Force
    }

    $issues = @($summary.Issues | ForEach-Object { [pscustomobject]$_ })
    $executed = [int]$summary.Passed + [int]$summary.Failed + [int]$summary.Skipped + [int]$summary.Inconclusive
    $status = if ($issues.Count -gt 0 -or [int]$summary.Failed -gt 0 -or
        [int]$summary.Skipped -gt 0 -or [int]$summary.Inconclusive -gt 0) {
        'fail'
    }
    elseif ($executed -eq 0) {
        Write-AvmLog 'no Bicep Pester tests matched the selection' -Level Warning
        'skipped'
    }
    else {
        'pass'
    }

    return [pscustomobject][ordered]@{
        Engine           = 'bicep'
        Tool             = "Pester/$($summary.Version)"
        ToolPath         = $null
        ToolSource       = 'PowerShell'
        Status           = $status
        FilesProcessed   = $files.Count
        UnitFiles        = $unitFileCount
        ComplianceFile   = if ($null -ne $suite -and $scopes.Count -gt 0) { $suite } else { $null }
        ModuleScopes     = $scopes.Count
        RunsTotal        = $executed
        RunsPassed       = [int]$summary.Passed
        RunsFailed       = [int]$summary.Failed
        RunsSkipped      = [int]$summary.Skipped
        RunsInconclusive = [int]$summary.Inconclusive
        RunsFiltered     = [int]$summary.Filtered
        Issues           = $issues
    }
}
