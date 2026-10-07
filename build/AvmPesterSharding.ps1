#Requires -Version 7.4

function script:Get-AvmIntegrationTestFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [ValidateSet('All', 'Bicep', 'Terraform')] [string] $Group = 'All'
    )

    $files = @(Get-ChildItem -LiteralPath $Path -Filter '*.Tests.ps1' -File -Recurse |
            Where-Object {
                $bicep = $_.Name.StartsWith('Bicep', [StringComparison]::OrdinalIgnoreCase)
                $Group -eq 'All' -or ($Group -eq 'Bicep' -and $bicep) -or ($Group -eq 'Terraform' -and -not $bicep)
            } | Sort-Object -Property FullName)
    if ($files.Count -eq 0) {
        throw "No integration test files found for group '$Group' in '$Path'."
    }
    $files.FullName
}

function script:Resolve-AvmPowerShellPath {
    if ($PSHOME) {
        $fileName = if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' }
        $candidate = Join-Path $PSHOME $fileName
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $processPath = (Get-Process -Id $PID).Path
    if ($processPath) {
        return $processPath
    }

    throw 'Unable to resolve the current PowerShell executable path.'
}

function script:Start-AvmPesterLogIsolation {
    if ([string]::IsNullOrWhiteSpace($env:GITHUB_ACTIONS)) {
        return
    }

    $token = [guid]::NewGuid().ToString('N')
    Microsoft.PowerShell.Utility\Write-Host "::stop-commands::$token"
    return $token
}

function script:Stop-AvmPesterLogIsolation {
    param(
        [string] $Token
    )

    if (-not [string]::IsNullOrWhiteSpace($Token)) {
        Microsoft.PowerShell.Utility\Write-Host "::$Token::"
    }
}

function script:Get-AvmPesterShardCount {
    param(
        [Parameter(Mandatory)] [ValidateSet('unit', 'component')] [string] $Tier
    )

    $variable = "AVM_$($Tier.ToUpperInvariant())_SHARD_COUNT"
    $value = [Environment]::GetEnvironmentVariable($variable)
    $default = [Math]::Min([Environment]::ProcessorCount, 6)
    if ($default -lt 1) {
        $default = 1
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        return $default
    }

    $configured = 0
    if (-not [int]::TryParse($value, [ref] $configured)) {
        throw "$variable must be an integer greater than or equal to 1; got '$value'."
    }
    if ($configured -lt 1) {
        throw "$variable must be greater than or equal to 1; got '$value'."
    }

    $configured
}

function script:Get-AvmPesterFileWeight {
    param(
        [Parameter(Mandatory)] [string] $Tier
    )

    $weights = @{}
    $dir = Join-Path $script:outRoot 'test-results'
    if (-not (Test-Path -LiteralPath $dir)) { return $weights }

    foreach ($file in @(Get-ChildItem -LiteralPath $dir -Filter "$Tier*.xml" -File -ErrorAction SilentlyContinue)) {
        try {
            $xml = [xml](Get-Content -LiteralPath $file.FullName -Raw)
        }
        catch {
            continue
        }

        foreach ($suite in @($xml.SelectNodes("//test-suite[@type='TestFixture']"))) {
            if ([string]::IsNullOrWhiteSpace($suite.name) -or $suite.name -notlike '*.Tests.ps1') { continue }
            $seconds = 0.0
            if (-not [double]::TryParse($suite.time, [ref] $seconds)) { continue }
            $weights[$suite.name] = $seconds
            $weights[(Split-Path -Leaf $suite.name)] = $seconds
        }
    }

    $weights
}

function script:New-AvmPesterShardPlan {
    param(
        [Parameter(Mandatory)] [System.IO.FileInfo[]] $File,
        [Parameter(Mandatory)] [int] $ShardCount,
        [hashtable] $Weight = @{}
    )

    if ($ShardCount -lt 1) {
        throw "ShardCount must be greater than or equal to 1; got $ShardCount."
    }

    $shards = @(1..$ShardCount | ForEach-Object { [pscustomobject]@{ Cost = 0.0; Paths = [System.Collections.Generic.List[string]]::new() } })
    $costed = $File | ForEach-Object {
        $cost = if ($Weight.ContainsKey($_.FullName)) {
            $Weight[$_.FullName]
        }
        elseif ($Weight.ContainsKey($_.Name)) {
            $Weight[$_.Name]
        }
        else {
            $_.Length / 1000.0
        }
        [pscustomobject]@{ Path = $_.FullName; Cost = [double] $cost }
    } | Sort-Object -Property @{ Expression = 'Cost'; Descending = $true }, @{ Expression = 'Path'; Descending = $false }

    foreach ($item in $costed) {
        $target = $shards | Sort-Object -Property @{ Expression = 'Cost'; Descending = $false }, @{ Expression = { $_.Paths.Count }; Descending = $false } | Select-Object -First 1
        $target.Paths.Add($item.Path)
        $target.Cost += $item.Cost
    }

    @($shards | Where-Object { $_.Paths.Count -gt 0 })
}

function script:Clear-AvmTierTestResult {
    # Removes single-process and shard results for a tier, so a run in one mode
    # never leaves results from the other mode to be uploaded or weighted.
    param(
        [Parameter(Mandatory)] [string] $Tier
    )

    $dir = Join-Path $script:outRoot 'test-results'
    foreach ($stale in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq "$Tier.xml" -or $_.Name -like "$Tier-shard*.xml" })) {
        Remove-Item -LiteralPath $stale.FullName -Force
    }
}

function script:Invoke-AvmPesterShardedTier {
    param(
        [Parameter(Mandatory)] [string] $Tier,
        [Parameter(Mandatory)] [System.IO.FileInfo[]] $File,
        [Parameter(Mandatory)] [int] $ShardCount
    )

    $weights = script:Get-AvmPesterFileWeight -Tier $Tier
    $plan = script:New-AvmPesterShardPlan -File $File -ShardCount $ShardCount -Weight $weights

    $resultDir = Split-Path -Parent (script:Get-AvmTestResultPath -Tier $Tier)
    script:Clear-AvmTierTestResult -Tier $Tier

    $shardScript = Join-Path $PSScriptRoot 'Invoke-AvmPesterShard.ps1'
    $logDir = Join-Path $script:outRoot 'test-logs'
    if (-not (Test-Path -LiteralPath $logDir)) {
        $null = New-Item -ItemType Directory -Path $logDir -Force
    }

    Write-Build Gray "  $Tier : $($File.Count) file(s) across $($plan.Count) shard(s)"
    for ($i = 0; $i -lt $plan.Count; $i++) {
        $files = @($plan[$i].Paths | ForEach-Object {
                [System.IO.Path]::GetRelativePath($script:repoRoot, $_)
            })
        Write-Build Gray (
            "  $Tier shard $($i + 1): estimated cost $([math]::Round($plan[$i].Cost, 2)); " +
            "$($files.Count) file(s): $($files -join ', ')"
        )
    }

    # Isolated shard folders sit outside the repository so git commands run in
    # TestDrive never discover this checkout. Names stay short, and component
    # shards keep the shared temp folder, because some component tests create
    # git paths close to the Windows 260-character limit.
    $filter = $script:tierFilter[$Tier]
    $isolate = $filter.ContainsKey('Isolate') -and $filter.Isolate
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('avm' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $running = @()
    $pwshPath = script:Resolve-AvmPowerShellPath
    try {
        for ($i = 0; $i -lt $plan.Count; $i++) {
            $index = $i + 1
            $outputPath = Join-Path $resultDir ("{0}-shard{1}.xml" -f $Tier, $index)
            $logPath = Join-Path $logDir ("{0}-shard{1}.log" -f $Tier, $index)
            $shardTemp = Join-Path $tempRoot "$index"
            $shardAvmHome = Join-Path $shardTemp 'h'
            $arguments = @(
                '-NoProfile', '-NonInteractive', '-File', $shardScript,
                '-OutputPath', $outputPath,
                '-Path', ($plan[$i].Paths -join [System.IO.Path]::PathSeparator)
            )
            if ($filter.ContainsKey('Tag')) {
                $arguments += @('-Tag', $filter.Tag)
            }
            if ($filter.ContainsKey('ExcludeTag')) {
                $arguments += @('-ExcludeTag', ($filter.ExcludeTag -join ','))
            }
            if ($isolate) {
                $arguments += @('-TempPath', (Join-Path $shardTemp 't'), '-AvmHome', $shardAvmHome)
            }
            $process = Microsoft.PowerShell.Management\Start-Process -FilePath $pwshPath `
                -ArgumentList $arguments -NoNewWindow -PassThru `
                -RedirectStandardOutput $logPath -RedirectStandardError "$logPath.err"
            $running += [pscustomobject]@{
                Index = $index; Process = $process; Log = $logPath; Output = $outputPath
                AvmHome = $shardAvmHome; Files = @($plan[$i].Paths)
            }
        }

        foreach ($shard in $running) {
            $shard.Process.WaitForExit()
        }

        $logToken = script:Start-AvmPesterLogIsolation
        try {
            $aggregate = [pscustomobject]@{ TotalCount = 0; PassedCount = 0; FailedCount = 0; SkippedCount = 0 }
            foreach ($shard in $running) {
                $exit = $shard.Process.ExitCode
                if (Test-Path -LiteralPath $shard.Log) {
                    Get-Content -LiteralPath $shard.Log | Write-Host
                }
                $errLog = "$($shard.Log).err"
                if ((Test-Path -LiteralPath $errLog) -and (Get-Item -LiteralPath $errLog).Length -gt 0) {
                    Get-Content -LiteralPath $errLog | Write-Host
                }
                if ($isolate) {
                    $leaked = @(Get-ChildItem -LiteralPath $shard.AvmHome -Recurse -File -ErrorAction SilentlyContinue)
                    if ($leaked.Count -gt 0) {
                        Write-Build Yellow "  $Tier shard $($shard.Index) wrote $($leaked.Count) file(s) to its isolated AVM_HOME."
                    }
                }
                if ($exit -eq 2) {
                    throw "$Tier shard $($shard.Index) ran no tests."
                }
                if (-not (Test-Path -LiteralPath $shard.Output)) {
                    throw "$Tier shard $($shard.Index) produced no result file (exit $exit)."
                }

                $xml = [xml](Get-Content -LiteralPath $shard.Output -Raw)
                $root = $xml.'test-results'
                $durationSeconds = [System.Xml.XmlConvert]::ToDouble([string] $root.'test-suite'.time)
                Write-Build Gray (
                    "  $Tier shard $($shard.Index): $([math]::Round($durationSeconds, 2))s; " +
                    "$($shard.Files.Count) file(s); exit $exit"
                )
                $total = [int] $root.total
                $failures = [int] $root.failures + [int] $root.errors
                $skipped = [int] $root.skipped + [int] $root.'not-run' + [int] $root.ignored
                $aggregate.TotalCount += $total
                $aggregate.FailedCount += $failures
                $aggregate.SkippedCount += $skipped
                $aggregate.PassedCount += $total - $failures - $skipped
                if ($exit -ne 0 -and $failures -eq 0) {
                    throw "$Tier shard $($shard.Index) exited with code $exit."
                }
            }
        }
        finally {
            script:Stop-AvmPesterLogIsolation -Token $logToken
        }
    }
    finally {
        foreach ($shard in $running) {
            if (-not $shard.Process.HasExited) {
                $shard.Process.Kill($true)
                $shard.Process.WaitForExit()
            }
        }
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    $aggregate
}

$script:tierFilter = @{
    unit        = @{ ExcludeTag = @('Integration', 'Component'); Isolate = $true }
    component   = @{ Tag = 'Component' }
    integration = @{ Tag = 'Integration' }
}
