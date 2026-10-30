#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeDiscovery {
    . (Join-Path $PSScriptRoot '..' '..' '..' 'Helpers' 'ModuleReleaseScenario.ps1')
    $stateCases = @(
        foreach ($scenario in (Get-ModuleReleaseCatalogue -Name 'state').Scenarios) {
            @{ Id = $scenario.Id; Title = $scenario.Title; Scenario = $scenario }
        }
    )
}

Describe 'Release state and record validation' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' '..' '..' 'Helpers' 'ModuleReleaseScenario.ps1')
        Import-Module -Name (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
        $script:catalogue = Get-ModuleReleaseCatalogue -Name 'state'
        $script:repository = 'Azure/terraform-azurerm-avm-res-example'
    }

    AfterAll {
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

    It '<Id>: <Title>' -ForEach $stateCases {
        $json = New-ModuleReleaseStateJson -Catalogue $script:catalogue -Scenario $Scenario
        $repository = if ($Scenario.ContainsKey('Repository')) { $Scenario.Repository } else { $script:repository }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ Json = $json; Kind = $Scenario.Kind; Repository = $repository } {
            param([string] $Json, [string] $Kind, [string] $Repository)
            ConvertFrom-AvmReleaseJson -Json $Json -Kind $Kind -Repository $Repository
        }

        $mismatches = Compare-ModuleReleaseValue -Expected $Scenario.Expected -Actual $result
        ($mismatches -join [Environment]::NewLine) | Should -BeNullOrEmpty
    }
}

Describe 'Release state serialisation' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' '..' '..' 'Helpers' 'ModuleReleaseScenario.ps1')
        Import-Module -Name (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
        $script:catalogue = Get-ModuleReleaseCatalogue -Name 'state'
        $script:repository = 'Azure/terraform-azurerm-avm-res-example'
    }

    AfterAll {
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

    It 'writes canonical <Kind> JSON that parses back to the same document' -ForEach @(@{ Kind = 'State' }, @{ Kind = 'Record' }) {
        $json = New-ModuleReleaseStateJson -Catalogue $script:catalogue -Scenario @{ Kind = $Kind }
        $outcome = InModuleScope 'Avm.Authoring' -Parameters @{ Json = $json; Kind = $Kind; Repository = $script:repository } {
            param([string] $Json, [string] $Kind, [string] $Repository)
            $parsed = ConvertFrom-AvmReleaseJson -Json $Json -Kind $Kind -Repository $Repository
            $canonical = ConvertTo-AvmReleaseJson -InputObject $parsed.Document -Kind $Kind
            $reparsed = ConvertFrom-AvmReleaseJson -Json $canonical -Kind $Kind -Repository $Repository
            [pscustomobject]@{
                IsValid   = $parsed.IsValid
                Canonical = $canonical
                Again     = ConvertTo-AvmReleaseJson -InputObject $reparsed.Document -Kind $Kind
            }
        }

        $outcome.IsValid | Should -BeTrue
        $outcome.Again | Should -BeExactly $outcome.Canonical
        $outcome.Canonical | Should -Not -Match "`r"
        $outcome.Canonical.EndsWith("}`n") | Should -BeTrue
        $outcome.Canonical.EndsWith("`n`n") | Should -BeFalse
        $keys = [string[]]@($outcome.Canonical -split "`n" | Where-Object { $_ -cmatch '^  "' } | ForEach-Object { ($_ -split '"')[1] })
        $sorted = [string[]]$keys.Clone()
        [System.Array]::Sort($sorted, [System.StringComparer]::Ordinal)
        $keys.Count | Should -BeGreaterThan 5
        $keys | Should -Be $sorted
    }

    It 'writes the same text for the same document regardless of key order' {
        $outcome = InModuleScope 'Avm.Authoring' -Parameters @{ Repository = $script:repository } {
            param([string] $Repository)
            $state = New-AvmReleaseState -Repository $Repository
            $reordered = [ordered]@{}
            foreach ($key in @($state.Keys)[($state.Count - 1)..0]) {
                $reordered[$key] = $state[$key]
            }
            [pscustomobject]@{
                First  = ConvertTo-AvmReleaseJson -InputObject $state -Kind State
                Second = ConvertTo-AvmReleaseJson -InputObject $reordered -Kind State
            }
        }

        $outcome.Second | Should -BeExactly $outcome.First
    }

    It 'refuses to write a damaged <Kind>' -ForEach @(@{ Kind = 'State' }, @{ Kind = 'Record' }) {
        $outcome = InModuleScope 'Avm.Authoring' -Parameters @{ Kind = $Kind } {
            param([string] $Kind)
            try {
                ConvertTo-AvmReleaseJson -InputObject ([ordered]@{ schemaVersion = 1 }) -Kind $Kind
                [pscustomobject]@{ IsArgument = $false; Message = $null }
            }
            catch {
                [pscustomobject]@{ IsArgument = $_.Exception -is [System.ArgumentException]; Message = $_.Exception.Message }
            }
        }

        $outcome.IsArgument | Should -BeTrue
        $outcome.Message | Should -MatchExactly "^Release $($Kind.ToLowerInvariant()) is invalid: "
    }
}
