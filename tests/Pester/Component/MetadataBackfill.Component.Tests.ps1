#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = Join-Path $PSScriptRoot '..' '..' '..'
    $moduleRoot = Join-Path $repoRoot 'src' 'Avm.Authoring'
    Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psm1') -Force
    $script:adapterRoot = Join-Path $repoRoot 'repository-management' 'module-metadata'
    $script:prepare = Join-Path $script:adapterRoot 'New-ModuleMetadataBackfillSeed.ps1'
    $script:initialize = Join-Path $script:adapterRoot 'Invoke-ModuleMetadataBackfill.ps1'
    . (Join-Path $script:adapterRoot 'MetadataBackfill.ps1')
    . (Join-Path $script:adapterRoot 'BicepOwnerSnapshot.ps1')

    function Write-BackfillFile {
        param([string] $Path, [string] $Content)
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
        [System.IO.File]::WriteAllText($Path, $Content.Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
    }

    function Write-BackfillJson {
        param([string] $Path, [object] $Value)
        Write-BackfillFile -Path $Path -Content (ConvertTo-Json -InputObject $Value -Depth 50)
    }

    function New-BackfillBicep {
        param([string] $Name = 'Storage Account', [string] $Type = 'Microsoft.Storage/storageAccounts', [string] $Prefix = '46d3xbcp.res.storage-account')
        @'
metadata name = 'NAME'
metadata description = 'Deploys NAME.'
param enableTelemetry bool = true
resource target 'TYPE@2025-01-01' = {
  name: 'example'
}
resource avmTelemetry 'Microsoft.Resources/deployments@2025-04-01' = if (enableTelemetry) {
  name: 'PREFIX.${replace('-..--..-', '.', '-')}.${substring(uniqueString(deployment().name), 0, 4)}'
}
'@.Replace('NAME', $Name).Replace('TYPE', $Type).Replace('PREFIX', $Prefix)
    }

    function New-BackfillFixture {
        param([ValidateSet('bicep', 'terraform')][string] $Ecosystem = 'terraform', [switch] $Child)
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $root = Join-Path $base 'checkout'
        $null = New-Item -ItemType Directory -Path $root -Force
        $repository = if ($Ecosystem -eq 'bicep') { 'Azure/bicep-registry-modules' } else { 'Azure/terraform-azurerm-avm-res-storage-account' }
        $modulePath = if ($Ecosystem -eq 'bicep') { 'avm/res/storage/account' } else { '.' }
        $moduleRoot = if ($Ecosystem -eq 'bicep') { Join-Path $root 'avm' 'res' 'storage' 'account' } else { $root }
        if ($Ecosystem -eq 'bicep') {
            Write-BackfillFile -Path (Join-Path $moduleRoot 'main.bicep') -Content (New-BackfillBicep)
        }
        else {
            Write-BackfillFile -Path (Join-Path $moduleRoot 'main.tf') -Content "locals {`n  example = true`n}`n"
            Write-BackfillFile -Path (Join-Path $moduleRoot '_header.md') -Content "# Storage Account`n`nDeploys a Storage Account.`n"
        }
        $childRoot = $null
        if ($Child) {
            $childRoot = if ($Ecosystem -eq 'bicep') { Join-Path $moduleRoot 'blob-service' } else { Join-Path $root 'modules' 'blob-service' }
            $source = if ($Ecosystem -eq 'bicep') {
                New-BackfillBicep -Name 'Blob Service' -Type 'Microsoft.Storage/storageAccounts/blobServices' -Prefix '46d3xbcp.res.storage-blobservice'
            }
            else { "locals {`n  example = true`n}`n" }
            $name = if ($Ecosystem -eq 'bicep') { 'main.bicep' } else { 'main.tf' }
            Write-BackfillFile -Path (Join-Path $childRoot $name) -Content $source
        }
        $csvPath = Join-Path $base 'legacy.csv'
        $legacy = [ordered]@{
            ModuleId                      = if ($Ecosystem -eq 'bicep') { $modulePath } else { 'avm-res-storage-account' }
            ProviderNamespace             = 'Microsoft.Storage'
            ProviderResourceType          = 'storageAccounts'
            ModuleDisplayName             = 'Storage Account'
            AlternativeNames              = 'Storage, Storage Service'
            PrimaryModuleOwnerGHHandle    = 'first-owner'
            PrimaryModuleOwnerDisplayName = 'PERSONAL-NAME-MUST-NOT-BE-COPIED'
            SecondaryModuleOwnerGHHandle  = 'second-owner'
        }
        [pscustomobject]$legacy | Export-Csv -LiteralPath $csvPath -NoTypeInformation
        [pscustomobject]@{
            Base       = $base
            Root       = $root
            ModuleRoot = $moduleRoot
            ChildRoot  = $childRoot
            Legacy     = $legacy
            Csv        = $csvPath
            Parameters = @{ RepositoryRoot = $root; Repository = $repository; Ecosystem = $Ecosystem; LegacyCsvPath = @($csvPath) }
        }
    }

    function New-BackfillChildOverride {
        param($Fixture)
        $path = Join-Path $Fixture.Base 'overrides.json'
        Write-BackfillJson -Path $path -Value @{
            schemaVersion = 1
            repository    = $Fixture.Parameters.Repository
            ecosystem     = 'terraform'
            reviewed      = $true
            modules       = @(@{
                    path     = 'modules/blob-service'
                    metadata = @{
                        moduleDisplayName = 'Blob Service'
                        moduleDescription = 'Deploys a Blob Service.'
                        canonicalType     = 'Microsoft.Storage/storageAccounts/blobServices'
                        telemetryIdPrefix = '46d3xtrf.res.storage-blobservice'
                    }
                })
        }
        return $path
    }

    function Save-BackfillManifest {
        param($Fixture, $Manifest)
        $Manifest.reviewed = $true
        $path = Join-Path $Fixture.Base 'seeds.json'
        Write-BackfillJson -Path $path -Value $Manifest
        return $path
    }

    function Invoke-BackfillPreparation {
        param($Fixture, [string] $OverridePath)
        $parameters = $Fixture.Parameters
        & $script:prepare @parameters -OverridePath $OverridePath
    }

    function New-BackfillSnapshotTeam {
        param(
            [string] $Slug = 'avm-res-storage-account-module-owners-bicep',
            [string[]] $Login = @('FIRST-OWNER', 'third-owner', 'fourth-owner')
        )
        $edges = @(
            for ($index = 0; $index -lt $Login.Count; $index++) {
                @{
                    role = if ($index % 2 -eq 0) { 'MEMBER' } else { 'MAINTAINER' }
                    node = @{
                        login      = $Login[$index]
                        name       = "PRIVATE-SNAPSHOT-PERSON-$index"
                        url        = "https://github.com/$($Login[$index])"
                        databaseId = 123000 + $index
                    }
                }
            }
        )
        @{
            name         = $Slug
            slug         = $Slug
            url          = "https://github.com/orgs/Azure/teams/$Slug"
            description  = 'A deleted module-owner team.'
            parentTeam   = $null
            repositories = @{ totalCount = 1 }
            members      = @{
                totalCount = $edges.Count
                pageInfo   = @{ hasNextPage = $false; endCursor = $null }
                edges      = $edges
            }
        }
    }

    function New-BackfillSnapshot {
        param([object[]] $Team = @((New-BackfillSnapshotTeam)))
        @{
            CapturedAtUtc         = '2026-09-10T00:00:00Z'
            QueryUrl              = 'https://github.com/orgs/Azure/teams?query=owners-bicep'
            ReportedQueryMatches  = $Team.Count
            RetrievedQueryMatches = $Team.Count
            PageCount             = 1
            Teams                 = $Team
        }
    }

    function Add-BackfillSnapshotCollision {
        param($Fixture, [string] $LegacyTeam = '')
        $otherPath = Join-Path $Fixture.Root 'avm' 'res' 'storage' 'ac-count'
        Write-BackfillFile (Join-Path $otherPath 'main.bicep') (New-BackfillBicep)
        $other = @{} + $Fixture.Legacy
        $other.ModuleId = 'avm/res/storage/ac-count'
        $other.ModuleOwnersGHTeam = $LegacyTeam
        @([pscustomobject]$Fixture.Legacy, [pscustomobject]$other) | Export-Csv $Fixture.Csv -NoTypeInformation
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: metadata backfill preparation' -Tag Component {
    It 'prepares deterministic root metadata from the current CSV shape and plain source paragraph' {
        $fixture = New-BackfillFixture
        $parameters = $fixture.Parameters
        $first = & $script:prepare @parameters
        $second = & $script:prepare @parameters
        $first.Status | Should -BeExactly 'pass'
        ($first | ConvertTo-Json -Depth 50) | Should -BeExactly ($second | ConvertTo-Json -Depth 50)
        $first.Manifest.reviewed | Should -BeFalse
        $metadata = $first.Manifest.modules[0].metadata
        $metadata.moduleDescription | Should -BeExactly 'Deploys a Storage Account.'
        $metadata.canonicalType | Should -BeExactly 'Microsoft.Storage/storageAccounts'
        $metadata.telemetryIdPrefix | Should -BeExactly '46d3xtrf.res.storage-account'
        $metadata.tier | Should -BeExactly 'maintained'
        $metadata.owners.individuals.githubHandle | Should -Be @('first-owner', 'second-owner')
        $metadata.alternativeNames | Should -Be @('Storage', 'Storage Service')
        ($first | ConvertTo-Json -Depth 50) | Should -Not -Match 'PERSONAL-NAME|OwnerDisplayName'
        Test-Path (Join-Path $fixture.Root 'metadata.json') | Should -BeFalse
    }

    It 'uses Bicep literals and preserves nested child prefixes and reduced shapes' {
        $fixture = New-BackfillFixture -Ecosystem bicep -Child
        $nested = Join-Path $fixture.ChildRoot 'container'
        Write-BackfillFile (Join-Path $nested 'main.bicep') (New-BackfillBicep -Name Container -Type 'Microsoft.Storage/storageAccounts/blobServices/containers' -Prefix '46d3xbcp.res.storage-container')
        Write-BackfillFile (Join-Path $fixture.ModuleRoot 'tests' 'ignored' 'main.bicep') (New-BackfillBicep)
        Write-BackfillFile (Join-Path $fixture.ModuleRoot 'examples' 'ignored' 'main.bicep') (New-BackfillBicep)
        Write-BackfillFile (Join-Path $fixture.ModuleRoot 'modules' 'internal' 'main.bicep') (New-BackfillBicep)
        $result = Invoke-BackfillPreparation $fixture
        $result.Status | Should -Be 'pass'
        $result.Manifest.modules.Count | Should -Be 3
        $root = $result.Manifest.modules[0]
        $root.metadata.moduleDescription | Should -Be 'Deploys Storage Account.'
        $root.metadata.telemetryIdPrefix | Should -Be '46d3xbcp.res.storage-account'
        foreach ($child in $result.Manifest.modules[1..2]) {
            $child.parentPath | Should -Be 'avm/res/storage/account'
            @($child.metadata.Keys) | Should -Not -Contain 'owners'
            @($child.metadata.Keys) | Should -Not -Contain 'tier'
            @($child.metadata.Keys) | Should -Not -Contain 'alternativeNames'
            @($child.metadata.Keys) | Should -Not -Contain 'comments'
        }
        $result.Manifest.modules[2].metadata.canonicalType | Should -Be 'Microsoft.Storage/storageAccounts/blobServices/containers'
    }

    It 'does not silently omit Terraform submodules with unresolved identities' {
        $fixture = New-BackfillFixture -Child
        $result = Invoke-BackfillPreparation $fixture
        $result.Status | Should -Be 'fail'
        $result.Manifest | Should -BeNullOrEmpty
        $result.Modules.Count | Should -Be 2
        ($result.Modules[1].issues.Message -join ' ') | Should -Match 'canonicalType|telemetryIdPrefix'
        $parameters = $fixture.Parameters
        $output = Join-Path $fixture.Base 'generated.json'
        { & $script:prepare @parameters -OutputPath $output } | Should -Throw '*no manifest or module files were written*'
        Test-Path $output | Should -BeFalse
    }

    It 'accepts reviewed child overrides and only discovers immediate Terraform modules' {
        $fixture = New-BackfillFixture -Child
        $overrides = New-BackfillChildOverride $fixture
        foreach ($relative in @('examples', 'tests', 'build', 'out', 'modules/blob-service/nested')) {
            $path = $fixture.Root
            foreach ($segment in $relative.Split('/')) { $path = Join-Path $path $segment }
            Write-BackfillFile (Join-Path $path 'main.tf') 'locals { ignored = true }'
        }
        $result = Invoke-BackfillPreparation $fixture $overrides
        $result.Status | Should -Be 'pass'
        $result.Manifest.modules.path | Should -Be @('.', 'modules/blob-service')
        $result.Manifest.modules[1].parentPath | Should -Be '.'
    }

    It 'merges every snapshot handle with legacy slots and drops personal-name fields' {
        $fixture = New-BackfillFixture -Ecosystem bicep -Child
        $ownerPath = Join-Path $fixture.Base 'owners.json'
        Write-BackfillJson $ownerPath @{
            schemaVersion = 1
            repository    = $fixture.Parameters.Repository
            reviewed      = $true
            modules       = @(@{ path = 'avm/res/storage/account'; githubHandles = @('FIRST-OWNER', 'third-owner', 'fourth-owner') })
        }
        $parameters = $fixture.Parameters
        $result = & $script:prepare @parameters -OwnerMappingPath $ownerPath
        $result.Status | Should -Be 'pass'
        $result.Manifest.modules[0].metadata.owners.individuals.githubHandle | Should -Be @('first-owner', 'second-owner', 'third-owner', 'fourth-owner')
        @($result.Manifest.modules[1].metadata.Keys) | Should -Not -Contain 'owners'
        ($result | ConvertTo-Json -Depth 50) | Should -Not -Match 'PERSONAL-NAME'
    }

    It 'merges a reviewed owner override without losing legacy or snapshot handles' {
        $fixture = New-BackfillFixture
        $result = New-AvmModuleMetadataSeed -Path $fixture.Root -ModuleId 'avm-res-storage-account' `
            -Ecosystem terraform -ModuleType resource -LegacyRecord @([pscustomobject]$fixture.Legacy) `
            -Override @{ moduleDescription = 'Deploys Storage.'; owners = @{ individuals = @(@{ githubHandle = 'third-owner' }); team = '@Azure/shared-owners' } } `
            -OwnerGitHubHandle @('THIRD-OWNER', 'fourth-owner') -SkipModuleVersionCheck
        $result.Status | Should -Be 'pass'
        $result.Metadata.owners.individuals.githubHandle | Should -Be @('first-owner', 'second-owner', 'third-owner', 'fourth-owner')
        $result.Metadata.owners.team | Should -Be '@Azure/shared-owners'
    }

    It 'reports owner PII overrides without copying the personal names into candidates' {
        $fixture = New-BackfillFixture
        $result = New-AvmModuleMetadataSeed -Path $fixture.Root -ModuleId 'avm-res-storage-account' `
            -Ecosystem terraform -ModuleType resource -LegacyRecord @([pscustomobject]$fixture.Legacy) `
            -Override @{ moduleDescription = 'Deploys Storage.'; owners = @{ individuals = @(@{ githubHandle = 'third-owner'; displayName = 'PRIVATE-OWNER-NAME' }) } } `
            -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        ($result.Issues.Message -join ' ') | Should -Match 'personal names'
        ($result.Candidate | ConvertTo-Json -Depth 50) | Should -Not -Match 'PRIVATE-OWNER-NAME'
    }

    It 'uses Bicep pattern and telemetry-free utility taxonomy without inventing prefixes: <Kind>' -TestCases @(
        @{ Kind = 'ptn'; ModuleType = 'pattern' }, @{ Kind = 'utl'; ModuleType = 'utility' }
    ) {
        param($Kind, $ModuleType)
        $fixture = New-BackfillFixture -Ecosystem bicep
        $path = Join-Path $fixture.Root 'avm' $Kind 'types' 'example'
        $source = if ($Kind -eq 'ptn') {
            New-BackfillBicep -Prefix '46d3xbcp.ptn.types-example'
        }
        else {
            "metadata name = 'Shared Types'`nmetadata description = 'Defines shared types.'`n"
        }
        Write-BackfillFile (Join-Path $path 'main.bicep') $source
        $result = New-AvmModuleMetadataSeed -Path $path -ModuleId "avm/$Kind/types/example" `
            -Ecosystem bicep -ModuleType $ModuleType -OwnerGitHubHandle @('owner') -SkipModuleVersionCheck
        $result.Status | Should -Be 'pass'
        $result.Metadata.canonicalType | Should -Be 'types/example'
        $result.Metadata.Contains('telemetryIdPrefix') | Should -Be ($Kind -eq 'ptn')
    }

    It 'ignores resource declarations inside Bicep comments and multiline string literals' {
        $fixture = New-BackfillFixture -Ecosystem bicep -Child
        $sourcePath = Join-Path $fixture.ChildRoot 'main.bicep'
        $source = Get-Content $sourcePath -Raw
        $source += @'

/* resource ignored 'Microsoft.Network/virtualNetworks@2025-01-01' = {} */
var example = '''
resource ignored 'Microsoft.Compute/virtualMachines@2025-01-01' = {}
'''
'@
        Write-BackfillFile $sourcePath $source
        $result = Invoke-BackfillPreparation $fixture
        $result.Status | Should -Be 'pass'
        $result.Manifest.modules[1].metadata.canonicalType | Should -Be 'Microsoft.Storage/storageAccounts/blobServices'
    }

    It 'retains an existing literal Terraform prefix rather than proposing a different one' {
        $fixture = New-BackfillFixture
        Write-BackfillFile (Join-Path $fixture.Root 'main.telemetry.tf') "locals {`n  avm_telemetry_id_prefix = `"46d3xtrf.res.stable-legacy-id`"`n}`n"
        $result = Invoke-BackfillPreparation $fixture
        $result.Status | Should -Be 'pass'
        $result.Manifest.modules[0].metadata.telemetryIdPrefix | Should -Be '46d3xtrf.res.stable-legacy-id'
    }

    It 'accepts an explicitly selected lossless description paragraph' {
        $fixture = New-BackfillFixture
        Write-BackfillFile (Join-Path $fixture.Root '_header.md') "# Storage`n`nThe selected description.`n`nUnrelated operational instructions."
        $overrides = Join-Path $fixture.Base 'selected-description.json'
        Write-BackfillJson $overrides @{
            schemaVersion = 1; repository = $fixture.Parameters.Repository; ecosystem = 'terraform'; reviewed = $true
            modules = @(@{ path = '.'; metadata = @{}; descriptionSource = @{ path = '_header.md'; paragraph = 2 } })
        }
        $result = Invoke-BackfillPreparation $fixture $overrides
        $result.Status | Should -Be 'pass'
        $result.Manifest.modules[0].metadata.moduleDescription | Should -Be 'The selected description.'
    }

    It 'requires an override for missing or ambiguous root ARM mappings' -TestCases @(@{ Ambiguous = $false }, @{ Ambiguous = $true }) {
        param($Ambiguous)
        $fixture = New-BackfillFixture -Ecosystem bicep
        if ($Ambiguous) {
            $other = @{} + $fixture.Legacy
            $other.ProviderResourceType = 'otherAccounts'
            @([pscustomobject]$fixture.Legacy, [pscustomobject]$other) | Export-Csv $fixture.Csv -NoTypeInformation
        }
        else {
            $fixture.Legacy.ProviderNamespace = ''
            [pscustomobject]$fixture.Legacy | Export-Csv $fixture.Csv -NoTypeInformation
        }
        $result = Invoke-BackfillPreparation $fixture
        $result.Status | Should -Be 'fail'
        ($result.Modules[0].issues.Message -join ' ') | Should -Match 'canonicalType'
    }

    It 'does not infer a child ARM identity from several unrelated resource declarations or string lookalikes' {
        $fixture = New-BackfillFixture -Ecosystem bicep -Child
        $sourcePath = Join-Path $fixture.ChildRoot 'main.bicep'
        $source = Get-Content $sourcePath -Raw
        $source += "`nresource other 'Microsoft.Network/virtualNetworks@2025-01-01' = { name: 'other' }"
        Write-BackfillFile $sourcePath $source
        $result = Invoke-BackfillPreparation $fixture
        $result.Status | Should -Be 'fail'
        ($result.Modules[1].issues.Message -join ' ') | Should -Match 'canonicalType'
    }

    It 'does not split ambiguous Terraform kebab taxonomy or guess a prose paragraph' {
        $fixture = New-BackfillFixture
        $fixture.Parameters.Repository = 'Azure/terraform-azurerm-avm-ptn-ai-ml-example'
        $fixture.Legacy.ModuleId = 'avm-ptn-ai-ml-example'
        [pscustomobject]$fixture.Legacy | Export-Csv $fixture.Csv -NoTypeInformation
        Write-BackfillFile (Join-Path $fixture.Root '_header.md') "# Example`n`nFirst paragraph.`n`nSecond paragraph."
        $result = Invoke-BackfillPreparation $fixture
        $result.Status | Should -Be 'fail'
        ($result.Modules[0].issues.Message -join ' ') | Should -Match 'canonicalType'
        ($result.Modules[0].issues.Message -join ' ') | Should -Match 'moduleDescription'
    }

    It 'rejects overlength proposed Terraform prefixes instead of truncating stable IDs' {
        $fixture = New-BackfillFixture
        $logical = 'a' * 46
        $fixture.Parameters.Repository = "Azure/terraform-azurerm-avm-res-$logical"
        $fixture.Legacy.ModuleId = "avm-res-$logical"
        [pscustomobject]$fixture.Legacy | Export-Csv $fixture.Csv -NoTypeInformation
        $result = Invoke-BackfillPreparation $fixture
        $result.Status | Should -Be 'pass'
        $result.Modules[0].candidate.telemetryIdPrefix.Length | Should -Be 59
        $fixture.Parameters.Repository += 'a'
        $fixture.Legacy.ModuleId += 'a'
        [pscustomobject]$fixture.Legacy | Export-Csv $fixture.Csv -NoTypeInformation
        (Invoke-BackfillPreparation $fixture).Status | Should -Be 'fail'
    }

    It 'requires review before application and supports a write-free preparation WhatIf' {
        $fixture = New-BackfillFixture
        $output = Join-Path $fixture.Base 'output.json'
        $parameters = $fixture.Parameters
        $result = & $script:prepare @parameters -OutputPath $output -WhatIf
        $result.Status | Should -Be 'pass'
        Test-Path $output | Should -BeFalse
        Write-BackfillJson $output $result.Manifest
        { & $script:initialize -RepositoryRoot $fixture.Root -Repository $parameters.Repository -SeedManifestPath $output } |
            Should -Throw '*reviewed: true*'
    }
}

Describe 'Component: metadata backfill application' -Tag Component {
    It 'preflights every module before writing any file: <Fault>' -TestCases @(
        @{ Fault = 'missing child' }, @{ Fault = 'invalid child' }, @{ Fault = 'root fields on child' }, @{ Fault = 'wrong parent' }
    ) {
        param($Fault)
        $fixture = New-BackfillFixture -Ecosystem bicep -Child
        $manifest = (Invoke-BackfillPreparation $fixture).Manifest
        switch ($Fault) {
            'missing child' { $manifest.modules = @($manifest.modules[0]) }
            'invalid child' { $manifest.modules[1].metadata.Remove('moduleDescription') }
            'root fields on child' { $manifest.modules[1].metadata.tier = 'maintained' }
            'wrong parent' { $manifest.modules[1].parentPath = '.' }
        }
        $path = Save-BackfillManifest $fixture $manifest
        { & $script:initialize -RepositoryRoot $fixture.Root -Repository $fixture.Parameters.Repository -SeedManifestPath $path } | Should -Throw
        Test-Path (Join-Path $fixture.ModuleRoot 'metadata.json') | Should -BeFalse
        Test-Path (Join-Path $fixture.ChildRoot 'metadata.json') | Should -BeFalse
    }

    It 'applies root and child metadata idempotently without overwriting existing files' -TestCases @(@{ Ecosystem = 'bicep' }, @{ Ecosystem = 'terraform' }) {
        param($Ecosystem)
        $fixture = New-BackfillFixture -Ecosystem $Ecosystem -Child
        $override = if ($Ecosystem -eq 'terraform') { New-BackfillChildOverride $fixture }
        $manifest = (Invoke-BackfillPreparation $fixture $override).Manifest
        $path = Save-BackfillManifest $fixture $manifest
        $parameters = @{ RepositoryRoot = $fixture.Root; Repository = $fixture.Parameters.Repository; SeedManifestPath = $path }
        $first = & $script:initialize @parameters
        $first.Changed | Should -BeTrue
        $metadataPath = Join-Path $fixture.ModuleRoot 'metadata.json'
        $original = Get-Content $metadataPath -Raw
        $manifest.modules[0].metadata.owners.individuals = @(@{ githubHandle = 'reviewed-other-owner' })
        Write-BackfillJson $path $manifest
        $second = & $script:initialize @parameters
        $second.Changed | Should -BeFalse
        (Get-Content $metadataPath -Raw) | Should -BeExactly $original
        Test-Path (Join-Path $fixture.ChildRoot 'metadata.json') | Should -BeTrue
        Test-Path (Join-Path $fixture.ModuleRoot 'main.metadata.tf') | Should -BeFalse
    }

    It 'uses both source-wiring opt-ins and honors WhatIf for the entire batch' {
        $fixture = New-BackfillFixture -Child
        $manifest = (Invoke-BackfillPreparation $fixture (New-BackfillChildOverride $fixture)).Manifest
        foreach ($entry in $manifest.modules) { $entry.updateSource = $true }
        $path = Save-BackfillManifest $fixture $manifest
        $parameters = @{ RepositoryRoot = $fixture.Root; Repository = $fixture.Parameters.Repository; SeedManifestPath = $path }
        $planned = & $script:initialize @parameters -UpdateSource -WhatIf
        $planned.Status | Should -Be 'planned'
        $planned.Modules[0].PlannedFiles | Should -Contain 'main.metadata.tf'
        Test-Path (Join-Path $fixture.Root 'metadata.json') | Should -BeFalse
        Test-Path (Join-Path $fixture.ChildRoot 'metadata.json') | Should -BeFalse
        $null = & $script:initialize @parameters
        Test-Path (Join-Path $fixture.Root 'main.metadata.tf') | Should -BeFalse
        $null = & $script:initialize @parameters -UpdateSource
        (Get-Content (Join-Path $fixture.ChildRoot 'main.metadata.tf') -Raw) | Should -Match '\.\./\.\./metadata.json'
    }

    It 'preflights source reader conflicts before creating metadata in earlier modules' {
        $fixture = New-BackfillFixture -Child
        $manifest = (Invoke-BackfillPreparation $fixture (New-BackfillChildOverride $fixture)).Manifest
        foreach ($entry in $manifest.modules) { $entry.updateSource = $true }
        Write-BackfillFile (Join-Path $fixture.ChildRoot 'main.metadata.tf') 'locals { unrelated = true }'
        $path = Save-BackfillManifest $fixture $manifest
        { & $script:initialize -RepositoryRoot $fixture.Root -Repository $fixture.Parameters.Repository -SeedManifestPath $path -UpdateSource } |
            Should -Throw '*main.metadata.tf already exists*'
        Test-Path (Join-Path $fixture.Root 'metadata.json') | Should -BeFalse
    }

    It 'rejects unsafe or undiscovered manifest paths: <Path>' -TestCases @(
        @{ Path = '../escape' }, @{ Path = 'C:/escape' }, @{ Path = '/tmp/escape' },
        @{ Path = '\\server\share' }, @{ Path = 'modules/../blob-service' },
        @{ Path = 'modules\blob-service' }, @{ Path = 'modules//blob-service' },
        @{ Path = 'modules/blob-service/' }, @{ Path = 'modules/blob-service:stream' },
        @{ Path = 'Modules/blob-service' }, @{ Path = 'examples' }
    ) {
        param($Path)
        $fixture = New-BackfillFixture -Child
        Write-BackfillFile (Join-Path $fixture.Root 'examples' 'main.tf') 'locals { ignored = true }'
        $manifest = (Invoke-BackfillPreparation $fixture (New-BackfillChildOverride $fixture)).Manifest
        $manifest.modules[1].path = $Path
        $seedPath = Save-BackfillManifest $fixture $manifest
        { & $script:initialize -RepositoryRoot $fixture.Root -Repository $fixture.Parameters.Repository -SeedManifestPath $seedPath } | Should -Throw
        Test-Path (Join-Path $fixture.Root 'metadata.json') | Should -BeFalse
    }

    It 'rejects reparse directory escapes and does not write to the linked destination' {
        $fixture = New-BackfillFixture -Child
        $manifest = (Invoke-BackfillPreparation $fixture (New-BackfillChildOverride $fixture)).Manifest
        $seedPath = Save-BackfillManifest $fixture $manifest
        $outside = Join-Path $fixture.Base 'outside'
        Write-BackfillFile (Join-Path $outside 'main.tf') 'locals { outside = true }'
        Remove-Item -LiteralPath $fixture.ChildRoot -Recurse -Force
        $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        $null = New-Item -ItemType $linkType -Path $fixture.ChildRoot -Target $outside
        { & $script:initialize -RepositoryRoot $fixture.Root -Repository $fixture.Parameters.Repository -SeedManifestPath $seedPath } | Should -Throw '*Reparse*'
        Test-Path (Join-Path $outside 'metadata.json') | Should -BeFalse
        Test-Path (Join-Path $fixture.Root 'metadata.json') | Should -BeFalse
    }

    It 'requires the Bicep family root and rejects existing invalid metadata' {
        $fixture = New-BackfillFixture -Ecosystem bicep -Child
        $manifest = (Invoke-BackfillPreparation $fixture).Manifest
        $seedPath = Save-BackfillManifest $fixture $manifest
        Write-BackfillFile (Join-Path $fixture.ChildRoot 'metadata.json') '{"invalid":true}'
        { & $script:initialize -RepositoryRoot $fixture.Root -Repository $fixture.Parameters.Repository -SeedManifestPath $seedPath } | Should -Throw '*Invalid child*'
        Test-Path (Join-Path $fixture.ModuleRoot 'metadata.json') | Should -BeFalse
        Remove-Item -LiteralPath (Join-Path $fixture.ModuleRoot 'main.bicep')
        { Invoke-BackfillPreparation $fixture } | Should -Throw '*no discovered family root*'
    }

    It 'does not waive seed shape validation just because metadata already exists' {
        $fixture = New-BackfillFixture
        $manifest = (Invoke-BackfillPreparation $fixture).Manifest
        $seedPath = Save-BackfillManifest $fixture $manifest
        $parameters = @{ RepositoryRoot = $fixture.Root; Repository = $fixture.Parameters.Repository; SeedManifestPath = $seedPath }
        $null = & $script:initialize @parameters
        $original = Get-Content (Join-Path $fixture.Root 'metadata.json') -Raw
        $manifest.modules[0].metadata.Remove('owners')
        Write-BackfillJson $seedPath $manifest
        { & $script:initialize @parameters } | Should -Throw '*Invalid root*'
        (Get-Content (Join-Path $fixture.Root 'metadata.json') -Raw) | Should -BeExactly $original
    }

    It 'rejects duplicate JSON and a seed-map traversal rather than silently choosing a value' {
        $fixture = New-BackfillFixture
        $json = Join-Path $fixture.Base 'duplicate.json'
        Write-BackfillFile $json '{"reviewed":false,"reviewed":true}'
        { Read-AvmMetadataBackfillJson $json } | Should -Throw '*Duplicate*'
        $mapPath = Join-Path $fixture.Base 'tools' 'repository-management' 'module-metadata' 'reviewed-seeds.json'
        Write-BackfillJson $mapPath @{ schemaVersion = 1; repositories = @{ 'Azure/example' = 'repository-management/module-metadata/seeds/../../escape.json' } }
        $null = New-Item -ItemType Directory -Path (Join-Path (Split-Path $mapPath -Parent) 'seeds')
        { Resolve-AvmMetadataBackfillSeedManifest -ToolsRoot (Join-Path $fixture.Base 'tools') -Repository 'Azure/example' } | Should -Throw '*Unsafe*'
        { Resolve-AvmMetadataBackfillSeedManifest -ToolsRoot (Join-Path $fixture.Base 'tools') -Repository 'Azure/missing' } | Should -Throw '*No reviewed*'
    }
}

Describe 'Component: metadata backfill owner snapshot' -Tag Component {
    It 'unions every member and maintainer, preserves legacy order, and stores root handles only' {
        $fixture = New-BackfillFixture -Ecosystem bicep -Child
        $slug = 'avm-res-storage-storageaccount-module-owners-bicep'
        $fixture.Legacy.ModuleOwnersGHTeam = "@Azure/$slug"
        [pscustomobject]$fixture.Legacy | Export-Csv $fixture.Csv -NoTypeInformation
        $snapshotPath = Join-Path $fixture.Base 'owner-snapshot.json'
        Write-BackfillJson $snapshotPath (New-BackfillSnapshot -Team @((New-BackfillSnapshotTeam -Slug $slug)))
        $parameters = $fixture.Parameters
        $report = & $script:prepare @parameters -BicepOwnerSnapshotPath $snapshotPath
        $again = & $script:prepare @parameters -BicepOwnerSnapshotPath $snapshotPath
        $report.Status | Should -Be 'pass'
        ($report | ConvertTo-Json -Depth 50) | Should -BeExactly ($again | ConvertTo-Json -Depth 50)
        $report.Manifest.modules[0].metadata.owners.individuals.githubHandle |
            Should -Be @('first-owner', 'second-owner', 'third-owner', 'fourth-owner')
        $report.Manifest.modules[0].metadata.owners.Contains('team') | Should -BeFalse
        $report.Modules[0].ownerSnapshot.matchMethod | Should -Be 'legacy-team'
        $report.Modules[0].ownerSnapshot.memberCount | Should -Be 3
        $report.Modules[0].ownerSnapshot.removedLegacyTeamReferences | Should -Be @($slug)
        $report.Modules[1].ownerSnapshot.status | Should -Be 'inherited'
        $report.Manifest.modules[1].metadata.Contains('owners') | Should -BeFalse
        $report.Manifest.modules[1].metadata.Contains('tier') | Should -BeFalse
        $report.OwnerSnapshot.TeamCount | Should -Be 1
        $report.OwnerSnapshot.MappedTeamCount | Should -Be 1
        ($report | ConvertTo-Json -Depth 50) | Should -Not -Match 'PRIVATE-SNAPSHOT-PERSON|databaseId|parentTeam'
        Test-Path (Join-Path $fixture.ModuleRoot 'metadata.json') | Should -BeFalse
    }

    It 'has no two-owner cap for a larger completely captured team' {
        $fixture = New-BackfillFixture -Ecosystem bicep
        $handles = @(1..12 | ForEach-Object { "snapshot-owner-$_" })
        $snapshotPath = Join-Path $fixture.Base 'owner-snapshot.json'
        Write-BackfillJson $snapshotPath (New-BackfillSnapshot -Team @((New-BackfillSnapshotTeam -Login $handles)))
        $parameters = $fixture.Parameters
        $report = & $script:prepare @parameters -BicepOwnerSnapshotPath $snapshotPath
        $report.Status | Should -Be 'pass'
        $report.Manifest.modules[0].metadata.owners.individuals.githubHandle |
            Should -Be (@('first-owner', 'second-owner') + $handles)
        $report.Manifest.modules[0].metadata.owners.individuals.Count | Should -Be 14
    }

    It 'falls back only to a unique normalized module path and reports a stale legacy reference' {
        $fixture = New-BackfillFixture -Ecosystem bicep
        $stale = 'avm-res-storage-oldaccount-module-owners-bicep'
        $fixture.Legacy.ModuleOwnersGHTeam = "@Azure/$stale"
        [pscustomobject]$fixture.Legacy | Export-Csv $fixture.Csv -NoTypeInformation
        $snapshotPath = Join-Path $fixture.Base 'owner-snapshot.json'
        Write-BackfillJson $snapshotPath (New-BackfillSnapshot)
        $parameters = $fixture.Parameters
        $report = & $script:prepare @parameters -BicepOwnerSnapshotPath $snapshotPath
        $report.Status | Should -Be 'pass'
        $report.Modules[0].ownerSnapshot.matchMethod | Should -Be 'normalized-path'
        $report.Modules[0].ownerSnapshot.unmatchedLegacyTeams | Should -Be @($stale)
        $report.Manifest.modules[0].metadata.owners.Contains('team') | Should -BeFalse
    }

    It 'prefers an exact legacy team mapping over a normalized path collision' {
        $fixture = New-BackfillFixture -Ecosystem bicep
        $fixture.Legacy.ModuleOwnersGHTeam = '@Azure/avm-res-storage-account-module-owners-bicep'
        Add-BackfillSnapshotCollision $fixture
        $snapshotPath = Join-Path $fixture.Base 'owner-snapshot.json'
        Write-BackfillJson $snapshotPath (New-BackfillSnapshot)
        $parameters = $fixture.Parameters
        $report = & $script:prepare @parameters -BicepOwnerSnapshotPath $snapshotPath
        $report.Status | Should -Be 'pass'
        $original = $report.Modules | Where-Object { $_.path -ceq 'avm/res/storage/account' }
        $original.ownerSnapshot.matchMethod | Should -Be 'legacy-team'
        $original.candidate.owners.individuals.Count | Should -Be 4
        $other = $report.Modules | Where-Object { $_.path -ceq 'avm/res/storage/ac-count' }
        $other.ownerSnapshot.status | Should -Be 'not-matched'
        $other.candidate.owners.individuals.Count | Should -Be 2
    }

    It 'reports ambiguous team mappings rather than choosing a root: <Case>' -TestCases @(
        @{ Case = 'normalized paths' }, @{ Case = 'duplicate exact reference' }
    ) {
        param($Case)
        $fixture = New-BackfillFixture -Ecosystem bicep
        $teamReference = ''
        if ($Case -eq 'duplicate exact reference') {
            $teamReference = '@Azure/avm-res-storage-account-module-owners-bicep'
            $fixture.Legacy.ModuleOwnersGHTeam = $teamReference
        }
        Add-BackfillSnapshotCollision $fixture $teamReference
        $snapshotPath = Join-Path $fixture.Base 'owner-snapshot.json'
        Write-BackfillJson $snapshotPath (New-BackfillSnapshot)
        $parameters = $fixture.Parameters
        $report = & $script:prepare @parameters -BicepOwnerSnapshotPath $snapshotPath
        $report.Status | Should -Be 'fail'
        $report.Manifest | Should -BeNullOrEmpty
        $report.OwnerSnapshot.AmbiguousTeams | Should -Be @('avm-res-storage-account-module-owners-bicep')
        ($report.OwnerSnapshot.Issues.Message -join ' ') | Should -Match 'ambiguously matches roots'
    }

    It 'reports unmatchable snapshot teams and refuses to write a partial manifest' {
        $fixture = New-BackfillFixture -Ecosystem bicep
        $slug = 'avm-res-network-unmatched-module-owners-bicep'
        $snapshotPath = Join-Path $fixture.Base 'owner-snapshot.json'
        Write-BackfillJson $snapshotPath (New-BackfillSnapshot -Team @((New-BackfillSnapshotTeam -Slug $slug)))
        $parameters = $fixture.Parameters
        $report = & $script:prepare @parameters -BicepOwnerSnapshotPath $snapshotPath
        $report.Status | Should -Be 'fail'
        $report.Manifest | Should -BeNullOrEmpty
        $report.OwnerSnapshot.UnmatchedTeams | Should -Be @($slug)
        $output = Join-Path $fixture.Base 'seeds.json'
        { & $script:prepare @parameters -BicepOwnerSnapshotPath $snapshotPath -OutputPath $output } |
            Should -Throw '*no discovered root mapping*'
        Test-Path $output | Should -BeFalse
        Test-Path (Join-Path $fixture.ModuleRoot 'metadata.json') | Should -BeFalse
    }

    It 'rejects multiple deleted teams claiming the same root rather than picking the first' {
        $fixture = New-BackfillFixture -Ecosystem bicep
        $firstSlug = 'avm-res-storage-account-module-owners-bicep'
        $secondSlug = 'avm-res-storage-retiredaccount-module-owners-bicep'
        $fixture.Legacy.ModuleOwnersGHTeam = "@Azure/$firstSlug"
        $other = @{} + $fixture.Legacy
        $other.ModuleOwnersGHTeam = "@Azure/$secondSlug"
        @([pscustomobject]$fixture.Legacy, [pscustomobject]$other) | Export-Csv $fixture.Csv -NoTypeInformation
        $snapshotPath = Join-Path $fixture.Base 'owner-snapshot.json'
        Write-BackfillJson $snapshotPath (New-BackfillSnapshot -Team @(
                (New-BackfillSnapshotTeam -Slug $firstSlug), (New-BackfillSnapshotTeam -Slug $secondSlug)
            ))
        $parameters = $fixture.Parameters
        $report = & $script:prepare @parameters -BicepOwnerSnapshotPath $snapshotPath
        $report.Status | Should -Be 'fail'
        $report.Manifest | Should -BeNullOrEmpty
        $report.OwnerSnapshot.AmbiguousTeams.Count | Should -Be 2
        ($report.OwnerSnapshot.Issues.Message -join ' ') | Should -Match 'more than one deleted team'
    }

    It 'accepts a complete empty team without inventing extra owners' {
        $fixture = New-BackfillFixture -Ecosystem bicep
        $snapshotPath = Join-Path $fixture.Base 'owner-snapshot.json'
        Write-BackfillJson $snapshotPath (New-BackfillSnapshot -Team @((New-BackfillSnapshotTeam -Login @())))
        $parameters = $fixture.Parameters
        $report = & $script:prepare @parameters -BicepOwnerSnapshotPath $snapshotPath
        $report.Status | Should -Be 'pass'
        $report.Modules[0].ownerSnapshot.memberCount | Should -Be 0
        $report.Manifest.modules[0].metadata.owners.individuals.githubHandle |
            Should -Be @('first-owner', 'second-owner')
    }

    It 'preserves existing owner-authored metadata and reports skipped snapshot handles' {
        $fixture = New-BackfillFixture -Ecosystem bicep -Child
        $rootSeed = (Invoke-BackfillPreparation $fixture).Manifest.modules[0].metadata
        $rootSeed.owners = @{
            individuals = @(@{ githubHandle = 'first-owner' })
            team        = '@Azure/avm-res-storage-account-module-owners-bicep'
        }
        $null = Initialize-AvmModuleMetadata -Path $fixture.ModuleRoot -InputObject $rootSeed `
            -Ecosystem bicep -ModuleType resource -SkipModuleVersionCheck
        $metadataPath = Join-Path $fixture.ModuleRoot 'metadata.json'
        $before = Get-Content $metadataPath -Raw
        $snapshotPath = Join-Path $fixture.Base 'owner-snapshot.json'
        Write-BackfillJson $snapshotPath (New-BackfillSnapshot)
        $parameters = $fixture.Parameters
        $report = & $script:prepare @parameters -BicepOwnerSnapshotPath $snapshotPath
        $report.Status | Should -Be 'pass'
        (Get-Content $metadataPath -Raw) | Should -BeExactly $before
        $report.Modules[0].ownerSnapshot.status | Should -Be 'skipped-existing-metadata'
        $report.Modules[0].ownerSnapshot.missingSnapshotHandles | Should -Be @('third-owner', 'fourth-owner')
        $report.Modules[0].issues.Code | Should -Contain 'AVM_OWNER_ENRICHMENT_SKIPPED'
        $report.Manifest.modules[0].metadata.owners.individuals.githubHandle | Should -Be @('first-owner')
        $report.Manifest.modules[0].metadata.owners.team | Should -Be $rootSeed.owners.team
        $report.Modules[1].ownerSnapshot.status | Should -Be 'inherited'
        $report.Manifest.modules[1].metadata.Contains('owners') | Should -BeFalse
    }

    It 'does not retain a deleted team through an explicit override' {
        $fixture = New-BackfillFixture -Ecosystem bicep
        $snapshotPath = Join-Path $fixture.Base 'owner-snapshot.json'
        Write-BackfillJson $snapshotPath (New-BackfillSnapshot)
        $overridePath = Join-Path $fixture.Base 'overrides.json'
        Write-BackfillJson $overridePath @{
            schemaVersion = 1; repository = $fixture.Parameters.Repository; ecosystem = 'bicep'; reviewed = $true
            modules = @(@{
                    path     = 'avm/res/storage/account'
                    metadata = @{ owners = @{ individuals = @(); team = '@Azure/avm-res-storage-account-module-owners-bicep' } }
                })
        }
        $parameters = $fixture.Parameters
        { & $script:prepare @parameters -BicepOwnerSnapshotPath $snapshotPath -OverridePath $overridePath } |
            Should -Throw '*owners.team must not reference a deleted*'
    }

    It 'preserves a nondeleted shared team while enriching individuals' {
        $fixture = New-BackfillFixture -Ecosystem bicep
        $fixture.Legacy.ModuleOwnersGHTeam = '@Azure/shared-owner-team'
        [pscustomobject]$fixture.Legacy | Export-Csv $fixture.Csv -NoTypeInformation
        $snapshotPath = Join-Path $fixture.Base 'owner-snapshot.json'
        Write-BackfillJson $snapshotPath (New-BackfillSnapshot)
        $parameters = $fixture.Parameters
        $report = & $script:prepare @parameters -BicepOwnerSnapshotPath $snapshotPath
        $report.Status | Should -Be 'pass'
        $report.Manifest.modules[0].metadata.owners.team | Should -Be '@Azure/shared-owner-team'
        $report.Manifest.modules[0].metadata.owners.individuals.Count | Should -Be 4
    }

    It 'rejects incomplete or malformed captures without writing any files: <Case>' -TestCases @(
        @{ Case = 'reported count' }, @{ Case = 'retrieved count' }, @{ Case = 'negative count' },
        @{ Case = 'noninteger count' }, @{ Case = 'page count' }, @{ Case = 'teams object' },
        @{ Case = 'member count' }, @{ Case = 'has next page' }, @{ Case = 'missing page status' },
        @{ Case = 'string page status' }, @{ Case = 'missing login' }, @{ Case = 'invalid login' },
        @{ Case = 'unknown role' }, @{ Case = 'nonstring role' }, @{ Case = 'duplicate login' }, @{ Case = 'duplicate team' }
    ) {
        param($Case)
        $fixture = New-BackfillFixture -Ecosystem bicep
        $snapshot = New-BackfillSnapshot
        $members = $snapshot.Teams[0].members
        switch ($Case) {
            'reported count' { $snapshot.ReportedQueryMatches = 2 }
            'retrieved count' { $snapshot.RetrievedQueryMatches = 2 }
            'negative count' { $snapshot.ReportedQueryMatches = -1 }
            'noninteger count' { $snapshot.ReportedQueryMatches = '1' }
            'page count' { $snapshot.PageCount = 0 }
            'teams object' { $snapshot.Teams = $snapshot.Teams[0] }
            'member count' { $members.totalCount = 4 }
            'has next page' { $members.pageInfo.hasNextPage = $true }
            'missing page status' { $members.pageInfo.Remove('hasNextPage') }
            'string page status' { $members.pageInfo.hasNextPage = 'false' }
            'missing login' { $members.edges[0].node.Remove('login') }
            'invalid login' { $members.edges[0].node.login = 'not a handle' }
            'unknown role' { $members.edges[0].role = 'UNKNOWN' }
            'nonstring role' { $members.edges[0].role = @('MEMBER') }
            'duplicate login' {
                $members.edges[2].node.login = 'first-owner'
            }
            'duplicate team' {
                $snapshot.Teams += $snapshot.Teams[0]
                $snapshot.ReportedQueryMatches = 2
                $snapshot.RetrievedQueryMatches = 2
            }
        }
        $snapshotPath = Join-Path $fixture.Base 'owner-snapshot.json'
        Write-BackfillJson $snapshotPath $snapshot
        $output = Join-Path $fixture.Base 'seeds.json'
        $parameters = $fixture.Parameters
        { & $script:prepare @parameters -BicepOwnerSnapshotPath $snapshotPath -OutputPath $output } |
            Should -Throw '*Bicep owner snapshot*'
        Test-Path $output | Should -BeFalse
        Test-Path (Join-Path $fixture.ModuleRoot 'metadata.json') | Should -BeFalse
    }

    It 'does not apply Bicep snapshots to Terraform repositories' {
        $fixture = New-BackfillFixture
        $parameters = $fixture.Parameters
        { & $script:prepare @parameters -BicepOwnerSnapshotPath 'not-read.json' } | Should -Throw '*only for Bicep*'
    }
}
