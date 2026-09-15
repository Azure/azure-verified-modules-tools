#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $creationRoot = Join-Path $repoRoot 'repository-management' 'repository-creation' 'scripts'
    $creationScript = Join-Path $creationRoot 'New-Repository.ps1'
    . (Join-Path $creationRoot 'RepositoryCreation.ps1')
    . (Join-Path $creationRoot 'RepositoryInventory.ps1')
    $inventoryRelativePath = Join-Path 'repository-management' 'repository-sync' 'config' 'repository-metadata.csv'

    function New-InventoryTestRecord {
        param([string] $ModuleId = 'avm-res-storage-storageaccount')
        [pscustomobject][ordered]@{
            moduleId = $ModuleId
            providerNamespace = 'Microsoft.Storage'
            providerResourceType = 'storageAccounts'
            moduleDisplayName = 'Azure Storage'
            alternativeNames = 'Storage, Storage account'
            primaryOwnerGitHubHandle = 'first-owner'
            primaryOwnerDisplayName = 'First Owner'
            secondaryOwnerGitHubHandle = 'second-owner'
            secondaryOwnerDisplayName = 'Second Owner'
            isArchived = 'false'
        }
    }

    function New-InventoryScriptArguments {
        param([switch] $CreateRepository)
        $parameters = @{
            moduleName = $script:record.moduleId
            moduleDisplayName = $script:record.moduleDisplayName
            resourceProviderNamespace = $script:record.providerNamespace
            resourceType = $script:record.providerResourceType
            moduleAlternativeNames = $script:record.alternativeNames
            ownerPrimaryGitHubHandle = $script:record.primaryOwnerGitHubHandle
            ownerPrimaryDisplayName = $script:record.primaryOwnerDisplayName
            ownerSecondaryGitHubHandle = $script:record.secondaryOwnerGitHubHandle
            ownerSecondaryDisplayName = $script:record.secondaryOwnerDisplayName
            tempPath = $script:workRoot
            skipCreateAppInstallationRequest = $true
        }
        if ($CreateRepository) {
            $parameters.moduleDescription = 'Description supplied with the creation request.'
            $parameters.tier = 'maintained'
            $parameters.telemetryIdPrefix = '46d3xtrf.res.storage-account'
            $parameters.ownerGitHubHandles = @('third-owner', 'fourth-owner')
            $parameters.ownerTeam = '@Azure/storage-owners'
        }
        return $parameters
    }

    function Invoke-InventoryTestProcess {
        param([hashtable] $State, [string] $Tool, [string[]] $ArgumentList, [string] $WorkingDirectory)
        $operation = "$Tool $($ArgumentList[0])"
        if ($Tool -eq 'gh' -and $ArgumentList[0] -in @('repo', 'pr')) {
            $operation += " $($ArgumentList[1])"
        }
        $State.processCalls.Value.Add([pscustomobject]@{
                Operation = $operation
                Arguments = @($ArgumentList)
                WorkingDirectory = $WorkingDirectory
            })
        if ($operation -eq $State.failure.Value) {
            throw [System.InvalidOperationException]::new("Simulated failure: $operation")
        }
        if ($operation -eq 'gh repo fork') {
            $name = ([uri]$ArgumentList[-1]).AbsolutePath.Trim('/').Split('/')[-1]
            $State.inventoryCheckout.Value = Join-Path $WorkingDirectory $name
            $csvPath = Join-Path $State.inventoryCheckout.Value $State.RelativeCsvPath
            $null = New-Item -ItemType Directory -Path (Join-Path $State.inventoryCheckout.Value '.git'), (Split-Path $csvPath -Parent) -Force
            if (-not $State.missingInventory.Value) {
                [System.IO.File]::WriteAllText($csvPath, $State.existingCsv.Value)
            }
        }
        if ($operation -eq 'git clone') {
            $State.moduleCheckout.Value = $ArgumentList[-1]
            $null = New-Item -ItemType Directory -Path (Join-Path $State.moduleCheckout.Value '.git') -Force
            [System.IO.File]::WriteAllText((Join-Path $State.moduleCheckout.Value 'main.tf'), "locals { unrelated = true }`n")
        }
        if ($operation -eq 'git commit') {
            $csvPath = Join-Path $WorkingDirectory $State.RelativeCsvPath
            if (Test-Path -LiteralPath $csvPath -PathType Leaf) {
                $State.publishedCsv.Value = [System.IO.File]::ReadAllText($csvPath)
            }
        }
        if ($operation -eq 'gh repo create') {
            $State.publishedMetadata.Value = Get-Content -LiteralPath (Join-Path $WorkingDirectory 'metadata.json') -Raw |
                ConvertFrom-Json -AsHashtable
        }
        return [pscustomobject]@{
            ExitCode = 0
            StdOut = if ($operation -eq 'gh pr create') { "https://github.com/Azure/azure-verified-modules-tools/pull/123`n" } else { '' }
            StdErr = ''
        }
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: repository creation inventory compatibility' -Tag Component {
    BeforeEach {
        $script:authoringModule = Import-AvmRepositoryCreationModule
        $script:workRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:record = New-InventoryTestRecord
        $script:existingCsv = (@(
                New-InventoryTestRecord -ModuleId 'avm-res-zulu'
                New-InventoryTestRecord -ModuleId 'avm-res-alpha'
            ) | ConvertTo-Csv -NoTypeInformation) -join "`n"
        $script:publishedCsv = $null
        $script:publishedMetadata = $null
        $script:inventoryCheckout = $null
        $script:moduleCheckout = $null
        $script:failure = ''
        $script:missingInventory = $false
        $script:processCalls = [System.Collections.Generic.List[object]]::new()
        $script:inventoryArguments = @{
            AuthoringModule = $script:authoringModule
            InputObject = $script:record
            WorkPath = $script:workRoot
        }
        $fixtureState = @{ RelativeCsvPath = $inventoryRelativePath }
        foreach ($name in @('processCalls', 'failure', 'inventoryCheckout', 'moduleCheckout', 'missingInventory', 'existingCsv', 'publishedCsv', 'publishedMetadata')) {
            $fixtureState[$name] = Get-Variable -Name $name -Scope Script
        }
        $simulator = ${function:Invoke-InventoryTestProcess}
        Mock Invoke-AvmRepositoryCreationProcess -MockWith ({
            param($Tool, $ArgumentList, $WorkingDirectory)
            & $simulator -State $fixtureState -Tool $Tool -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory
        }.GetNewClosure())
        # Entry-point imports reuse the real checked-out module with a mocked
        # process boundary; nonexistent executable paths also prevent escape.
        $checkedOutModule = $script:authoringModule
        Mock Import-Module -MockWith ({ $checkedOutModule }.GetNewClosure()) -ParameterFilter { $Name -like '*Avm.Authoring.psd1' }
        Mock Get-Command { [pscustomobject]@{ Source = "fixture-$Name" } } -ParameterFilter { $Name -in @('git', 'gh') }
        Mock Invoke-AvmProcess -ModuleName Avm.Authoring -MockWith ({
            param($FilePath, $ArgumentList, $WorkingDirectory)
            & $simulator -State $fixtureState -Tool ($FilePath -replace '^fixture-', '') `
                -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory
        }.GetNewClosure())
        Mock Install-Module { throw 'Creation tests must not install modules.' }
        Mock Read-Host { 'yes' }
        Mock Start-Process { throw 'Creation tests must not open a browser.' }
    }

    It 'does not read or publish inventory in helper <Mode>' -TestCases @(
        @{ Mode = 'PlanOnly' }
        @{ Mode = 'WhatIf' }
    ) {
        param($Mode)
        Mock Import-Csv { throw 'A plan must not read the inventory.' }
        $options = @{ $Mode = $true }
        $result = Publish-AvmRepositoryInventory @script:inventoryArguments @options
        $result.Status | Should -Be 'plan'
        $result.Branch | Should -Be "chore/add/$($script:record.moduleId)"
        $result.File | Should -Be $inventoryRelativePath
        Test-Path -LiteralPath $script:workRoot | Should -BeFalse
        $script:processCalls | Should -HaveCount 0
        Should -Invoke Import-Csv -Times 0 -Exactly
    }

    It 'appends and sorts the legacy row and publishes the original branch and pull request' {
        $result = Publish-AvmRepositoryInventory @script:inventoryArguments -Confirm:$false
        $result.Status | Should -Be 'pass'
        $result.PullRequestUrl | Should -Be 'https://github.com/Azure/azure-verified-modules-tools/pull/123'
        $rows = @($script:publishedCsv | ConvertFrom-Csv)
        @($rows.moduleId) | Should -Be @('avm-res-alpha', $script:record.moduleId, 'avm-res-zulu')
        foreach ($property in $script:record.PSObject.Properties) {
            $rows[1].($property.Name) | Should -BeExactly $property.Value
        }
        $script:publishedCsv | Should -Not -Match "`r"
        $calls = $script:processCalls
        ($calls | Where-Object Operation -eq 'gh repo fork').Arguments |
            Should -Be @('repo', 'fork', '--clone', '--default-branch-only', 'https://github.com/Azure/azure-verified-modules-tools')
        ($calls | Where-Object Operation -eq 'gh repo set-default').Arguments |
            Should -Be @('repo', 'set-default', 'Azure/azure-verified-modules-tools')
        ($calls | Where-Object Operation -eq 'git fetch').Arguments | Should -Be @('fetch', 'upstream')
        ($calls | Where-Object Operation -eq 'git reset').Arguments | Should -Be @('reset', '--hard', 'upstream/main')
        ($calls | Where-Object Operation -eq 'git checkout').Arguments |
            Should -Be @('checkout', '-b', "chore/add/$($script:record.moduleId)")
        ($calls | Where-Object Operation -eq 'git commit').Arguments |
            Should -Be @('commit', '-m', "chore: add $($script:record.moduleId) metadata")
        ($calls | Where-Object Operation -eq 'git push').Arguments |
            Should -Be @('push', '--set-upstream', 'origin', "chore/add/$($script:record.moduleId)")
        ($calls | Where-Object Operation -eq 'gh pr create').Arguments |
            Should -Be @('pr', 'create', '--title', "chore: add $($script:record.moduleId) metadata",
                '--body', "This PR adds metadata for the $($script:record.moduleId) module.")
        Test-Path -LiteralPath $script:inventoryCheckout | Should -BeFalse
    }

    It 'preserves the toolingRepoUrl override for inventory publication only' {
        $result = Publish-AvmRepositoryInventory @script:inventoryArguments -ToolingRepoUrl 'https://github.com/example/tools-index' -Confirm:$false
        $result.ToolingRepositoryUrl | Should -Be 'https://github.com/example/tools-index'
        ($script:processCalls | Where-Object Operation -eq 'gh repo fork').Arguments[-1] |
            Should -Be 'https://github.com/example/tools-index'
        ($script:processCalls | Where-Object Operation -eq 'gh repo set-default').Arguments[-1] |
            Should -Be 'example/tools-index'
    }

    It 'retains the original append behavior instead of replacing an existing row' {
        $old = New-InventoryTestRecord
        $old.moduleDisplayName = 'Existing inventory value'
        $script:existingCsv = ($old | ConvertTo-Csv -NoTypeInformation) -join "`n"
        $null = Publish-AvmRepositoryInventory @script:inventoryArguments -Confirm:$false
        $rows = @($script:publishedCsv | ConvertFrom-Csv)
        $rows | Should -HaveCount 2
        @($rows.moduleDisplayName) | Should -Contain 'Existing inventory value'
        @($rows.moduleDisplayName) | Should -Contain 'Azure Storage'
    }

    It 'fails visibly before publication when the existing inventory is missing' {
        $script:missingInventory = $true
        { Publish-AvmRepositoryInventory @script:inventoryArguments -Confirm:$false } |
            Should -Throw '*Repository inventory publication failed*'
        @($script:processCalls.Operation) | Should -Not -Contain 'git commit'
        @($script:processCalls.Operation) | Should -Not -Contain 'git push'
        @($script:processCalls.Operation) | Should -Not -Contain 'gh pr create'
    }

    It 'retains the index checkout and reports a failed <Operation> without destructive rollback' -TestCases @(
        @{ Operation = 'git push' }
        @{ Operation = 'gh pr create' }
    ) {
        param($Operation)
        $script:failure = $Operation
        { Publish-AvmRepositoryInventory @script:inventoryArguments -Confirm:$false } |
            Should -Throw '*Repository inventory publication failed*Inspect*before retrying*'
        Test-Path -LiteralPath (Join-Path $script:inventoryCheckout $inventoryRelativePath) | Should -BeTrue
        @($script:processCalls.Operation) | Should -Not -Contain 'gh repo delete'
    }

    It 'preserves <Mode> inventory publication without requiring new metadata fields' -TestCases @(
        @{ Mode = 'metaDataOnly' }
        @{ Mode = 'skipRepoCreation' }
    ) {
        param($Mode)
        $parameters = New-InventoryScriptArguments
        $parameters[$Mode] = $true
        & $creationScript @parameters -Confirm:$false
        @($script:processCalls.Operation) | Should -Contain 'gh pr create'
        @($script:processCalls.Operation) | Should -Not -Contain 'gh repo create'
        @($script:processCalls.Operation) | Should -Not -Contain 'git clone'
        $script:publishedMetadata | Should -BeNullOrEmpty
        $added = @($script:publishedCsv | ConvertFrom-Csv | Where-Object moduleId -eq $parameters.moduleName)
        $added | Should -HaveCount 1
        $added[0].primaryOwnerDisplayName | Should -Be 'First Owner'
        $added[0].alternativeNames | Should -BeExactly 'Storage, Storage account'
        Should -Invoke Install-Module -Times 0 -Exactly
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'keeps the complete entry point non-writing in <Mode>, including inventory and app publication' -TestCases @(
        @{ Mode = 'PlanOnly' }
        @{ Mode = 'WhatIf' }
    ) {
        param($Mode)
        $parameters = New-InventoryScriptArguments -CreateRepository
        $parameters.Remove('skipCreateAppInstallationRequest')
        $parameters[$Mode] = $true
        $result = & $creationScript @parameters
        $result.Status | Should -Be 'plan'
        $result.Inventory.primaryOwnerDisplayName | Should -Be 'First Owner'
        $result.Metadata.moduleDescription | Should -Be $parameters.moduleDescription
        $result.Metadata.owners.individuals | Should -HaveCount 4
        $script:processCalls | Should -HaveCount 0
        Test-Path -LiteralPath $script:workRoot | Should -BeFalse
        Should -Invoke Install-Module -Times 0 -Exactly
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'publishes the index first but constructs metadata.json exclusively from the creation request' {
        Mock Start-Process {}
        $old = New-InventoryTestRecord
        $old.moduleDisplayName = 'Conflicting inventory display'
        $old.providerNamespace = 'Microsoft.Compute'
        $old.providerResourceType = 'virtualMachines'
        $old.primaryOwnerGitHubHandle = 'inventory-only-owner'
        $script:existingCsv = ($old | ConvertTo-Csv -NoTypeInformation) -join "`n"
        $parameters = New-InventoryScriptArguments -CreateRepository
        & $creationScript @parameters -Confirm:$false
        $metadata = $script:publishedMetadata
        $metadata.moduleDisplayName | Should -Be $parameters.moduleDisplayName
        $metadata.moduleDescription | Should -Be $parameters.moduleDescription
        $metadata.canonicalType | Should -Be 'Microsoft.Storage/storageAccounts'
        $metadata.tier | Should -Be $parameters.tier
        $metadata.telemetryIdPrefix | Should -Be $parameters.telemetryIdPrefix
        @($metadata.owners.individuals.githubHandle) | Should -Be @('first-owner', 'second-owner', 'third-owner', 'fourth-owner')
        $metadata.owners.team | Should -Be '@Azure/storage-owners'
        @($metadata.alternativeNames) | Should -Be @('Storage', 'Storage account')
        $operations = @($script:processCalls.Operation)
        [array]::IndexOf($operations, 'gh pr create') | Should -BeLessThan ([array]::IndexOf($operations, 'gh repo create'))
        @($script:publishedCsv | ConvertFrom-Csv) | Should -HaveCount 2
        Test-Path -LiteralPath $script:inventoryCheckout | Should -BeFalse
        Test-Path -LiteralPath $script:moduleCheckout | Should -BeFalse
    }

    It 'skips only the inventory update and still initializes metadata when skipMetaDataCreation is set' {
        Mock Start-Process {}
        $parameters = New-InventoryScriptArguments -CreateRepository
        $parameters.skipMetaDataCreation = $true
        $parameters.ownerPrimaryGitHubHandle = ''
        $parameters.ownerPrimaryDisplayName = ''
        $parameters.ownerSecondaryGitHubHandle = ''
        $parameters.ownerGitHubHandles = @()
        & $creationScript @parameters -Confirm:$false
        $script:publishedMetadata.moduleDescription | Should -Be $parameters.moduleDescription
        $script:publishedMetadata.owners.individuals | Should -HaveCount 0
        @($script:processCalls.Operation) | Should -Contain 'gh repo create'
        @($script:processCalls.Operation) | Should -Not -Contain 'gh repo fork'
        @($script:processCalls.Operation) | Should -Not -Contain 'gh pr create'
        $script:publishedCsv | Should -BeNullOrEmpty
    }

    It 'rejects invalid metadata before publishing an otherwise valid inventory request' {
        $parameters = New-InventoryScriptArguments -CreateRepository
        $parameters.tier = 'invalid-tier'
        { & $creationScript @parameters -Confirm:$false } | Should -Throw '*Invalid repository metadata*'
        $script:processCalls | Should -HaveCount 0
        Test-Path -LiteralPath $script:workRoot | Should -BeFalse
    }

    It 'retains required legacy inventory fields in metadata-only mode' {
        $parameters = New-InventoryScriptArguments
        $parameters.ownerPrimaryDisplayName = ''
        { & $creationScript @parameters -metaDataOnly -Confirm:$false } |
            Should -Throw '*Primary owner GitHub handle and display name*'
        $script:processCalls | Should -HaveCount 0
        Test-Path -LiteralPath $script:workRoot | Should -BeFalse
    }
}
