#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $script:helperPath = Join-Path $script:repoRoot 'build' 'AvmPesterSharding.ps1'
    . $script:helperPath

    function script:New-TestFile {
        param(
            [Parameter(Mandatory)] [string] $Name,
            [Parameter(Mandatory)] [int] $Length
        )

        $path = Join-Path $TestDrive $Name
        [System.IO.File]::WriteAllText($path, ('x' * $Length))
        Get-Item -LiteralPath $path
    }
}

Describe 'New-AvmPesterShardPlan' {
    It 'partitions files deterministically by descending weight' {
        $files = @(
            script:New-TestFile -Name 'A.Tests.ps1' -Length 10
            script:New-TestFile -Name 'B.Tests.ps1' -Length 10
            script:New-TestFile -Name 'C.Tests.ps1' -Length 10
            script:New-TestFile -Name 'D.Tests.ps1' -Length 10
        )
        $weights = @{
            'A.Tests.ps1' = 10.0
            'B.Tests.ps1' = 9.0
            'C.Tests.ps1' = 8.0
            'D.Tests.ps1' = 1.0
        }

        $plan = New-AvmPesterShardPlan -File $files -ShardCount 2 -Weight $weights

        $plan.Count | Should -Be 2
        @($plan[0].Paths | ForEach-Object { Split-Path -Leaf $_ }) | Should -Be @('A.Tests.ps1', 'D.Tests.ps1')
        @($plan[1].Paths | ForEach-Object { Split-Path -Leaf $_ }) | Should -Be @('B.Tests.ps1', 'C.Tests.ps1')
    }

    It 'assigns every file exactly once' {
        $files = @(
            script:New-TestFile -Name 'One.Tests.ps1' -Length 100
            script:New-TestFile -Name 'Two.Tests.ps1' -Length 200
            script:New-TestFile -Name 'Three.Tests.ps1' -Length 300
            script:New-TestFile -Name 'Four.Tests.ps1' -Length 400
            script:New-TestFile -Name 'Five.Tests.ps1' -Length 500
        )

        $plan = New-AvmPesterShardPlan -File $files -ShardCount 3
        $assigned = @($plan | ForEach-Object { $_.Paths } | ForEach-Object { Split-Path -Leaf $_ })

        $assigned.Count | Should -Be $files.Count
        @($assigned | Sort-Object) | Should -Be @($files.Name | Sort-Object)
        @($assigned | Group-Object | Where-Object { $_.Count -ne 1 }) | Should -BeNullOrEmpty
    }

    It 'does not return empty shards' {
        $files = @(
            script:New-TestFile -Name 'First.Tests.ps1' -Length 100
            script:New-TestFile -Name 'Second.Tests.ps1' -Length 200
        )

        $plan = New-AvmPesterShardPlan -File $files -ShardCount 5

        $plan.Count | Should -Be 2
        foreach ($shard in $plan) {
            $shard.Paths.Count | Should -BeGreaterThan 0
        }
    }
}

Describe 'Get-AvmPesterShardCount' {
    BeforeEach {
        $script:previousShardCount = @{
            unit      = $env:AVM_UNIT_SHARD_COUNT
            component = $env:AVM_COMPONENT_SHARD_COUNT
        }
    }

    AfterEach {
        foreach ($tier in $script:previousShardCount.Keys) {
            [Environment]::SetEnvironmentVariable("AVM_$($tier.ToUpperInvariant())_SHARD_COUNT", $script:previousShardCount[$tier])
        }
    }

    Describe 'Pester log isolation' {
        BeforeEach {
            $script:previousActions = $env:GITHUB_ACTIONS
        }

        AfterEach {
            $env:GITHUB_ACTIONS = $script:previousActions
        }

        It 'emits paired workflow-command delimiters when Actions is active' {
            $env:GITHUB_ACTIONS = 'true'

            $started = @(Start-AvmPesterLogIsolation 6>&1)
            $token = [string]$started[-1]
            $stopped = @(Stop-AvmPesterLogIsolation -Token $token 6>&1)

            $token | Should -Match '^[0-9a-f]{32}$'
            @($started | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } |
                    ForEach-Object { [string]$_.MessageData }) | Should -Contain "::stop-commands::$token"
            @($stopped | ForEach-Object { [string]$_.MessageData }) | Should -Contain "::$token::"
        }

        It 'emits no workflow commands outside Actions' {
            $env:GITHUB_ACTIONS = ''

            @(Start-AvmPesterLogIsolation 6>&1).Count | Should -Be 0
            @(Stop-AvmPesterLogIsolation -Token $null 6>&1).Count | Should -Be 0
        }
    }

    It 'uses a positive default capped at six for <_>' -ForEach @('unit', 'component') {
        Remove-Item "Env:AVM_$($_.ToUpperInvariant())_SHARD_COUNT" -ErrorAction SilentlyContinue

        $count = Get-AvmPesterShardCount -Tier $_

        $count | Should -BeGreaterOrEqual 1
        $count | Should -BeLessOrEqual 6
    }

    It 'honours the tier-specific shard count variable' {
        $env:AVM_COMPONENT_SHARD_COUNT = '3'
        $env:AVM_UNIT_SHARD_COUNT = '1'

        Get-AvmPesterShardCount -Tier 'component' | Should -Be 3
        Get-AvmPesterShardCount -Tier 'unit' | Should -Be 1
    }

    It 'rejects a shard count below one' {
        $env:AVM_UNIT_SHARD_COUNT = '0'

        { Get-AvmPesterShardCount -Tier 'unit' } | Should -Throw '*AVM_UNIT_SHARD_COUNT*'
    }
}
Describe 'Clear-AvmTierTestResult' {
    It 'removes single-process and shard results for the tier only' {
        $script:outRoot = Join-Path $TestDrive 'out'
        $dir = Join-Path $script:outRoot 'test-results'
        $null = New-Item -ItemType Directory -Path $dir -Force
        foreach ($name in 'unit.xml', 'unit-shard1.xml', 'unit-shard2.xml', 'workflow-unit.xml', 'component-shard1.xml') {
            [IO.File]::WriteAllText((Join-Path $dir $name), '<x/>')
        }

        Clear-AvmTierTestResult -Tier 'unit'

        @(Get-ChildItem -LiteralPath $dir -File | ForEach-Object Name | Sort-Object) |
            Should -Be @('component-shard1.xml', 'workflow-unit.xml')
    }
}

Describe 'Invoke-AvmPesterShardedTier' {
    BeforeAll {
        function script:Get-AvmTestResultPath {
            param([Parameter(Mandatory)] [string] $Tier)
            $dir = Join-Path $script:outRoot 'test-results'
            $null = New-Item -ItemType Directory -Path $dir -Force
            Join-Path $dir "$Tier.xml"
        }
        function script:Write-Build {
            param($Color, $Text)
            $script:buildMessages.Add([string]$Text)
        }
    }

    BeforeEach {
        $script:outRoot = Join-Path $TestDrive 'out'
        $script:buildMessages = [System.Collections.Generic.List[string]]::new()
    }

    It 'warns when a unit shard writes to its isolated AVM_HOME' {
        $probe = Join-Path $TestDrive 'Writes.Tests.ps1'
        [IO.File]::WriteAllText($probe, @'
Describe 'writes state' {
    It 'writes to AVM_HOME' {
        $null = New-Item -ItemType Directory -Path $env:AVM_HOME -Force
        [IO.File]::WriteAllText((Join-Path $env:AVM_HOME 'state.json'), '{}')
    }
}
'@)

        $result = Invoke-AvmPesterShardedTier -Tier 'unit' -File @(Get-Item -LiteralPath $probe) -ShardCount 1 6>$null

        $result.PassedCount | Should -Be 1
        @($script:buildMessages | Where-Object { $_ -like '*unit shard 1 wrote 1 file(s) to its isolated AVM_HOME*' }).Count |
            Should -Be 1
    }

    It 'does not warn when a unit shard leaves AVM_HOME untouched' {
        $probe = Join-Path $TestDrive 'Clean.Tests.ps1'
        [IO.File]::WriteAllText($probe, "Describe 'clean' { It 'passes' { 1 | Should -Be 1 } }")

        $result = Invoke-AvmPesterShardedTier -Tier 'unit' -File @(Get-Item -LiteralPath $probe) -ShardCount 1 6>$null

        $result.PassedCount | Should -Be 1
        @($script:buildMessages | Where-Object { $_ -like '*isolated AVM_HOME*' }).Count | Should -Be 0
    }
}

Describe 'Invoke-AvmPesterShard' {
    It 'fails a shard on block teardown even when all individual tests pass' {
        $probe = Join-Path $TestDrive 'Teardown.Tests.ps1'
        [IO.File]::WriteAllText($probe, @'
Describe 'broken teardown' {
    AfterAll { throw 'Teardown failed.' }
    It 'passes' { 1 | Should -Be 1 }
}
'@)
        $shard = Join-Path $script:repoRoot 'build' 'Invoke-AvmPesterShard.ps1'
        $output = Join-Path $TestDrive 'teardown.xml'
        $null = & pwsh -NoLogo -NoProfile -NonInteractive -File $shard -Path $probe -OutputPath $output 2>&1
        $LASTEXITCODE | Should -Be 1
        ([xml](Get-Content -LiteralPath $output -Raw)).'test-results'.total | Should -Be 1
    }

    It 'fails a shard when a test file cannot be loaded, even if other tests pass' {
        $passing = Join-Path $TestDrive 'Passing.Tests.ps1'
        $broken = Join-Path $TestDrive 'Broken.Tests.ps1'
        [IO.File]::WriteAllText($passing, "Describe 'ok' { It 'passes' { 1 | Should -Be 1 } }")
        [IO.File]::WriteAllText($broken, 'Describe ''broken'' { It ''never runs'' { "value:$Name:" } }')
        $shard = Join-Path $script:repoRoot 'build' 'Invoke-AvmPesterShard.ps1'
        $output = Join-Path $TestDrive 'shard.xml'
        $null = & pwsh -NoLogo -NoProfile -NonInteractive -File $shard `
            -Path ($passing + [IO.Path]::PathSeparator + $broken) -OutputPath $output 2>&1
        $LASTEXITCODE | Should -Be 1
        ([xml](Get-Content -LiteralPath $output -Raw)).'test-results'.total | Should -Be 1
    }

    It 'applies excluded tags and isolates temp and AVM_HOME per shard' {
        $probe = Join-Path $TestDrive 'Probe.Tests.ps1'
        $record = Join-Path $TestDrive 'probe.txt'
        [IO.File]::WriteAllText($probe, @"
Describe 'probe' {
    It 'runs untagged' {
        [IO.File]::WriteAllLines('$record', @([IO.Path]::GetTempPath(), `$env:AVM_HOME))
    }
    It 'is excluded' -Tag 'Component' { throw 'should not run' }
    It 'is also excluded' -Tag 'Integration' { throw 'should not run' }
}
"@)
        $shard = Join-Path $script:repoRoot 'build' 'Invoke-AvmPesterShard.ps1'
        $output = Join-Path $TestDrive 'isolated.xml'
        $temp = Join-Path $TestDrive 'shard-tmp'
        $avmHome = Join-Path $TestDrive 'shard-home'

        $null = & pwsh -NoLogo -NoProfile -NonInteractive -File $shard -Path $probe -OutputPath $output `
            -ExcludeTag 'Integration,Component' -TempPath $temp -AvmHome $avmHome 2>&1

        $LASTEXITCODE | Should -Be 0
        ([xml](Get-Content -LiteralPath $output -Raw)).'test-results'.total | Should -Be 1
        $seen = [IO.File]::ReadAllLines($record)
        $seen[0].TrimEnd([IO.Path]::DirectorySeparatorChar) | Should -Be $temp
        $seen[1] | Should -Be $avmHome
    }
}

Describe 'Invoke-AvmPester block failures' {
    BeforeAll {
        $buildPath = Join-Path $script:repoRoot 'build' 'avm.build.ps1'
        $ast = [Management.Automation.Language.Parser]::ParseFile($buildPath, [ref]$null, [ref]$null)
        $definition = $ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'script:Invoke-AvmPester'
            }, $false)
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    BeforeEach {
        $script:testNameFilter = @()
        $script:fakeResult = [pscustomobject]@{
            TotalCount = 1; PassedCount = 1; FailedCount = 0
            FailedContainersCount = 0; FailedBlocksCount = 0; FailedBlocks = @()
        }
        Mock Invoke-Pester { $script:fakeResult }
    }

    It 'rejects a failed block even when every individual test passed' {
        $script:fakeResult.FailedBlocksCount = 1
        $script:fakeResult.FailedBlocks = @([pscustomobject]@{ Name = 'broken teardown' })
        { Invoke-AvmPester -Configuration (New-PesterConfiguration) } |
            Should -Throw '*1 Pester setup or teardown block(s) failed: broken teardown*'
    }

    It 'retains the successful result when no block or container failed' {
        $result = Invoke-AvmPester -Configuration (New-PesterConfiguration)
        [object]::ReferenceEquals($result, $script:fakeResult) | Should -BeTrue
    }
}