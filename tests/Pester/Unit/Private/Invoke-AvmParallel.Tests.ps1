#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmParallel' {
    BeforeEach {
        $script:savedEnvironment = @{}
        foreach ($name in @('GITHUB_ACTIONS', 'GH_TOKEN', 'GITHUB_REPOSITORY', 'AVM_GITHUB_CHECK_RUN_ID', 'GITHUB_STEP_SUMMARY', 'GITHUB_WORKSPACE', 'NO_COLOR')) {
            $script:savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, [NullString]::Value, 'Process')
        }
        $env:NO_COLOR = '1'
    }

    AfterEach {
        foreach ($name in $script:savedEnvironment.Keys) {
            $value = $script:savedEnvironment[$name]
            [Environment]::SetEnvironmentVariable($name,
                $(if ($null -eq $value) { [NullString]::Value } else { $value }), 'Process')
        }
    }

    It 'reports every worker diagnostic once in commands and the summary' {
        $env:GITHUB_ACTIONS = 'true'
        $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive 'parallel-summary.md'
        $env:GITHUB_WORKSPACE = Join-Path $TestDrive 'workspace'
        $workerRoot = Join-Path $env:GITHUB_WORKSPACE 'avm' 'res' 'sample'
        $null = New-Item -ItemType Directory -Path $workerRoot -Force
        foreach ($worker in 1..2) {
            $null = New-Item -ItemType File -Path (Join-Path $workerRoot "worker-$worker.bicep")
        }
        InModuleScope 'Avm.Authoring' -Parameters @{ WorkerRoot = $workerRoot } {
            param($WorkerRoot)
            $stream = @(Invoke-AvmParallel -InputObject @(1, 2) -ThrottleLimit 2 -Argument $WorkerRoot -ScriptBlock {
                    param($Item, $Root)
                    Set-Location -LiteralPath $Root
                    & (Get-Module Avm.Authoring) {
                        param($Worker)
                        Write-AvmLog "info-$Worker"
                        foreach ($index in 1..12) {
                            foreach ($level in @('Warning', 'Error')) {
                                Write-AvmLog "[code-$Worker] diagnostic $index %0A" -Level $level `
                                    -File "worker-$Worker.bicep" -Line $index -Column 2
                            }
                        }
                    } $Item
                    $Item
                } 6>&1)
            $messages = @($stream | Where-Object { $_ -is [Management.Automation.InformationRecord] } |
                    ForEach-Object { [string]$_.MessageData })
            @($stream | Where-Object { $_ -isnot [Management.Automation.InformationRecord] }) | Should -Be @(1, 2)
            @($messages | Where-Object { $_ -like 'info-*' }) | Should -Be @('info-1', 'info-2')
            @($messages | Where-Object { $_ -like '::warning*' }) | Should -HaveCount 24
            @($messages | Where-Object { $_ -like '::error*' }) | Should -HaveCount 24
            $messages | Should -Contain '::warning file=avm/res/sample/worker-1.bicep,line=11,col=2::[code-1] diagnostic 11 %250A (avm/res/sample/worker-1.bicep, line 11, column 2)'
        }
        @(Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY) | Should -HaveCount 48
    }

    It 'retains all worker diagnostics when an earlier worker fails' {
        $env:GITHUB_ACTIONS = 'true'
        $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive 'parallel-failure-summary.md'
        InModuleScope 'Avm.Authoring' {
            $exception = try {
                Invoke-AvmParallel -InputObject @(1, 2) -ThrottleLimit 2 -ScriptBlock {
                    param($Item)
                    & (Get-Module Avm.Authoring) {
                        param($Worker)
                        1..12 | ForEach-Object { Write-AvmLog "worker-$Worker warning-$_" -Level Warning }
                    } $Item
                    if ($Item -eq 1) { throw [InvalidOperationException]::new('worker failed') }
                } 6>$null
                $null
            }
            catch { $_.Exception }
            $exception.GetType().Name | Should -BeExactly 'InvalidOperationException'
            $exception.Message | Should -BeExactly 'worker failed'
        }
        $summary = @(Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY)
        $summary | Should -HaveCount 24
        $summary[-1] | Should -Match 'worker\\-2 warning\\-12'
    }

    It 'inherits the caller diagnostic directory for workers that do not change location' {
        $env:GITHUB_ACTIONS = 'true'
        $env:GITHUB_WORKSPACE = Join-Path $TestDrive 'workspace'
        $root = Join-Path $env:GITHUB_WORKSPACE 'avm' 'res' 'sample'
        $null = New-Item -ItemType Directory -Path $root -Force
        Push-Location -LiteralPath $root
        try {
            InModuleScope 'Avm.Authoring' {
                $messages = @(Invoke-AvmParallel -InputObject @(1, 2) -ThrottleLimit 2 -ScriptBlock {
                        param($Item)
                        & (Get-Module Avm.Authoring) {
                            param($Worker)
                            Write-AvmLog "worker-$Worker" -Level Warning -File 'main.bicep' -Line 2
                        } $Item
                    } 6>&1 | ForEach-Object { [string]$_.MessageData })
                $messages | Should -Be @(
                    '::warning file=avm/res/sample/main.bicep,line=2::worker-1 (avm/res/sample/main.bicep, line 2)'
                    '::warning file=avm/res/sample/main.bicep,line=2::worker-2 (avm/res/sample/main.bicep, line 2)'
                )
            }
        }
        finally { Pop-Location }
    }

    It 'preserves local warning streams and positioned error text without duplicate worker diagnostics' {
        InModuleScope 'Avm.Authoring' {
            $stream = @(Invoke-AvmParallel -InputObject @(1, 2) -ThrottleLimit 2 -ScriptBlock {
                    param($Item)
                    & (Get-Module Avm.Authoring) {
                        param($Worker)
                        Write-AvmLog "[code-$Worker] warning" -Level Warning -File 'main.tf' -Line 4 -Column 2
                        Write-AvmLog "[code-$Worker] error" -Level Error -File 'main.tf' -Line 5
                    } $Item
                } 3>&1 6>&1)
            @($stream | Where-Object { $_ -is [Management.Automation.WarningRecord] } | ForEach-Object { $_.Message }) |
                Should -Be @('[code-1] warning (main.tf, line 4, column 2)', '[code-2] warning (main.tf, line 4, column 2)')
            @($stream | Where-Object { $_ -is [Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData }) |
                Should -Be @('[code-1] error (main.tf, line 5)', '[code-2] error (main.tf, line 5)')
        }
    }

    It 'returns worker output in input order' {
        $result = InModuleScope 'Avm.Authoring' {
            Invoke-AvmParallel `
                -InputObject @(3, 1, 2) `
                -ScriptBlock {
                    param($Item, $Prefix)
                    Start-Sleep -Milliseconds ($Item * 30)
                    '{0}{1}' -f $Prefix, $Item
                } `
                -Argument 'item-' `
                -ThrottleLimit 3
        }

        $result | Should -Be @('item-3', 'item-1', 'item-2')
    }

    It 'imports the module and invokes a private function in each worker' {
        $result = InModuleScope 'Avm.Authoring' {
            Invoke-AvmParallel `
                -InputObject @('first', 'second') `
                -FunctionName 'Format-AvmLogText' `
                -Argument 'Info' `
                -ThrottleLimit 2
        }

        $result | Should -Be @('first', 'second')
    }

    It 'replays worker information in input order' {
        $probe = InModuleScope 'Avm.Authoring' {
            $stream = @(
                Invoke-AvmParallel `
                    -InputObject @(2, 1) `
                    -ScriptBlock {
                        param($Item)
                        Start-Sleep -Milliseconds ($Item * 30)
                        Write-Information "info-$Item" -InformationAction Continue
                        $Item
                    } `
                    -ThrottleLimit 2 6>&1
            )
            [pscustomobject]@{
                Information = @(
                    $stream |
                        Where-Object { $_ -is [System.Management.Automation.InformationRecord] } |
                        ForEach-Object { [string]$_.MessageData }
                )
                Output      = @(
                    $stream |
                        Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] }
                )
            }
        } 6>$null

        $probe.Information | Should -Be @('info-2', 'info-1')
        $probe.Output | Should -Be @(2, 1)
    }

    It 'propagates a worker failure after all workers finish' {
        $exception = InModuleScope 'Avm.Authoring' {
            try {
                Invoke-AvmParallel `
                    -InputObject @(1, 2, 3) `
                    -ScriptBlock {
                        param($Item)
                        if ($Item -eq 2) {
                            throw [System.InvalidOperationException]::new('worker 2 failed')
                        }
                        $Item
                    } `
                    -ThrottleLimit 3
            }
            catch {
                $_.Exception
            }
        }

        $exception | Should -Not -BeNullOrEmpty
        $exception.GetType().Name | Should -Be 'InvalidOperationException'
        $exception.Message | Should -Match 'worker 2 failed'
    }
}
