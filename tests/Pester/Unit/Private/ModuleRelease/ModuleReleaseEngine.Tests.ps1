#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeDiscovery {
    . (Join-Path $PSScriptRoot '..' '..' '..' 'Helpers' 'ModuleReleaseScenario.ps1')
    $engineCases = @(
        foreach ($scenario in (Get-ModuleReleaseCatalogue -Name 'engine').Scenarios) {
            @{ Id = $scenario.Id; Title = $scenario.Title; Scenario = $scenario }
        }
    )
}

Describe 'Release decision engine' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' '..' '..' 'Helpers' 'ModuleReleaseScenario.ps1')
        Import-Module -Name (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    }

    AfterAll {
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

    It '<Id>: <Title>' -ForEach $engineCases {
        $stateJson = if ($Scenario.ContainsKey('StateJson')) { $Scenario['StateJson'] } else { $null }
        $initialize = if ($Scenario.ContainsKey('Initialize')) { $Scenario['Initialize'] } else { $null -eq $stateJson }
        $overrides = [ordered]@{}
        Merge-ModuleReleaseFacts -Target $overrides -Overrides $Scenario['Facts']
        $merges = @()
        $labelEvents = @()
        $comments = @()
        $failures = [System.Collections.Generic.List[string]]::new()

        $stepNumber = 0
        foreach ($step in $Scenario['Steps']) {
            $stepNumber++
            $stepStateJson = $stateJson
            $stepInitialize = $initialize
            if ($step.ContainsKey('StateJson')) {
                $stepStateJson = $step['StateJson']
                $stepInitialize = $false
            }
            if ($step.ContainsKey('Initialize')) {
                $stepInitialize = $step['Initialize']
            }
            $stepOverrides = Copy-ModuleReleaseFixture -Value $overrides
            Merge-ModuleReleaseFacts -Target $stepOverrides -Overrides $step['Facts']
            $stepMerges = @($merges) + @($step['Merge'] | Where-Object { $null -ne $_ })
            $stepLabelEvents = @($labelEvents) + @($step['Label'] | Where-Object { $null -ne $_ })
            $stepComments = @($comments) + @($step['Comment'] | Where-Object { $null -ne $_ })

            $facts = New-ModuleReleaseFacts -Overrides $stepOverrides -Now $step['Now'] -Merges $stepMerges -LabelEvents $stepLabelEvents -Comments $stepComments
            $outcome = InModuleScope 'Avm.Authoring' -Parameters @{ StateJson = $stepStateJson; Facts = $facts; Initialize = [bool]$stepInitialize } {
                param([AllowNull()] [string] $StateJson, [object] $Facts, [bool] $Initialize)
                try {
                    $decision = Get-AvmReleaseDecision -StateJson $StateJson -Facts $Facts -Initialize:$Initialize
                    [pscustomobject]@{ Decision = $decision; Failed = $false; IsArgument = $false; Message = $null }
                }
                catch {
                    [pscustomobject]@{ Decision = $null; Failed = $true; IsArgument = $_.Exception -is [System.ArgumentException]; Message = $_.Exception.Message }
                }
            }

            $prefix = "Step $stepNumber at $($step['Now'])"
            if ($step.ContainsKey('Throws')) {
                if (-not $outcome.Failed) {
                    $failures.Add("${prefix}: expected an ArgumentException matching /$($step['Throws'])/ but the engine returned status '$($outcome.Decision.Status)'.")
                }
                elseif (-not $outcome.IsArgument -or $outcome.Message -cnotmatch $step['Throws']) {
                    $failures.Add("${prefix}: expected an ArgumentException matching /$($step['Throws'])/ but caught '$($outcome.Message)'.")
                }
                continue
            }
            if ($outcome.Failed) {
                $failures.Add("${prefix}: the engine threw '$($outcome.Message)'.")
                break
            }

            $expected = [ordered]@{ Actions = @() }
            foreach ($key in $step['Expected'].Keys) {
                if ($key -ne 'State') {
                    $expected[$key] = $step['Expected'][$key]
                }
            }
            foreach ($mismatch in (Compare-ModuleReleaseValue -Expected $expected -Actual $outcome.Decision)) {
                $failures.Add("${prefix}: $mismatch")
            }
            if ($step['Expected'].ContainsKey('State')) {
                foreach ($mismatch in (Compare-ModuleReleaseState -Expected $step['Expected'].State -State $outcome.Decision.State)) {
                    $failures.Add("${prefix}: $mismatch")
                }
            }

            $overrides = $stepOverrides
            $merges = $stepMerges
            $labelEvents = $stepLabelEvents
            $comments = $stepComments
            $stateJson = $outcome.Decision.StateJson
            $initialize = $false
        }

        ($failures -join [Environment]::NewLine) | Should -BeNullOrEmpty
    }
}
