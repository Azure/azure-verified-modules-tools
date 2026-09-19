#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $creationRoot = Join-Path $repoRoot 'repository-management' 'repository-creation' 'scripts'
    $creationScript = Join-Path $creationRoot 'New-Repository.ps1'
    . (Join-Path $creationRoot 'RepositoryCreation.ps1')
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: repository creation entry point' -Tag Component {
    BeforeEach {
        $script:authoringModule = Import-AvmRepositoryCreationModule
        $script:workRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:request = @{
            moduleName = 'avm-res-storage-storageaccount'
            moduleDisplayName = 'Azure Storage'
            moduleDescription = 'Creates a storage account.'
            resourceProviderNamespace = 'Microsoft.Storage'
            resourceType = 'storageAccounts'
            telemetryIdPrefix = '46d3xtrf.res.storage-account'
            ownerPrimaryGitHubHandle = 'first-owner'
            ownerSecondaryGitHubHandle = 'second-owner'
            ownerGitHubHandles = @('third-owner', 'fourth-owner')
            ownerTeam = '@Azure/storage-owners'
            moduleAlternativeNames = ' Storage, Storage account, , Storage '
            tempPath = $script:workRoot
            skipCreateAppInstallationRequest = $true
        }
        $script:state = @{
            Calls = [System.Collections.Generic.List[string]]::new()
            Metadata = $null
            Checkout = $null
            Property = 'true'
        }
        $fixture = $script:state
        $fixtureModule = $script:authoringModule
        Mock Import-Module -MockWith ({ $fixtureModule }.GetNewClosure()) -ParameterFilter { $Name -like '*Avm.Authoring.psd1' }
        Mock Get-Command { [pscustomobject]@{ Source = "fixture-$Name" } } -ParameterFilter { $Name -in @('git', 'gh') }
        Mock Invoke-AvmProcess -ModuleName Avm.Authoring -MockWith ({
            param($FilePath, $ArgumentList, $WorkingDirectory)
            $tool = $FilePath -replace '^fixture-', ''
            $arguments = @($ArgumentList)
            while ($tool -eq 'git' -and $arguments.Count -gt 1 -and $arguments[0] -eq '-c') {
                $arguments = @($arguments | Select-Object -Skip 2)
            }
            $operation = "$tool $($arguments[0])"
            if ($tool -eq 'gh' -and $arguments[0] -eq 'repo') { $operation += " $($arguments[1])" }
            $fixture.Calls.Add($operation)
            if ($operation -notin @('gh auth', 'git clone', 'git init-db', 'git add', 'git commit', 'git remote', 'gh repo create', 'gh api', 'git push', 'git ls-remote', 'git fetch', 'git reset')) {
                throw "Unexpected creation command: $operation"
            }
            if ($operation -eq 'git clone') {
                $fixture.Checkout = $ArgumentList[-1]
                $null = New-Item -ItemType Directory -Path (Join-Path $fixture.Checkout '.git') -Force
                [System.IO.File]::WriteAllText((Join-Path $fixture.Checkout 'main.tf'), "locals { unrelated = true }`n")
            }
            if ($operation -eq 'gh repo create') {
                $fixture.Metadata = Get-Content (Join-Path $WorkingDirectory 'metadata.json') -Raw | ConvertFrom-Json -AsHashtable
            }
            if ($operation -eq 'gh api') {
                if ($ArgumentList -contains 'PATCH') {
                    $field = @($ArgumentList | Where-Object { $_.StartsWith('properties[][value]=') })[0]
                    $fixture.Property = $field.Split('=')[-1]
                } else {
                    return [pscustomobject]@{
                        ExitCode = 0
                        StdOut = (ConvertTo-Json -InputObject @(@{ property_name = 'rulesets-default-opt-in'; value = $fixture.Property }))
                        StdErr = ''
                    }
                }
            }
            return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
        }.GetNewClosure())
        Mock Install-Module { throw 'Creation tests must not install modules.' }
        Mock Read-Host { 'yes' }
        Mock Start-Process {}
        Mock Import-Csv { throw 'Creation must not read an inventory.' }
        Mock ConvertFrom-Csv { throw 'Creation must not read an inventory.' }
    }

    It 'publishes request metadata without forking the tooling repository or creating an inventory review' {
        & $creationScript @script:request -Confirm:$false
        $metadata = $script:state.Metadata
        $metadata.moduleDescription | Should -BeExactly $script:request.moduleDescription
        $metadata.canonicalType | Should -BeExactly 'Microsoft.Storage/storageAccounts'
        @($metadata.owners) | Should -Be @('first-owner', 'second-owner', 'third-owner', 'fourth-owner', '@Azure/storage-owners')
        @($metadata.alternativeNames) | Should -Be @('Storage', 'Storage account')
        $script:state.Calls | Should -Contain 'gh repo create'
        $script:state.Calls | Should -Not -Contain 'gh repo fork'
        $script:state.Calls | Should -Not -Contain 'gh pr'
        $script:state.Property | Should -BeExactly 'true'
        Test-Path -LiteralPath $script:state.Checkout | Should -BeFalse
        Should -Invoke Import-Csv -Exactly 0
        Should -Invoke ConvertFrom-Csv -Exactly 0
        Should -Invoke Install-Module -Exactly 0
    }

    It 'keeps the complete entry point non-writing in <Mode>' -TestCases @(
        @{ Mode = 'PlanOnly' }
        @{ Mode = 'WhatIf' }
    ) {
        param($Mode)
        $script:request.Remove('skipCreateAppInstallationRequest')
        $script:request[$Mode] = $true
        $result = & $creationScript @script:request
        $result.Status | Should -Be 'plan'
        $result.Metadata.owners | Should -HaveCount 5
        $result.InitialPush.TemporaryRulesetProperty | Should -BeExactly 'rulesets-default-opt-in'
        $result.InitialPush.RestoreOriginalValue | Should -BeTrue
        @($result.PSObject.Properties.Name) | Should -Not -Contain 'Inventory'
        $script:state.Calls | Should -HaveCount 0
        Test-Path -LiteralPath $script:workRoot | Should -BeFalse
        Should -Invoke Install-Module -Exactly 0
        Should -Invoke Read-Host -Exactly 0
    }

    It 'permits explicit empty owners without legacy display-name requirements' {
        $script:request.ownerPrimaryGitHubHandle = ''
        $script:request.ownerSecondaryGitHubHandle = ''
        $script:request.ownerGitHubHandles = @()
        $script:request.Remove('ownerTeam')
        & $creationScript @script:request -Confirm:$false
        $script:state.Metadata.owners | Should -HaveCount 0
    }

    It 'rejects invalid metadata before any publication' {
        $script:request.telemetryIdPrefix = 'invalid'
        { & $creationScript @script:request -Confirm:$false } | Should -Throw '*Invalid repository metadata*'
        $script:state.Calls | Should -HaveCount 0
        Test-Path -LiteralPath $script:workRoot | Should -BeFalse
    }

    It 'does not initialize metadata or relax protection when repository creation is skipped' {
        $script:request.skipRepoCreation = $true
        $script:request.Remove('moduleDescription')
        & $creationScript @script:request -Confirm:$false
        $script:state.Metadata | Should -BeNullOrEmpty
        $script:state.Calls | Should -Be @('gh auth')
        Test-Path -LiteralPath $script:workRoot | Should -BeFalse
        Should -Invoke Read-Host -Exactly 0
    }

    It 'rejects the obsolete CSV parameter <Parameter>' -TestCases @(
        @{ Parameter = 'metaDataOnly' }
        @{ Parameter = 'skipMetaDataCreation' }
        @{ Parameter = 'toolingRepoUrl' }
        @{ Parameter = 'ownerPrimaryDisplayName' }
        @{ Parameter = 'ownerSecondaryDisplayName' }
    ) {
        param($Parameter)
        $script:request[$Parameter] = $true
        { & $creationScript @script:request -PlanOnly } | Should -Throw '*parameter cannot be found*'
        $script:state.Calls | Should -HaveCount 0
    }
}
