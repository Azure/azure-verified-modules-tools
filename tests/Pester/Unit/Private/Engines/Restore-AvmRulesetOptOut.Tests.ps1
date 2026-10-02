#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
    $script:savedHome = $env:AVM_HOME
}

AfterAll {
    $env:AVM_HOME = $script:savedHome
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Restore-AvmRulesetOptOut' {
    BeforeEach {
        $env:AVM_HOME = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:recordPath = InModuleScope 'Avm.Authoring' { Get-AvmRulesetOptOutRecordPath -Repository 'Azure/repo' }
        function Write-TestRecord {
            param([object] $Value, [string] $Repository = 'Azure/repo', [object] $RepositoryId = 42)
            $null = New-Item -ItemType Directory -Path (Split-Path -Path $script:recordPath -Parent) -Force
            $record = [ordered]@{ repository = $Repository; repositoryId = $RepositoryId; propertyName = 'global-rulesets-opt-out'; value = $Value }
            [System.IO.File]::WriteAllText($script:recordPath, (ConvertTo-Json -InputObject $record))
        }
    }

    It 'keeps records in the user state folder, named after the repository' {
        $script:recordPath | Should -Be (Join-Path $env:AVM_HOME 'state' 'repository-init' 'Azure_repo.ruleset-opt-out.json')
    }

    It 'reports none when no record exists' {
        $result = InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmGitHubApi { throw 'No GitHub call expected.' }
            Restore-AvmRulesetOptOut -Repository 'Azure/repo' -RepositoryId 42 -Confirm:$false
        }
        $result.Status | Should -Be 'none'
    }

    It 'restores the recorded <Case> value while the temporary true remains and removes the record' -TestCases @(
        @{ Case = 'false'; Value = 'false' }
        @{ Case = 'unset'; Value = $null }
    ) {
        param($Case, $Value)
        Write-TestRecord -Value $Value
        $result = InModuleScope 'Avm.Authoring' {
            Mock Get-AvmRepositoryRulesetOptOut { 'true' }
            Mock Test-AvmRepositorySyncManaged { $false }
            Mock Set-AvmRepositoryRulesetOptOut { $script:restoredTo = [pscustomobject]@{ Repository = $Repository; Value = $Value } }
            $script:restoredTo = $null
            $restore = Restore-AvmRulesetOptOut -Repository 'Azure/repo' -RepositoryId 42 -Confirm:$false
            [pscustomobject]@{ Restore = $restore; RestoredTo = $script:restoredTo }
        }
        $result.Restore.Status | Should -Be 'restored'
        $result.Restore.Value | Should -Be $Value
        $result.RestoredTo.Repository | Should -Be 'Azure/repo'
        $result.RestoredTo.Value | Should -Be $Value
        Test-Path -LiteralPath $script:recordPath | Should -BeFalse
    }

    It 'only removes the record when <Case>' -TestCases @(
        @{ Case = 'the property was changed since'; Current = 'false'; Synced = $false }
        @{ Case = 'the property was cleared since'; Current = $null; Synced = $false }
        @{ Case = 'repository sync manages the repository'; Current = 'true'; Synced = $true }
    ) {
        param($Case, $Current, $Synced)
        Write-TestRecord -Value 'false'
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ Current = $Current; Synced = $Synced } {
            param($Current, $Synced)
            Mock Get-AvmRepositoryRulesetOptOut -MockWith ({ $Current }.GetNewClosure())
            Mock Test-AvmRepositorySyncManaged -MockWith ({ $Synced }.GetNewClosure())
            Mock Set-AvmRepositoryRulesetOptOut {}
            Restore-AvmRulesetOptOut -Repository 'Azure/repo' -RepositoryId 42 -Confirm:$false
            Should -Invoke Set-AvmRepositoryRulesetOptOut -Exactly 0
        }
        $result.Status | Should -Be 'unchanged'
        Test-Path -LiteralPath $script:recordPath | Should -BeFalse
    }

    It 'discards a record for an earlier repository with the same name without changing the property' {
        Write-TestRecord -Value 'false' -RepositoryId 41
        $result = InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmGitHubApi { throw 'No GitHub call expected.' }
            Mock Set-AvmRepositoryRulesetOptOut {}
            Restore-AvmRulesetOptOut -Repository 'Azure/repo' -RepositoryId 42 -Confirm:$false
            Should -Invoke Set-AvmRepositoryRulesetOptOut -Exactly 0
        }
        $result.Status | Should -Be 'stale'
        Test-Path -LiteralPath $script:recordPath | Should -BeFalse
    }

    It 'keeps the record under WhatIf' {
        Write-TestRecord -Value 'false'
        $result = InModuleScope 'Avm.Authoring' {
            Mock Get-AvmRepositoryRulesetOptOut { 'true' }
            Mock Test-AvmRepositorySyncManaged { $false }
            Mock Set-AvmRepositoryRulesetOptOut {}
            Restore-AvmRulesetOptOut -Repository 'Azure/repo' -RepositoryId 42 -WhatIf
            Should -Invoke Set-AvmRepositoryRulesetOptOut -Exactly 0
        }
        $result.Status | Should -Be 'planned'
        Test-Path -LiteralPath $script:recordPath | Should -BeTrue
    }

    It 'rejects a record for <Case>' -TestCases @(
        @{ Case = 'another repository'; Repository = 'Azure/other'; Value = 'false'; RepositoryId = 42 }
        @{ Case = 'an unexpected value'; Repository = 'Azure/repo'; Value = 'yes'; RepositoryId = 42 }
        @{ Case = 'a missing repository ID'; Repository = 'Azure/repo'; Value = 'false'; RepositoryId = $null }
    ) {
        param($Case, $Repository, $Value, $RepositoryId)
        Write-TestRecord -Value $Value -Repository $Repository -RepositoryId $RepositoryId
        {
            InModuleScope 'Avm.Authoring' {
                Mock Invoke-AvmGitHubApi { throw 'No GitHub call expected.' }
                Restore-AvmRulesetOptOut -Repository 'Azure/repo' -RepositoryId 42 -Confirm:$false
            }
        } | Should -Throw '*ruleset opt-out record*is invalid*'
        Test-Path -LiteralPath $script:recordPath | Should -BeTrue
    }
}
