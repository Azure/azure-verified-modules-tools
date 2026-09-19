#Requires -Version 7.4

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

function script:Get-AvmComponentShardCount {
    $default = [Math]::Min([Environment]::ProcessorCount, 6)
    if ($default -lt 1) {
        $default = 1
    }

    if ([string]::IsNullOrWhiteSpace($env:AVM_COMPONENT_SHARD_COUNT)) {
        return $default
    }

    $configured = 0
    if (-not [int]::TryParse($env:AVM_COMPONENT_SHARD_COUNT, [ref] $configured)) {
        throw "AVM_COMPONENT_SHARD_COUNT must be an integer greater than or equal to 1; got '$env:AVM_COMPONENT_SHARD_COUNT'."
    }
    if ($configured -lt 1) {
        throw "AVM_COMPONENT_SHARD_COUNT must be greater than or equal to 1; got '$env:AVM_COMPONENT_SHARD_COUNT'."
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

function script:Invoke-AvmPesterShardedTier {
    param(
        [Parameter(Mandatory)] [string] $Tier,
        [Parameter(Mandatory)] [System.IO.FileInfo[]] $File,
        [Parameter(Mandatory)] [int] $ShardCount
    )

    $weights = script:Get-AvmPesterFileWeight -Tier $Tier
    $plan = script:New-AvmPesterShardPlan -File $File -ShardCount $ShardCount -Weight $weights

    $resultDir = Split-Path -Parent (script:Get-AvmTestResultPath -Tier $Tier)
    foreach ($stale in @(Get-ChildItem -LiteralPath $resultDir -Filter "$Tier*.xml" -File -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $stale.FullName -Force
    }

    $shardScript = Join-Path $PSScriptRoot 'Invoke-AvmPesterShard.ps1'
    $logDir = Join-Path $script:outRoot 'test-logs'
    if (-not (Test-Path -LiteralPath $logDir)) {
        $null = New-Item -ItemType Directory -Path $logDir -Force
    }

    Write-Build Gray "  $Tier : $($File.Count) file(s) across $($plan.Count) shard(s)"

    $running = @()
    $pwshPath = script:Resolve-AvmPowerShellPath
    for ($i = 0; $i -lt $plan.Count; $i++) {
        $index = $i + 1
        $outputPath = Join-Path $resultDir ("{0}-shard{1}.xml" -f $Tier, $index)
        $logPath = Join-Path $logDir ("{0}-shard{1}.log" -f $Tier, $index)
        $arguments = @(
            '-NoProfile', '-NonInteractive', '-File', $shardScript,
            '-OutputPath', $outputPath,
            '-Tag', $script:tierTag[$Tier],
            '-Path', ($plan[$i].Paths -join [System.IO.Path]::PathSeparator)
        )
        $process = Microsoft.PowerShell.Management\Start-Process -FilePath $pwshPath `
            -ArgumentList $arguments -NoNewWindow -PassThru `
            -RedirectStandardOutput $logPath -RedirectStandardError "$logPath.err"
        $running += [pscustomobject]@{
            Index = $index; Process = $process; Log = $logPath; Output = $outputPath
        }
    }

    foreach ($shard in $running) {
        $shard.Process.WaitForExit()
    }

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
        if ($exit -eq 2) {
            throw "$Tier shard $($shard.Index) ran no tests."
        }
        if (-not (Test-Path -LiteralPath $shard.Output)) {
            throw "$Tier shard $($shard.Index) produced no result file (exit $exit)."
        }

        $xml = [xml](Get-Content -LiteralPath $shard.Output -Raw)
        $root = $xml.'test-results'
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

    $aggregate
}

$script:tierTag = @{ component = 'Component'; integration = 'Integration' }
