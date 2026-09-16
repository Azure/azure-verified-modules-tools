#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $creationRoot = Join-Path $repoRoot 'repository-management' 'repository-creation' 'scripts'
    $creationScript = Join-Path $creationRoot 'New-Repository.ps1'
    $moduleRoot = Join-Path $repoRoot 'src' 'Avm.Authoring'
    . (Join-Path $creationRoot 'RepositoryCreation.ps1')

    function New-CreationTestMetadata {
        New-AvmRepositoryMetadataInput -AuthoringModule $script:authoringModule `
            -ModuleDisplayName 'Azure Storage' -ModuleDescription 'Creates a storage account.' `
            -CanonicalType 'Microsoft.Storage/storageAccounts' `
            -TelemetryIdPrefix '46d3xtrf.res.storage-account' `
            -OwnerGitHubHandles @('first-owner', 'second-owner', 'third-owner') `
            -OwnerTeam '@Azure/storage-owners' -AlternativeNames @('Storage', 'Storage account')
    }

    function New-CreationScriptArguments {
        @{
            moduleName = 'avm-res-storage-storageaccount'
            moduleDisplayName = 'Azure Storage'
            moduleDescription = 'Creates a storage account.'
            canonicalType = 'Microsoft.Storage/storageAccounts'
            telemetryIdPrefix = '46d3xtrf.res.storage-account'
            tempPath = $script:workRoot
            skipMetaDataCreation = $true
        }
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: repository creation metadata' -Tag Component {
    BeforeEach {
        $script:authoringModule = Import-AvmRepositoryCreationModule
        $script:workRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:templateMetadata = $null
        $script:templateMetadataName = 'metadata.json'
        $script:templateDisabled = $false
        $script:templateSource = "locals { telemetry_prefix = `"46d3xtrf.res.storage-account`" }`r`n"
        $script:metadataAtCreate = $null
        $script:sourceAtCreate = $null
        $script:clonePath = $null
        $script:failure = ''
        $script:processCalls = [System.Collections.Generic.List[object]]::new()
        $script:createArguments = @{
            AuthoringModule = $script:authoringModule
            RepositoryName = 'terraform-azure-avm-res-storage-storageaccount'
            Metadata = New-CreationTestMetadata
            ModuleType = 'resource'
            WorkPath = $script:workRoot
        }

        Mock Invoke-AvmRepositoryCreationProcess {
            param($AuthoringModule, $Tool, $ArgumentList, $WorkingDirectory)
            $operation = "$Tool $($ArgumentList[0])"
            if ($Tool -eq 'gh' -and $ArgumentList[0] -eq 'repo') {
                $operation += " $($ArgumentList[1])"
            }
            $script:processCalls.Add([pscustomobject]@{ Operation = $operation; Arguments = $ArgumentList })
            if ($operation -eq $script:failure) {
                throw [System.InvalidOperationException]::new("Simulated failure: $operation")
            }
            if ($operation -eq 'git clone') {
                $script:clonePath = $ArgumentList[-1]
                $null = New-Item -ItemType Directory -Path (Join-Path $script:clonePath '.git') -Force
                [System.IO.File]::WriteAllText((Join-Path $script:clonePath 'main.tf'), "locals { unrelated = true }`n")
                [System.IO.File]::WriteAllText((Join-Path $script:clonePath 'main.telemetry.tf'), $script:templateSource)
                if ($null -ne $script:templateMetadata) {
                    [System.IO.File]::WriteAllText((Join-Path $script:clonePath $script:templateMetadataName), $script:templateMetadata)
                }
                if ($script:templateDisabled) {
                    $null = New-Item -ItemType Directory -Path (Join-Path $script:clonePath '.avm')
                    [System.IO.File]::WriteAllText((Join-Path $script:clonePath '.avm' '.disable'), '')
                }
            }

            if ($operation -in @('git commit', 'gh repo create', 'git push')) {
                $metadataPath = Join-Path $WorkingDirectory 'metadata.json'
                if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
                    throw [System.InvalidOperationException]::new('Publication attempted without metadata.json.')
                }
                if ($operation -eq 'gh repo create') {
                    $script:metadataAtCreate = [System.IO.File]::ReadAllText($metadataPath)
                    $script:sourceAtCreate = [System.IO.File]::ReadAllText((Join-Path $WorkingDirectory 'main.telemetry.tf'))
                }
            }
            return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
        }
        Mock Import-Csv { throw 'Repository creation must not import CSV.' }
        Mock ConvertFrom-Csv { throw 'Repository creation must not convert CSV.' }
    }

    It 'does not write files or run external commands for <Mode>' -TestCases @(
        @{ Mode = 'PlanOnly' }
        @{ Mode = 'WhatIf' }
    ) {
        param($Mode)
        $options = @{ $Mode = $true }
        $result = New-AvmRepositoryContent @script:createArguments @options
        $result.Status | Should -Be 'plan'
        $result.Metadata.canonicalType | Should -Be 'Microsoft.Storage/storageAccounts'
        Test-Path -LiteralPath $script:workRoot | Should -BeFalse
        Should -Invoke Invoke-AvmRepositoryCreationProcess -Times 0 -Exactly
        Should -Invoke Import-Csv -Times 0 -Exactly
        Should -Invoke ConvertFrom-Csv -Times 0 -Exactly
    }

    It 'maps request values and unlimited explicit owners in the entry-point plan' {
        Mock Get-Command { throw 'Plan must not look for an external tool.' } -ParameterFilter { $Name -in @('git', 'gh') }
        $parameters = New-CreationScriptArguments
        $parameters.ownerPrimaryGitHubHandle = 'first-owner'
        $parameters.ownerSecondaryGitHubHandle = 'second-owner'
        $parameters.ownerGitHubHandles = @('third-owner', 'fourth-owner')
        $parameters.ownerTeam = '@Azure/storage-owners'
        $parameters.moduleAlternativeNames = ' Storage, Storage account, , Storage '

        $result = & $creationScript @parameters -PlanOnly

        $result.Status | Should -Be 'plan'
        $result.Metadata.moduleDisplayName | Should -Be $parameters.moduleDisplayName
        $result.Metadata.moduleDescription | Should -Be $parameters.moduleDescription
        $result.Metadata.canonicalType | Should -Be $parameters.canonicalType
        $result.Metadata.Contains('tier') | Should -BeFalse
        $result.Metadata.Contains('schemaVersion') | Should -BeFalse
        $result.Metadata.telemetryIdPrefix | Should -Be $parameters.telemetryIdPrefix
        @($result.Metadata.owners) | Should -Be @('first-owner', 'second-owner', 'third-owner', 'fourth-owner', '@Azure/storage-owners')
        @($result.Metadata.alternativeNames) | Should -Be @('Storage', 'Storage account')
        Test-Path -LiteralPath $script:workRoot | Should -BeFalse
        Should -Invoke Get-Command -Times 0 -Exactly -ParameterFilter { $Name -in @('git', 'gh') }
    }

    It 'honors entry-point WhatIf without requiring GitHub authentication or an app request' {
        Mock Get-Command { throw 'WhatIf must not look for an external tool.' } -ParameterFilter { $Name -in @('git', 'gh') }
        $parameters = New-CreationScriptArguments
        $result = & $creationScript @parameters -WhatIf
        $result.Status | Should -Be 'plan'
        $result.Metadata.owners | Should -HaveCount 0
        Test-Path -LiteralPath $script:workRoot | Should -BeFalse
        Should -Invoke Get-Command -Times 0 -Exactly -ParameterFilter { $Name -in @('git', 'gh') }
    }

    It 'checks authentication before an app-only request installs modules or forks a repository' {
        $parameters = New-CreationScriptArguments
        $parameters.skipRepoCreation = $true
        Mock Invoke-AvmRepositoryCreationProcess {
            throw [System.InvalidOperationException]::new('Authentication preflight failed.')
        } -ParameterFilter { $Tool -eq 'gh' -and $ArgumentList[0] -eq 'auth' -and $ArgumentList[1] -eq 'status' }
        Mock Install-Module { throw 'Authentication must be checked before installing a module.' }
        { & $creationScript @parameters -Confirm:$false } | Should -Throw '*Authentication preflight failed*'
        Should -Invoke Invoke-AvmRepositoryCreationProcess -Times 1 -Exactly -ParameterFilter {
            $Tool -eq 'gh' -and $ArgumentList[0] -eq 'auth' -and $ArgumentList[1] -eq 'status'
        }
        Should -Invoke Invoke-AvmRepositoryCreationProcess -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -ne 'auth' }
        Should -Invoke Install-Module -Times 0 -Exactly
        Test-Path -LiteralPath $script:workRoot | Should -BeFalse
    }

    It 'uses the supplied resource namespace and type without guessing from the module name' {
        $parameters = New-CreationScriptArguments
        $parameters.Remove('canonicalType')
        $parameters.resourceProviderNamespace = 'Microsoft.Storage'
        $parameters.resourceType = 'storageAccounts'
        $result = & $creationScript @parameters -PlanOnly
        $result.Metadata.canonicalType | Should -Be 'Microsoft.Storage/storageAccounts'
    }

    It 'rejects conflicting explicit resource types before any publication' {
        $parameters = New-CreationScriptArguments
        $parameters.resourceProviderNamespace = 'Microsoft.Compute'
        $parameters.resourceType = 'virtualMachines'
        { & $creationScript @parameters -PlanOnly } | Should -Throw '*canonicalType conflicts*'
        Test-Path -LiteralPath $script:workRoot | Should -BeFalse
    }

    It 'requires explicit canonical taxonomy for <Kind> rather than deriving it from a repository name' -TestCases @(
        @{ Kind = 'ptn' }
        @{ Kind = 'utl' }
    ) {
        param($Kind)
        $parameters = New-CreationScriptArguments
        $parameters.moduleName = "avm-$Kind-example-module"
        $parameters.Remove('canonicalType')
        { & $creationScript @parameters -PlanOnly } | Should -Throw '*CanonicalType must be supplied explicitly*'
        Test-Path -LiteralPath $script:workRoot | Should -BeFalse
    }

    It 'initializes explicit <Kind> metadata with no invented owners' -TestCases @(
        @{ Kind = 'ptn'; Canonical = 'networking/hub-spoke'; Prefix = '46d3xtrf.ptn.existing-prefix' }
        @{ Kind = 'utl'; Canonical = 'utilities/naming'; Prefix = '' }
    ) {
        param($Kind, $Canonical, $Prefix)
        $parameters = New-CreationScriptArguments
        $parameters.moduleName = "avm-$Kind-example-module"
        $parameters.canonicalType = $Canonical
        $parameters.telemetryIdPrefix = $Prefix
        $result = & $creationScript @parameters -PlanOnly
        $result.Metadata.canonicalType | Should -Be $Canonical
        $result.Metadata.owners | Should -HaveCount 0
        $result.Metadata.Contains('telemetryIdPrefix') | Should -Be (-not [string]::IsNullOrEmpty($Prefix))
    }

    It 'publishes initialized metadata in the first commit and never rewrites source telemetry' {
        $result = New-AvmRepositoryContent @script:createArguments -Confirm:$false
        $result.Status | Should -Be 'pass'
        $published = $script:metadataAtCreate | ConvertFrom-Json -AsHashtable
        $published.'$schema' | Should -Be $script:createArguments.Metadata.'$schema'
        $published.Contains('schemaVersion') | Should -BeFalse
        $published.moduleDisplayName | Should -Be $script:createArguments.Metadata.moduleDisplayName
        $published.moduleDescription | Should -Be $script:createArguments.Metadata.moduleDescription
        $published.canonicalType | Should -Be $script:createArguments.Metadata.canonicalType
        $published.Contains('tier') | Should -BeFalse
        $published.telemetryIdPrefix | Should -Be $script:createArguments.Metadata.telemetryIdPrefix
        @($published.owners) | Should -Be @('first-owner', 'second-owner', 'third-owner', '@Azure/storage-owners')
        $script:sourceAtCreate | Should -BeExactly $script:templateSource
        $script:metadataAtCreate | Should -Not -Match "`r"
        $script:metadataAtCreate.EndsWith("`n") | Should -BeTrue
        ([int][char]$script:metadataAtCreate[0]) | Should -Not -Be 0xFEFF
        $operations = @($script:processCalls.Operation)
        $operations | Should -Contain 'git init-db'
        [array]::IndexOf($operations, 'git commit') | Should -BeLessThan ([array]::IndexOf($operations, 'gh repo create'))
        [array]::IndexOf($operations, 'gh repo create') | Should -BeLessThan ([array]::IndexOf($operations, 'git push'))
        @($script:processCalls.Arguments) | Should -Not -Contain '--template'
        Test-Path -LiteralPath $script:clonePath | Should -BeFalse
        Should -Invoke Import-Csv -Times 0 -Exactly
        Should -Invoke ConvertFrom-Csv -Times 0 -Exactly
    }

    It 'preserves a valid existing metadata file byte-for-byte including its telemetry identifier' {
        $existing = New-CreationTestMetadata
        $existing.moduleDisplayName = 'Existing display name'
        $existing.telemetryIdPrefix = '46d3xtrf.res.published-id'
        $script:templateMetadata = ($existing | ConvertTo-Json -Depth 20 -Compress) + "`n"
        $script:templateSource = "locals { telemetry_prefix = `"46d3xtrf.res.published-id`" }`n"
        $result = New-AvmRepositoryContent @script:createArguments -Confirm:$false
        $result.Metadata.moduleDisplayName | Should -Be 'Existing display name'
        $result.Metadata.telemetryIdPrefix | Should -Be '46d3xtrf.res.published-id'
        $script:metadataAtCreate | Should -BeExactly $script:templateMetadata
        $script:sourceAtCreate | Should -BeExactly $script:templateSource
    }

    It 'rejects invalid existing metadata without overwriting it or creating the remote repository' {
        $script:templateMetadata = '{"moduleDisplayName":"keep this file"}'
        { New-AvmRepositoryContent @script:createArguments -Confirm:$false } | Should -Throw '*Invalid root module metadata*'
        [System.IO.File]::ReadAllText((Join-Path $script:clonePath 'metadata.json')) | Should -BeExactly $script:templateMetadata
        @($script:processCalls.Operation) | Should -Not -Contain 'gh repo create'
        @($script:processCalls.Operation) | Should -Not -Contain 'git push'
    }

    It 'honors the exact metadata filename protection before publication' {
        $script:templateMetadata = New-CreationTestMetadata | ConvertTo-Json -Depth 20
        $script:templateMetadataName = 'Metadata.json'
        { New-AvmRepositoryContent @script:createArguments -Confirm:$false } | Should -Throw '*exact casing*'
        [System.IO.File]::ReadAllText((Join-Path $script:clonePath 'Metadata.json')) | Should -BeExactly $script:templateMetadata
        @($script:processCalls.Operation) | Should -Not -Contain 'gh repo create'
    }

    It 'honors an opted-out template before writing metadata or creating the remote repository' {
        $script:templateDisabled = $true
        { New-AvmRepositoryContent @script:createArguments -Confirm:$false } | Should -Throw '*avm is disabled*'
        Test-Path -LiteralPath (Join-Path $script:clonePath 'metadata.json') | Should -BeFalse
        @($script:processCalls.Operation) | Should -Not -Contain 'gh repo create'
        @($script:processCalls.Operation) | Should -Not -Contain 'git push'
    }

    It 'rejects missing required <Field> before any local or remote write' -TestCases @(
        @{ Field = 'moduleDisplayName' }
        @{ Field = 'moduleDescription' }
        @{ Field = 'canonicalType' }
        @{ Field = 'owners' }
        @{ Field = 'telemetryIdPrefix' }
    ) {
        param($Field)
        $script:createArguments.Metadata.Remove($Field)
        { New-AvmRepositoryContent @script:createArguments -Confirm:$false } | Should -Throw '*Invalid repository metadata*'
        Test-Path -LiteralPath $script:workRoot | Should -BeFalse
        Should -Invoke Invoke-AvmRepositoryCreationProcess -Times 0 -Exactly
    }

    It 'rejects invalid explicit <Field> before any local or remote write' -TestCases @(
        @{ Field = 'moduleDescription'; Value = ' ' }
        @{ Field = 'canonicalType'; Value = 'not-a-canonical-type' }
        @{ Field = 'canonicalType'; Value = 'networking/hub-spoke' }
        @{ Field = 'tier'; Value = 'open-source' }
        @{ Field = 'schemaVersion'; Value = 1 }
        @{ Field = 'telemetryIdPrefix'; Value = '46d3xbcp.res.wrong-ecosystem' }
        @{ Field = 'owners'; Value = @{ individuals = @(@{ githubHandle = '@invalid' }) } }
        @{ Field = 'owners'; Value = @('valid-user', '@unqualified-team') }
    ) {
        param($Field, $Value)
        $script:createArguments.Metadata[$Field] = $Value
        { New-AvmRepositoryContent @script:createArguments -Confirm:$false } | Should -Throw '*Invalid repository metadata*'
        Test-Path -LiteralPath $script:workRoot | Should -BeFalse
        Should -Invoke Invoke-AvmRepositoryCreationProcess -Times 0 -Exactly
    }

    It 'keeps module metadata required when inventory publication is skipped' {
        $parameters = New-CreationScriptArguments
        $parameters.Remove('moduleDescription')
        { & $creationScript @parameters -PlanOnly } |
            Should -Throw '*ModuleDescription must be supplied explicitly*'
        Test-Path -LiteralPath $script:workRoot | Should -BeFalse
    }

    It 'retains staged content and reports a failed <Operation> without destructive rollback' -TestCases @(
        @{ Operation = 'gh repo create'; Expected = '*no files were pushed*' }
        @{ Operation = 'git push'; Expected = '*repository was created*initial publication failed*has not been deleted*' }
    ) {
        param($Operation, $Expected)
        $script:failure = $Operation
        { New-AvmRepositoryContent @script:createArguments -Confirm:$false } | Should -Throw $Expected
        Test-Path -LiteralPath (Join-Path $script:clonePath 'metadata.json') | Should -BeTrue
        @($script:processCalls.Operation) | Should -Not -Contain 'gh repo delete'
    }

    It 'runs from a tools checkout containing no CSV indexes or disposable migration area' {
        Mock Get-Command { throw 'Plan must not look for an external tool.' } -ParameterFilter { $Name -in @('git', 'gh') }
        $isolatedRoot = Join-Path $TestDrive 'isolated-tools'
        $isolatedScripts = Join-Path $isolatedRoot 'repository-management' 'repository-creation' 'scripts'
        $null = New-Item -ItemType Directory -Path $isolatedScripts, (Join-Path $isolatedRoot 'src') -Force
        Copy-Item -LiteralPath $moduleRoot -Destination (Join-Path $isolatedRoot 'src') -Recurse
        Copy-Item -LiteralPath $creationScript, (Join-Path $creationRoot 'RepositoryCreation.ps1') -Destination $isolatedScripts
        $parameters = New-CreationScriptArguments
        $result = & (Join-Path $isolatedScripts 'New-Repository.ps1') @parameters -PlanOnly
        $result.Status | Should -Be 'plan'
        $result.Metadata.canonicalType | Should -Be 'Microsoft.Storage/storageAccounts'
        Test-Path -LiteralPath (Join-Path $isolatedRoot 'repository-management' 'module-metadata') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $isolatedRoot -Recurse -Filter '*.csv') | Should -HaveCount 0
        Test-Path -LiteralPath $script:workRoot | Should -BeFalse
        Should -Invoke Import-Csv -Times 0 -Exactly
        Should -Invoke ConvertFrom-Csv -Times 0 -Exactly
    }
}
