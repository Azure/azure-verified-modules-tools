#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeDiscovery {
    . (Join-Path $PSScriptRoot '..' '..' '..' 'Helpers' 'ModuleReleaseScenario.ps1')
    $catalogues = foreach ($name in (Get-ModuleReleaseUnitCatalogueName)) {
        $catalogue = Get-ModuleReleaseCatalogue -Name $name
        @{
            Name         = $name
            FunctionName = $catalogue.Function
            Cases        = @(
                foreach ($scenario in $catalogue.Scenarios) {
                    @{ Id = $scenario.Id; Title = $scenario.Title; FunctionName = $catalogue.Function; Scenario = $scenario }
                }
            )
        }
    }
}

Describe 'Release engine scenario catalogues' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' '..' '..' 'Helpers' 'ModuleReleaseScenario.ps1')
        Import-Module -Name (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    }

    AfterAll {
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

    It 'gives every scenario a unique Id, a Title, a design reference, and an expectation' {
        $ids = [System.Collections.Generic.List[string]]::new()
        $issues = [System.Collections.Generic.List[string]]::new()
        foreach ($name in @((Get-ModuleReleaseUnitCatalogueName) + 'state' + 'engine')) {
            $catalogue = Get-ModuleReleaseCatalogue -Name $name
            $issues.AddRange([string[]](Get-ModuleReleaseIntegrityIssues -Name $name -Catalogue $catalogue))
            foreach ($scenario in $catalogue.Scenarios) {
                $ids.Add([string]$scenario.Id)
            }
        }
        foreach ($group in @($ids | Group-Object | Where-Object { $_.Count -gt 1 })) {
            $issues.Add("$($group.Name): is used by $($group.Count) scenarios.")
        }

        $ids.Count | Should -BeGreaterThan 0
        ($issues -join [Environment]::NewLine) | Should -BeNullOrEmpty
    }

    It 'names every unit input after a parameter of the function under test' {
        $issues = foreach ($name in (Get-ModuleReleaseUnitCatalogueName)) {
            $catalogue = Get-ModuleReleaseCatalogue -Name $name
            $parameters = InModuleScope 'Avm.Authoring' -Parameters @{ FunctionName = $catalogue.Function } {
                param([string] $FunctionName)
                , @((Get-Command -Name $FunctionName -CommandType Function).Parameters.Keys)
            }
            foreach ($scenario in $catalogue.Scenarios) {
                foreach ($key in $scenario.Input.Keys) {
                    if ($parameters -cnotcontains $key) {
                        "$($scenario.Id): '$key' is not a parameter of $($catalogue.Function)."
                    }
                }
            }
        }

        ($issues -join [Environment]::NewLine) | Should -BeNullOrEmpty
    }
}

Describe 'Release engine catalogue <Name> (<FunctionName>)' -ForEach $catalogues {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' '..' '..' 'Helpers' 'ModuleReleaseScenario.ps1')
        Import-Module -Name (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    }

    AfterAll {
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

    It '<Id>: <Title>' -ForEach $Cases {
        $arguments = Copy-ModuleReleaseFixture -Value $Scenario.Input
        $outcome = InModuleScope 'Avm.Authoring' -Parameters @{ FunctionName = $FunctionName; Arguments = $arguments } {
            param([string] $FunctionName, [System.Collections.IDictionary] $Arguments)
            try {
                $value = & $FunctionName @Arguments
                [pscustomobject]@{ Value = $value; Failed = $false; IsArgument = $false; Message = $null }
            }
            catch {
                [pscustomobject]@{ Value = $null; Failed = $true; IsArgument = $_.Exception -is [System.ArgumentException]; Message = $_.Exception.Message }
            }
        }

        if ($Scenario.ContainsKey('Throws')) {
            $outcome.Failed | Should -BeTrue -Because 'the scenario expects an ArgumentException'
            $outcome.IsArgument | Should -BeTrue -Because $outcome.Message
            $outcome.Message | Should -MatchExactly $Scenario.Throws
        }
        else {
            $outcome.Failed | Should -BeFalse -Because $outcome.Message
            $mismatches = Compare-ModuleReleaseValue -Expected $Scenario.Expected -Actual $outcome.Value
            ($mismatches -join [Environment]::NewLine) | Should -BeNullOrEmpty
        }
    }
}
