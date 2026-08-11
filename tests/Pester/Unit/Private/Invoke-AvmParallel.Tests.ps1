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
