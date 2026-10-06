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

        [switch] $IncludeCompliance,

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
    $includeSuite = $IncludeCompliance -or -not [string]::IsNullOrWhiteSpace($CompliancePath)
    $suite = $null
    $packaged = $null
    if ($IncludeCompliance -and [string]::IsNullOrWhiteSpace($CompliancePath)) {
        $packaged = Invoke-AvmBicepPackagedCompliance -Context $Context -Recurse:$Recurse `
            -AllowPathFallback:$AllowPathFallback -Tag $Tag -TestName $TestName
        $suite = $packaged.Suite
    }
    elseif ($includeSuite) {
        $resolvedSuite = if ([System.IO.Path]::IsPathRooted($CompliancePath)) {
            $CompliancePath
        }
        else {
            Join-Path $repoRoot $CompliancePath
        }
        if (-not (Test-Path -LiteralPath $resolvedSuite -PathType Leaf)) {
            throw [AvmConfigurationException]::new("Bicep compliance suite not found: $resolvedSuite")
        }
        $suite = (Get-Item -LiteralPath $resolvedSuite -ErrorAction Stop).FullName
    }
    if ($null -eq $packaged -and $null -ne $suite -and $scopes.Count -gt 0) {
        $files.Insert(0, $suite)
    }

    if ($files.Count -eq 0 -and $null -eq $packaged) {
        $message = if ($includeSuite) {
            'no Bicep unit or compliance tests found'
        }
        else {
            'no Bicep unit tests found'
        }
        Write-AvmLog $message -Level Warning
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
    if ($null -ne $suite -and $files.Count -gt 0) {
        $bicep = Resolve-AvmTool -Name 'bicep' -AllowPathFallback:$AllowPathFallback
        $envVars['PATH'] = [System.IO.Path]::GetDirectoryName($bicep.Path) + [System.IO.Path]::PathSeparator + $env:PATH
    }

    $summary = @{
        Version = 'not-run'; Total = 0; Passed = 0; Failed = 0
        Skipped = 0; Inconclusive = 0; Filtered = 0; Issues = @()
    }
    if ($files.Count -gt 0) {
        $summary = Invoke-AvmBicepPesterSuite -Files $files.ToArray() `
            -ModulePaths $modulePaths -RepositoryRoot $repoRoot `
            -Tag $Tag -TestName $TestName -WorkingDirectory $repoRoot -EnvVars $envVars
    }

    $issues = @($summary.Issues | ForEach-Object { [pscustomobject]$_ })
    $unitFailures = [int]$summary.Failed
    if ($null -ne $packaged) {
        $issues += @($packaged.Issues)
        if ($null -ne $packaged.Summary) {
            if ($files.Count -eq 0) { $summary.Version = $packaged.Summary.Version }
            foreach ($count in @('Total', 'Passed', 'Failed', 'Skipped', 'Inconclusive', 'Filtered')) {
                $summary[$count] += $packaged.Summary[$count]
            }
        }
    }
    $executed = [int]$summary.Passed + [int]$summary.Failed + [int]$summary.Skipped + [int]$summary.Inconclusive
    $status = if (@($issues | Where-Object { $_.Severity -eq 'error' }).Count -gt 0 -or $unitFailures -gt 0 -or
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
        FilesProcessed   = $files.Count + $(if ($null -ne $packaged) { 1 } else { 0 })
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
