#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    $script:moduleManifest = Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
    Import-Module -Name $script:moduleManifest -Force
}

AfterAll {
    Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
}

Describe 'Component: bounded parallel execution' -Tag 'Component' {
    It 'overlaps workers up to the requested throttle' {
        $barrier = [System.Threading.Barrier]::new(4)
        try {
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ Barrier = $barrier } {
                param($Barrier)
                Invoke-AvmParallel `
                    -InputObject @(1, 2, 3, 4) `
                    -ScriptBlock {
                        param($Item, $SharedBarrier)
                        if (-not $SharedBarrier.SignalAndWait([timespan]::FromSeconds(15))) {
                            throw [System.TimeoutException]::new('Workers did not overlap.')
                        }
                        $Item
                    } `
                    -Argument $Barrier `
                    -ThrottleLimit 4
            }
        }
        finally {
            $barrier.Dispose()
        }

        $result | Should -Be @(1, 2, 3, 4)
    }
}
