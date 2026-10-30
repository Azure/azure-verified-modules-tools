#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
}

AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Configured PowerShell repository operations' {
    It 'fails explicitly when no repositories are configured' {
        InModuleScope Avm.Authoring {
            Mock Get-PSResourceRepository {}
            { Invoke-AvmPSRepositoryOperation -Action { throw 'Should not execute' } } |
                Should -Throw '*No PowerShell repositories are configured*'
        }
    }

    It 'stops after a successful operation even when it returns no output' {
        InModuleScope Avm.Authoring {
            Mock Get-PSResourceRepository {
                [pscustomobject]@{ Name = 'Backup'; Priority = 20 }
                [pscustomobject]@{ Name = 'Preferred'; Priority = 10 }
            }
            $calls = [Collections.Generic.List[string]]::new()
            $result = Invoke-AvmPSRepositoryOperation -Action { param($RepositoryName) $calls.Add($RepositoryName) }
            $result | Should -BeNullOrEmpty
            $calls.ToArray() | Should -Be @('Preferred')
        }
    }

    It 'visits all repositories in configured order when collecting results' {
        InModuleScope Avm.Authoring {
            Mock Get-PSResourceRepository {
                [pscustomobject]@{ Name = 'CompanyFeed'; Priority = 1; Uri = 'https://packages.example.test/v3/index.json' }
                [pscustomobject]@{ Name = 'OfficialPackages'; Priority = 99; Uri = 'https://mcr.microsoft.com/' }
            }
            $result = @(Invoke-AvmPSRepositoryOperation -All -Action {
                param($RepositoryName)
                $RepositoryName
            })
            $result | Should -Be @('CompanyFeed', 'OfficialPackages')
        }
    }

    It 'collects successful results before and after a failed repository without leaking partial output' {
        InModuleScope Avm.Authoring {
            Mock Get-PSResourceRepository {
                [pscustomobject]@{ Name = 'First'; Priority = 1 }
                [pscustomobject]@{ Name = 'Broken'; Priority = 2 }
                [pscustomobject]@{ Name = 'Last'; Priority = 3 }
            }
            $result = @(Invoke-AvmPSRepositoryOperation -All -Action {
                param($RepositoryName)
                if ($RepositoryName -eq 'Broken') {
                    'partial output'
                    throw [InvalidOperationException]::new('Unavailable')
                }
                $RepositoryName
            })
            $result | Should -Be @('First', 'Last')
        }
    }

    It 'tries only selected repositories while preserving configured priority and name order' {
        InModuleScope Avm.Authoring {
            Mock Get-PSResourceRepository {
                [pscustomobject]@{ Name = 'OldFeed'; Priority = 1 }
                [pscustomobject]@{ Name = 'LatestZ'; Priority = 20 }
                [pscustomobject]@{ Name = 'LatestA'; Priority = 20 }
            }
            $calls = [Collections.Generic.List[string]]::new()
            $null = Invoke-AvmPSRepositoryOperation -Repository LatestZ, LatestA -Action {
                param($RepositoryName)
                $calls.Add($RepositoryName)
                if ($RepositoryName -eq 'LatestA') { throw [InvalidOperationException]::new('Unavailable') }
            }
            $calls.ToArray() | Should -Be @('LatestA', 'LatestZ')
        }
    }

    It 'fails explicitly when the selected repositories are no longer configured' {
        InModuleScope Avm.Authoring {
            Mock Get-PSResourceRepository { [pscustomobject]@{ Name = 'OtherFeed'; Priority = 1 } }
            { Invoke-AvmPSRepositoryOperation -Repository RemovedFeed -Action { throw 'Should not execute' } } |
                Should -Throw '*None of the selected PowerShell repositories are still configured*'
        }
    }

    It 'preserves the final failure when all repositories fail during collection' {
        InModuleScope Avm.Authoring {
            Mock Get-PSResourceRepository {
                [pscustomobject]@{ Name = 'First'; Priority = 1 }
                [pscustomobject]@{ Name = 'Last'; Priority = 2 }
            }
            { Invoke-AvmPSRepositoryOperation -All -Action {
                    param($RepositoryName)
                    throw [InvalidOperationException]::new("$RepositoryName failed")
                }
            } | Should -Throw '*Last failed*'
        }
    }

    It 'preserves the final error after every repository fails' {
        InModuleScope Avm.Authoring {
            Mock Get-PSResourceRepository {
                [pscustomobject]@{ Name = 'First'; Priority = 10 }
                [pscustomobject]@{ Name = 'Last'; Priority = 20 }
            }
            $failure = [InvalidOperationException]::new('Last repository failed')
            $caught = $null
            try {
                Invoke-AvmPSRepositoryOperation -Action { throw $failure }
            }
            catch { $caught = $_.Exception }
            [object]::ReferenceEquals($failure, $caught) | Should -BeTrue
        }
    }

    It 'does not try another repository after cancellation' {
        InModuleScope Avm.Authoring {
            Mock Get-PSResourceRepository {
                [pscustomobject]@{ Name = 'First'; Priority = 10 }
                [pscustomobject]@{ Name = 'Last'; Priority = 20 }
            }
            $attempts = @{ Count = 0 }
            { Invoke-AvmPSRepositoryOperation -Action {
                    $attempts.Count++
                    throw [OperationCanceledException]::new('Cancelled')
                }
            } | Should -Throw '*Cancelled*'
            $attempts.Count | Should -Be 1
        }
    }

    It 'uses configured legacy repositories when bootstrapping PSResourceGet' {
        InModuleScope Avm.Authoring {
            function Get-PSRepository {
                [CmdletBinding()]
                param()
                throw 'Legacy repository discovery must be mocked.'
            }
            Mock Get-PSRepository {
                [pscustomobject]@{ Name = 'LegacyPrimary' }
                [pscustomobject]@{ Name = 'LegacyBackup' }
            }
            Mock Get-PSResourceRepository { throw 'PSResourceGet is not installed yet' }
            $calls = [Collections.Generic.List[string]]::new()
            $result = Invoke-AvmPSRepositoryOperation -Legacy -Action {
                param($RepositoryName)
                $calls.Add($RepositoryName)
                if ($RepositoryName -eq 'LegacyPrimary') { throw [InvalidOperationException]::new('Unavailable') }
                'installed'
            }
            $result | Should -Be 'installed'
            $calls.ToArray() | Should -Be @('LegacyPrimary', 'LegacyBackup')
        }
    }
}
