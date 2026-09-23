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

Describe 'Get-AvmComponentShardCount' {
    BeforeEach {
        $script:previousShardCount = $env:AVM_COMPONENT_SHARD_COUNT
    }

    AfterEach {
        if ($null -eq $script:previousShardCount) {
            Remove-Item Env:AVM_COMPONENT_SHARD_COUNT -ErrorAction SilentlyContinue
        }
        else {
            $env:AVM_COMPONENT_SHARD_COUNT = $script:previousShardCount
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

    It 'uses a positive default capped at six' {
        Remove-Item Env:AVM_COMPONENT_SHARD_COUNT -ErrorAction SilentlyContinue

        $count = Get-AvmComponentShardCount

        $count | Should -BeGreaterOrEqual 1
        $count | Should -BeLessOrEqual 6
    }

    It 'honours AVM_COMPONENT_SHARD_COUNT' {
        $env:AVM_COMPONENT_SHARD_COUNT = '3'

        Get-AvmComponentShardCount | Should -Be 3
    }
}
