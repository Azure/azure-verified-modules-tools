#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module -Name (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
    $schemaPath = Join-Path $moduleRoot 'Resources' 'Schemas' 'v1' 'avm-module-metadata.schema.json'
    $script:metadataSchemaId = (Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json).'$id'

    function New-InitializationFixture {
        param([ValidateSet('res', 'ptn', 'utl')][string] $Kind = 'res')

        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $parent = [System.IO.Path]::Combine($root, 'avm', $Kind, 'storage')
        $null = New-Item -ItemType Directory -Path $parent -Force
        [System.IO.File]::WriteAllText((Join-Path $root 'bicepconfig.json'), "{}`n")
        return [pscustomobject]@{
            Root = $root
            Path = Join-Path $parent 'storage-account'
            InputObject = [ordered]@{
                moduleDisplayName = 'Storage Accounts'
                moduleDescription = 'Deploys a Storage Account.'
                canonicalType = if ($Kind -eq 'res') { 'Microsoft.Storage/storageAccounts' } else { 'naming' }
                owners = @('module-owner')
            }
        }
    }
}

AfterAll {
    Remove-Module -Name Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: local avm init' -Tag Component {
    It 'creates only proposed Bicep metadata using both published and local current/historical prefixes' {
        $fixture = New-InitializationFixture
        $existingPath = Join-Path (Split-Path -Path $fixture.Path -Parent) 'earlier-module'
        $null = New-Item -ItemType Directory -Path $existingPath
        $existing = [ordered]@{
            '$schema' = $script:metadataSchemaId
            moduleDisplayName = 'Previous module'
            moduleDescription = 'Existing metadata.'
            canonicalType = 'Microsoft.Storage/storageAccounts'
            owners = @()
            telemetryIdPrefix = '46d3xbcp.res.aaaaaaa'
            alternativeTelemetryIdPrefixes = @('46d3xbcp.res.bbbbbbb')
        }
        [System.IO.File]::WriteAllText((Join-Path $existingPath 'metadata.json'), ($existing | ConvertTo-Json))

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ Target = $fixture.Path; Values = $fixture.InputObject } {
            param($Target, $Values)
            Mock Get-AvmCatalogTelemetryPrefix {
                @('46d3xbcp.res.ccccccc', '46d3xbcp.res.ddddddd')
            }
            Mock New-AvmTelemetryIdPrefix {
                '46d3xbcp.res.123abcd'
            }
            $created = Initialize-AvmModule -Path $Target -Ecosystem bicep -ModuleType resource `
                -InputObject $Values -Proposed -SkipModuleVersionCheck
            Should -Invoke New-AvmTelemetryIdPrefix -Exactly 1 -ParameterFilter {
                $Ecosystem -eq 'bicep' -and $Kind -eq 'res' -and
                $KnownPrefix -contains '46d3xbcp.res.aaaaaaa' -and
                $KnownPrefix -contains '46d3xbcp.res.bbbbbbb' -and
                $KnownPrefix -contains '46d3xbcp.res.ccccccc' -and
                $KnownPrefix -contains '46d3xbcp.res.ddddddd'
            }
            return $created
        }

        $result.Status | Should -Be 'pass'
        $result.Changed | Should -BeTrue
        $result.PlannedFiles | Should -Be @('metadata.json')
        $result.Metadata.telemetryIdPrefix | Should -BeExactly '46d3xbcp.res.123abcd'
        $result.Metadata.'$schema' | Should -BeExactly $script:metadataSchemaId
        @(Get-ChildItem -LiteralPath $fixture.Path -Force).Name | Should -Be @('metadata.json')
        (Test-AvmModuleMetadata -Path $fixture.Path -Ecosystem bicep -ModuleType resource -SkipModuleVersionCheck).Status |
            Should -Be 'pass'
    }

    It 'leaves the missing Bicep directory untouched under WhatIf' {
        $fixture = New-InitializationFixture
        $fixture.InputObject.telemetryIdPrefix = '46d3xbcp.res.explicit'

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ Target = $fixture.Path; Values = $fixture.InputObject } {
            param($Target, $Values)
            Mock Read-Host { throw [System.InvalidOperationException]::new('Must not prompt.') }
            $preview = Initialize-AvmModule -Path $Target -Ecosystem bicep -ModuleType resource `
                -InputObject $Values -Proposed -SkipModuleVersionCheck -WhatIf
            Should -Invoke Read-Host -Exactly 0
            return $preview
        }

        $result.Changed | Should -BeFalse
        $result.PlannedFiles | Should -Be @('metadata.json')
        Test-Path -LiteralPath $fixture.Path | Should -BeFalse
    }

    It 'handles confirmation in the wrapper rather than prompting again in the metadata initializer' {
        $fixture = New-InitializationFixture
        $fixture.InputObject.telemetryIdPrefix = '46d3xbcp.res.explicit'

        InModuleScope 'Avm.Authoring' -Parameters @{ Target = $fixture.Path; Values = $fixture.InputObject } {
            param($Target, $Values)
            Mock Initialize-AvmModuleMetadata { [pscustomobject]@{ Status = 'pass' } }
            $null = Initialize-AvmModule -Path $Target -Ecosystem bicep -ModuleType resource `
                -InputObject $Values -Proposed -SkipModuleVersionCheck -Confirm:$false
            Should -Invoke Initialize-AvmModuleMetadata -Exactly 1 -ParameterFilter {
                $Confirm -eq $false -and $WhatIf -eq $false
            }
        }
    }

    It 'creates a missing Bicep provider directory only after validation' {
        $fixture = New-InitializationFixture
        $fixture.Path = Join-Path $fixture.Root 'avm' 'res' 'new-provider' 'storage-account'
        $provider = Split-Path -Path $fixture.Path -Parent
        $fixture.InputObject.telemetryIdPrefix = '46d3xbcp.res.explicit'

        $preview = Initialize-AvmModule -Path $fixture.Path -Ecosystem bicep -ModuleType resource `
            -InputObject $fixture.InputObject -Proposed -SkipModuleVersionCheck -WhatIf
        $preview.PlannedFiles | Should -Be @('metadata.json')
        Test-Path -LiteralPath $provider | Should -BeFalse

        $result = Initialize-AvmModule -Path $fixture.Path -Ecosystem bicep -ModuleType resource `
            -InputObject $fixture.InputObject -Proposed -SkipModuleVersionCheck
        $result.Changed | Should -BeTrue
        @(Get-ChildItem -LiteralPath $fixture.Path -Force).Name | Should -Be @('metadata.json')
    }

    It 'removes only its newly created Bicep directories if directory creation fails' {
        $fixture = New-InitializationFixture
        $fixture.Path = Join-Path $fixture.Root 'avm' 'res' 'new-provider' 'storage-account'
        $provider = Split-Path -Path $fixture.Path -Parent
        $fixture.InputObject.telemetryIdPrefix = '46d3xbcp.res.explicit'

        InModuleScope 'Avm.Authoring' -Parameters @{ Target = $fixture.Path; Values = $fixture.InputObject } {
            param($Target, $Values)
            Mock New-Item {
                if ((Split-Path -Path $Path -Leaf) -eq 'storage-account') {
                    throw [System.IO.IOException]::new('Simulated directory creation failure.')
                }
                [System.IO.Directory]::CreateDirectory($Path)
            } -ParameterFilter { $ItemType -eq 'Directory' }

            {
                Initialize-AvmModule -Path $Target -Ecosystem bicep -ModuleType resource `
                    -InputObject $Values -Proposed -SkipModuleVersionCheck
            } | Should -Throw '*Simulated directory creation failure*'
        }
        Test-Path -LiteralPath $provider | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $fixture.Root 'avm' 'res') | Should -BeTrue
    }

    It 'prompts for every missing field despite a partial input object and permits no owners' {
        $fixture = New-InitializationFixture
        $probe = InModuleScope 'Avm.Authoring' -Parameters @{ Target = $fixture.Path } {
            param($Target)
            $script:questions = [System.Collections.Generic.List[string]]::new()
            Mock Test-AvmInteractiveHost { $true }
            Mock Read-Host {
                $script:questions.Add($Prompt)
                switch -Wildcard ($Prompt) {
                    'Module display name' { 'Storage Accounts'; break }
                    'Canonical type*' { 'Microsoft.Storage/storageAccounts'; break }
                    'Owners*' { ''; break }
                    default { throw [System.InvalidOperationException]::new("Unexpected prompt: $Prompt") }
                }
            }
            Mock Get-AvmCatalogTelemetryPrefix { @() }
            Mock New-AvmTelemetryIdPrefix { '46d3xbcp.res.123abcd' }

            $created = Initialize-AvmModule -Path $Target -Ecosystem bicep -ModuleType resource `
                -InputObject @{ moduleDescription = 'Supplied description.' } -Proposed -SkipModuleVersionCheck
            return [pscustomobject]@{ Result = $created; Questions = $script:questions.ToArray() }
        }

        $probe.Result.Metadata.moduleDescription | Should -BeExactly 'Supplied description.'
        $probe.Result.Metadata.owners | Should -HaveCount 0
        $probe.Questions | Should -HaveCount 3
        $probe.Questions -join ' ' | Should -Match 'Module display name'
        $probe.Questions -join ' ' | Should -Match 'Canonical type'
        $probe.Questions -join ' ' | Should -Match 'Owners'
        @(Get-ChildItem -LiteralPath $fixture.Path -Force).Name | Should -Be @('metadata.json')
    }

    It 'lists all missing metadata fields in CI without prompting or creating a directory' {
        $fixture = New-InitializationFixture
        InModuleScope 'Avm.Authoring' -Parameters @{ Target = $fixture.Path } {
            param($Target)
            Mock Test-AvmInteractiveHost { $false }
            Mock Read-Host { throw [System.InvalidOperationException]::new('Must not prompt in CI.') }
            Mock Get-AvmCatalogTelemetryPrefix { throw [System.InvalidOperationException]::new('Must not fetch catalog.') }

            {
                Initialize-AvmModule -Path $Target -Ecosystem bicep -ModuleType resource `
                    -InputObject @{ moduleDescription = 'Supplied description.' } -Proposed -SkipModuleVersionCheck
            } | Should -Throw '*moduleDisplayName*canonicalType*owners*'
            Should -Invoke Read-Host -Exactly 0
            Should -Invoke Get-AvmCatalogTelemetryPrefix -Exactly 0
        }
        Test-Path -LiteralPath $fixture.Path | Should -BeFalse
    }

    It 'rejects invalid explicitly supplied metadata before prompting or creating anything' {
        $fixture = New-InitializationFixture
        InModuleScope 'Avm.Authoring' -Parameters @{ Target = $fixture.Path } {
            param($Target)
            Mock Test-AvmInteractiveHost { $true }
            Mock Read-Host { throw [System.InvalidOperationException]::new('Must not prompt for invalid input.') }
            Mock Get-AvmCatalogTelemetryPrefix { throw [System.InvalidOperationException]::new('Must not fetch catalog.') }

            {
                Initialize-AvmModule -Path $Target -Ecosystem bicep -ModuleType resource `
                    -InputObject @{ moduleDisplayName = ''; canonicalType = 'not-an-arm-type' } `
                    -Proposed -SkipModuleVersionCheck
            } | Should -Throw '*Invalid root module metadata*'
            Should -Invoke Read-Host -Exactly 0
            Should -Invoke Get-AvmCatalogTelemetryPrefix -Exactly 0
        }
        Test-Path -LiteralPath $fixture.Path | Should -BeFalse
    }

    It 'rejects an invalid prompted value before reading the catalog or creating directories' {
        $fixture = New-InitializationFixture
        $fixture.Path = Join-Path $fixture.Root 'avm' 'res' 'new-provider' 'storage-account'
        InModuleScope 'Avm.Authoring' -Parameters @{ Target = $fixture.Path; Values = $fixture.InputObject } {
            param($Target, $Values)
            Mock Test-AvmInteractiveHost { $true }
            Mock Read-Host { 'not-an-arm-type' }
            Mock Get-AvmCatalogTelemetryPrefix { throw [System.InvalidOperationException]::new('Must not fetch for invalid input.') }

            $Values.Remove('canonicalType')
            {
                Initialize-AvmModule -Path $Target -Ecosystem bicep -ModuleType resource `
                    -InputObject $Values -Proposed -SkipModuleVersionCheck
            } | Should -Throw '*canonicalType*does not identify a resource module*'
            Should -Invoke Read-Host -Exactly 1
            Should -Invoke Get-AvmCatalogTelemetryPrefix -Exactly 0
        }
        Test-Path -LiteralPath (Split-Path -Path $fixture.Path -Parent) | Should -BeFalse
    }

    It 'does not invent telemetry for a Bicep utility or helper child without telemetry' {
        $utility = New-InitializationFixture -Kind utl
        $helper = New-InitializationFixture
        $null = New-Item -ItemType Directory -Path $helper.Path
        $helperPath = Join-Path $helper.Path 'submodule'
        InModuleScope 'Avm.Authoring' -Parameters @{
            UtilityPath = $utility.Path
            UtilityValues = $utility.InputObject
            HelperPath = $helperPath
        } {
            param($UtilityPath, $UtilityValues, $HelperPath)
            Mock Get-AvmCatalogTelemetryPrefix { throw [System.InvalidOperationException]::new('Telemetry must remain absent.') }

            $createdUtility = Initialize-AvmModule -Path $UtilityPath -Ecosystem bicep -ModuleType utility `
                -InputObject $UtilityValues -Proposed -SkipModuleVersionCheck
            $createdHelper = Initialize-AvmModule -Path $HelperPath -Ecosystem bicep -ModuleType resource `
                -InputObject @{
                    moduleDisplayName = 'Helper'
                    moduleDescription = 'Helper metadata.'
                    canonicalType = 'helper'
                } -ChildModule -Proposed -SkipModuleVersionCheck

            $createdUtility.Metadata.Contains('telemetryIdPrefix') | Should -BeFalse
            $createdHelper.Metadata.Contains('telemetryIdPrefix') | Should -BeFalse
            $createdHelper.Metadata.Contains('owners') | Should -BeFalse
            Should -Invoke Get-AvmCatalogTelemetryPrefix -Exactly 0
        }
    }

    It 'does not skip malformed local metadata while checking prefix uniqueness' {
        $fixture = New-InitializationFixture
        $oldPath = Join-Path (Split-Path -Path $fixture.Path -Parent) 'old-module'
        $null = New-Item -ItemType Directory -Path $oldPath
        [System.IO.File]::WriteAllText((Join-Path $oldPath 'metadata.json'), '{"canonicalType":')

        InModuleScope 'Avm.Authoring' -Parameters @{ Target = $fixture.Path; Values = $fixture.InputObject } {
            param($Target, $Values)
            Mock Get-AvmCatalogTelemetryPrefix { throw [System.InvalidOperationException]::new('Local input must fail first.') }
            {
                Initialize-AvmModule -Path $Target -Ecosystem bicep -ModuleType resource `
                    -InputObject $Values -Proposed -SkipModuleVersionCheck
            } | Should -Throw '*invalid local metadata*old-module*'
            Should -Invoke Get-AvmCatalogTelemetryPrefix -Exactly 0
        }
        Test-Path -LiteralPath $fixture.Path | Should -BeFalse
    }

    It 'warns when the published catalog is unavailable and still checks local historical identifiers' {
        $fixture = New-InitializationFixture
        $oldPath = Join-Path (Split-Path -Path $fixture.Path -Parent) 'old-module'
        $null = New-Item -ItemType Directory -Path $oldPath
        $oldMetadata = [ordered]@{
            '$schema' = $script:metadataSchemaId
            moduleDisplayName = 'Previous module'
            moduleDescription = 'Existing metadata.'
            canonicalType = 'Microsoft.Storage/storageAccounts'
            owners = @()
            telemetryIdPrefix = '46d3xbcp.res.aaaaaaa'
            alternativeTelemetryIdPrefixes = @('46d3xbcp.res.bbbbbbb')
        }
        [System.IO.File]::WriteAllText((Join-Path $oldPath 'metadata.json'), ($oldMetadata | ConvertTo-Json))

        $probe = InModuleScope 'Avm.Authoring' -Parameters @{ Target = $fixture.Path; Values = $fixture.InputObject } {
            param($Target, $Values)
            Mock Invoke-WebRequest { throw [System.Net.Http.HttpRequestException]::new('Catalog unavailable.') }
            Mock New-AvmTelemetryIdPrefix { '46d3xbcp.res.123abcd' }
            $warnings = @()

            $created = Initialize-AvmModule -Path $Target -Ecosystem bicep -ModuleType resource `
                -InputObject $Values -Proposed -SkipModuleVersionCheck -WarningVariable warnings 3> $null
            Should -Invoke New-AvmTelemetryIdPrefix -Exactly 1 -ParameterFilter {
                $KnownPrefix -contains '46d3xbcp.res.aaaaaaa' -and
                $KnownPrefix -contains '46d3xbcp.res.bbbbbbb'
            }
            return [pscustomobject]@{ Result = $created; Warnings = $warnings }
        }

        $probe.Result.Metadata.telemetryIdPrefix | Should -BeExactly '46d3xbcp.res.123abcd'
        $probe.Warnings -join ' ' | Should -Match 'cannot be checked against published identifiers'
        @(Get-ChildItem -LiteralPath $fixture.Path -Force).Name | Should -Be @('metadata.json')
    }

    It 'preserves existing metadata byte-for-byte without prompting or catalog lookup' {
        $fixture = New-InitializationFixture
        $fixture.InputObject.telemetryIdPrefix = '46d3xbcp.res.existing'
        $null = Initialize-AvmModule -Path $fixture.Path -Ecosystem bicep -ModuleType resource `
            -InputObject $fixture.InputObject -Proposed -SkipModuleVersionCheck
        $metadataPath = Join-Path $fixture.Path 'metadata.json'
        $before = [System.IO.File]::ReadAllBytes($metadataPath)

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ Target = $fixture.Path } {
            param($Target)
            Mock Read-Host { throw [System.InvalidOperationException]::new('Must not prompt.') }
            Mock Get-AvmCatalogTelemetryPrefix { throw [System.InvalidOperationException]::new('Must not fetch.') }
            $reused = Initialize-AvmModule -Path $Target -Ecosystem bicep -ModuleType resource `
                -InputObject @{ canonicalType = 'bad' } -Proposed -SkipModuleVersionCheck
            Should -Invoke Read-Host -Exactly 0
            Should -Invoke Get-AvmCatalogTelemetryPrefix -Exactly 0
            return $reused
        }

        $result.Changed | Should -BeFalse
        $result.PlannedFiles | Should -HaveCount 0
        [System.IO.File]::ReadAllBytes($metadataPath) | Should -Be $before
    }

    It 'leaves an existing main.bicep and other files unchanged in proposed mode' {
        $fixture = New-InitializationFixture
        $null = New-Item -ItemType Directory -Path $fixture.Path
        $source = Join-Path $fixture.Path 'main.bicep'
        $notes = Join-Path $fixture.Path 'README.md'
        [System.IO.File]::WriteAllText($source, "metadata name = 'Storage Accounts'`nmetadata description = 'Deploys a Storage Account.'`n")
        [System.IO.File]::WriteAllText($notes, "Authored notes.`n")
        $fixture.InputObject.telemetryIdPrefix = '46d3xbcp.res.explicit'
        $beforeSource = [System.IO.File]::ReadAllBytes($source)
        $beforeNotes = [System.IO.File]::ReadAllBytes($notes)

        $result = Initialize-AvmModule -Path $fixture.Path -Ecosystem bicep -ModuleType resource `
            -InputObject $fixture.InputObject -Proposed -SkipModuleVersionCheck

        $result.PlannedFiles | Should -Be @('metadata.json')
        @(Get-ChildItem -LiteralPath $fixture.Path -Force | Sort-Object Name).Name |
            Should -Be @('main.bicep', 'metadata.json', 'README.md')
        [System.IO.File]::ReadAllBytes($source) | Should -Be $beforeSource
        [System.IO.File]::ReadAllBytes($notes) | Should -Be $beforeNotes
    }

    It 'preserves a source prefix and excludes its own published record from collision checks' {
        $fixture = New-InitializationFixture
        $null = New-Item -ItemType Directory -Path $fixture.Path
        $source = Join-Path $fixture.Path 'main.bicep'
        $prefix = '46d3xbcp.res.123abcd'
        [System.IO.File]::WriteAllText($source, @"
metadata name = 'Storage Accounts'
metadata description = 'Deploys a Storage Account.'
resource avmTelemetry 'Microsoft.Resources/deployments@2025-04-01' = {
  name: '$prefix.`${uniqueString(resourceGroup().id)}'
}
"@)

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ Target = $fixture.Path; Values = $fixture.InputObject } {
            param($Target, $Values)
            Mock Get-AvmCatalogTelemetryPrefix { @() }
            Mock New-AvmTelemetryIdPrefix { throw [System.InvalidOperationException]::new('Must preserve source prefix.') }

            $created = Initialize-AvmModuleMetadata -Path $Target -Ecosystem bicep -ModuleType resource `
                -InputObject $Values -UpdateSource -SkipModuleVersionCheck
            Should -Invoke Get-AvmCatalogTelemetryPrefix -Exactly 1 -ParameterFilter {
                $ExcludeBicepModulePath -ceq 'avm/res/storage/storage-account'
            }
            Should -Invoke New-AvmTelemetryIdPrefix -Exactly 0
            return $created
        }

        $result.Metadata.telemetryIdPrefix | Should -BeExactly $prefix
        (Test-AvmModuleMetadata -Path $fixture.Path -Ecosystem bicep -ModuleType resource `
                -CheckSource -SkipModuleVersionCheck).Status | Should -Be 'pass'
    }

    It 'rejects a source prefix reused by another local module before fetching the catalog' {
        $fixture = New-InitializationFixture
        $null = New-Item -ItemType Directory -Path $fixture.Path
        $source = Join-Path $fixture.Path 'main.bicep'
        $prefix = '46d3xbcp.res.123abcd'
        [System.IO.File]::WriteAllText($source, @"
metadata name = 'Storage Accounts'
metadata description = 'Deploys a Storage Account.'
resource avmTelemetry 'Microsoft.Resources/deployments@2025-04-01' = {
  name: '$prefix.`${uniqueString(resourceGroup().id)}'
}
"@)
        $oldPath = Join-Path (Split-Path -Path $fixture.Path -Parent) 'earlier-module'
        $null = New-Item -ItemType Directory -Path $oldPath
        $oldMetadata = [ordered]@{
            '$schema' = $script:metadataSchemaId
            moduleDisplayName = 'Previous module'
            moduleDescription = 'Existing metadata.'
            canonicalType = 'Microsoft.Storage/storageAccounts'
            owners = @()
            telemetryIdPrefix = $prefix
        }
        [System.IO.File]::WriteAllText((Join-Path $oldPath 'metadata.json'), ($oldMetadata | ConvertTo-Json))
        $before = [System.IO.File]::ReadAllBytes($source)

        InModuleScope 'Avm.Authoring' -Parameters @{ Target = $fixture.Path; Values = $fixture.InputObject } {
            param($Target, $Values)
            Mock Get-AvmCatalogTelemetryPrefix { throw [System.InvalidOperationException]::new('Must reject local collision first.') }

            {
                Initialize-AvmModuleMetadata -Path $Target -Ecosystem bicep -ModuleType resource `
                    -InputObject $Values -UpdateSource -SkipModuleVersionCheck
            } | Should -Throw '*already used by another module*'
            Should -Invoke Get-AvmCatalogTelemetryPrefix -Exactly 0
        }
        Test-Path -LiteralPath (Join-Path $fixture.Path 'metadata.json') | Should -BeFalse
        [System.IO.File]::ReadAllBytes($source) | Should -Be $before
    }

    It 'initializes local Terraform metadata without source files or remote operations' {
        $root = Join-Path $TestDrive ('terraform-azure-avm-res-' + [guid]::NewGuid().ToString('N'))
        $metadataInput = @{
            moduleDisplayName = 'Storage Accounts'
            moduleDescription = 'Deploys a Storage Account.'
            canonicalType = 'Microsoft.Storage/storageAccounts'
            telemetryIdPrefix = '46d3xtrf.res.explicit'
            owners = @()
        }

        $result = Initialize-AvmModule -Path $root -Ecosystem terraform -ModuleType resource `
            -InputObject $metadataInput -SkipModuleVersionCheck

        $result.Status | Should -Be 'pass'
        $result.Changed | Should -BeTrue
        $result.PlannedFiles | Should -Be @('metadata.json')
        @(Get-ChildItem -LiteralPath $root -Force).Name | Should -Be @('metadata.json')
        (Test-AvmModuleMetadata -Path $root -Ecosystem terraform -ModuleType resource -SkipModuleVersionCheck).Status |
            Should -Be 'pass'
        (Initialize-AvmModule -Path $root -Ecosystem terraform -ModuleType resource -SkipModuleVersionCheck).Changed |
            Should -BeFalse
    }

    It 'keeps legacy Terraform metadata initialization bound to existing directories' {
        $root = Join-Path $TestDrive ('terraform-azure-avm-res-' + [guid]::NewGuid().ToString('N'))
        { Initialize-AvmModuleMetadata -Path $root -Ecosystem terraform -ModuleType resource -SkipModuleVersionCheck } |
            Should -Throw '*Module directory does not exist*'
        Test-Path -LiteralPath $root | Should -BeFalse
    }

    It 'does not create a Terraform directory under WhatIf and rejects -Proposed' {
        $root = Join-Path $TestDrive ('terraform-azure-avm-res-' + [guid]::NewGuid().ToString('N'))
        $metadataInput = @{
            moduleDisplayName = 'Storage Accounts'
            moduleDescription = 'Deploys a Storage Account.'
            canonicalType = 'Microsoft.Storage/storageAccounts'
            telemetryIdPrefix = '46d3xtrf.res.explicit'
            owners = @()
        }

        $plan = Initialize-AvmModule -Path $root -Ecosystem terraform -ModuleType resource `
            -InputObject $metadataInput -SkipModuleVersionCheck -WhatIf
        $plan.Changed | Should -BeFalse
        $plan.PlannedFiles | Should -Be @('metadata.json')
        Test-Path -LiteralPath $root | Should -BeFalse
        { Initialize-AvmModule -Path $root -Ecosystem terraform -ModuleType resource `
                -InputObject $metadataInput -Proposed -SkipModuleVersionCheck } | Should -Throw '*only supported for Bicep*'
        Test-Path -LiteralPath $root | Should -BeFalse
    }

    It 'dispatches avm init to the local metadata-only Terraform initializer' {
        $root = Join-Path $TestDrive ('terraform-azure-avm-res-' + [guid]::NewGuid().ToString('N'))
        $metadataInput = @{
            moduleDisplayName = 'Storage Accounts'
            moduleDescription = 'Deploys a Storage Account.'
            canonicalType = 'Microsoft.Storage/storageAccounts'
            telemetryIdPrefix = '46d3xtrf.res.explicit'
            owners = @()
        }

        $result = avm -SkipModuleVersionCheck init -Ecosystem terraform -ModuleType resource `
            -Path $root -InputObject $metadataInput --passthru

        $result.Status | Should -Be 'pass'
        @(Get-ChildItem -LiteralPath $root -Force).Name | Should -Be @('metadata.json')
    }
}

Describe 'Component: full local Bicep module initialization' -Tag Component {
    It 'creates a root source, version, changelog, and only the two root e2e tests' {
        $fixture = New-InitializationFixture
        $fixture.InputObject.telemetryIdPrefix = '46d3xbcp.res.123abcd'

        $result = Initialize-AvmModule -Path $fixture.Path -Ecosystem bicep -ModuleType resource `
            -InputObject $fixture.InputObject -SkipModuleVersionCheck

        $result.Status | Should -Be 'pass'
        $result.Changed | Should -BeTrue
        $result.PlannedFiles | Should -Be @(
            'metadata.json', 'main.bicep', 'version.json', 'CHANGELOG.md',
            'tests/e2e/defaults/main.test.bicep', 'tests/e2e/waf-aligned/main.test.bicep'
        )
        $result.Metadata.telemetryIdPrefix | Should -BeExactly '46d3xbcp.res.123abcd'
        @(Get-ChildItem -LiteralPath $fixture.Path -Force | Sort-Object -Property Name).Name | Should -Be @(
            'CHANGELOG.md', 'main.bicep', 'metadata.json', 'tests', 'version.json'
        )
        Test-Path -LiteralPath (Join-Path $fixture.Path 'README.md') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $fixture.Path 'main.json') | Should -BeFalse
        (Get-Content -LiteralPath (Join-Path $fixture.Path 'version.json') -Raw | ConvertFrom-Json).version |
            Should -BeExactly '0.1'
        (Get-Content -LiteralPath (Join-Path $fixture.Path 'CHANGELOG.md') -Raw) |
            Should -Match 'avm/res/storage/storage-account/CHANGELOG.md'
        $source = Get-Content -LiteralPath (Join-Path $fixture.Path 'main.bicep') -Raw
        $source | Should -Match ([regex]::Escape(
                "var telemetryIdPrefix = loadJsonContent('metadata.json', 'telemetryIdPrefix')"))
        $source | Should -Match ([regex]::Escape('${telemetryIdPrefix}.'))
        $source | Should -Not -Match 'avmTelemetryIdPrefix'
        (Test-AvmModuleMetadata -Path $fixture.Path -Ecosystem bicep -ModuleType resource `
                -CheckSource -SkipModuleVersionCheck).Status | Should -Be 'pass'
    }

    It 'completes a metadata-only proposal without changing its metadata or generated prefix' {
        $fixture = New-InitializationFixture
        $fixture.InputObject.telemetryIdPrefix = '46d3xbcp.res.123abcd'
        $null = Initialize-AvmModule -Path $fixture.Path -Ecosystem bicep -ModuleType resource `
            -InputObject $fixture.InputObject -Proposed -SkipModuleVersionCheck
        $metadataPath = Join-Path $fixture.Path 'metadata.json'
        $metadataBytes = [System.IO.File]::ReadAllBytes($metadataPath)

        $probe = InModuleScope Avm.Authoring -Parameters @{ Target = $fixture.Path } {
            param($Target)
            Mock Get-AvmCatalogTelemetryPrefix {
                throw [System.InvalidOperationException]::new('Must not fetch catalog for existing metadata.')
            }
            Mock Read-Host { throw [System.InvalidOperationException]::new('Must not prompt.') }
            $first = Initialize-AvmModule -Path $Target -Ecosystem bicep -ModuleType resource `
                -InputObject @{ moduleDisplayName = 'ignored' } -SkipModuleVersionCheck
            $again = Initialize-AvmModule -Path $Target -Ecosystem bicep -ModuleType resource `
                -SkipModuleVersionCheck
            Should -Invoke Get-AvmCatalogTelemetryPrefix -Exactly 0
            Should -Invoke Read-Host -Exactly 0
            return [pscustomobject]@{ First = $first; Again = $again }
        }
        $probe.First.Changed | Should -BeTrue
        $probe.First.PlannedFiles | Should -Not -Contain 'metadata.json'
        $probe.First.Metadata.telemetryIdPrefix | Should -BeExactly '46d3xbcp.res.123abcd'
        $probe.Again.Changed | Should -BeFalse
        $probe.Again.PlannedFiles | Should -HaveCount 0
        [System.IO.File]::ReadAllBytes($metadataPath) | Should -Be $metadataBytes
    }

    It 'validates and previews root files without creating a module directory' {
        $fixture = New-InitializationFixture
        $fixture.InputObject.telemetryIdPrefix = '46d3xbcp.res.123abcd'
        $result = Initialize-AvmModule -Path $fixture.Path -Ecosystem bicep -ModuleType resource `
            -InputObject $fixture.InputObject -SkipModuleVersionCheck -WhatIf
        $result.Changed | Should -BeFalse
        $result.PlannedFiles | Should -HaveCount 6
        Test-Path -LiteralPath $fixture.Path | Should -BeFalse
    }

    It 'validates scaffold collisions even under WhatIf before creating metadata' {
        $fixture = New-InitializationFixture
        $fixture.InputObject.telemetryIdPrefix = '46d3xbcp.res.123abcd'
        $null = New-Item -ItemType Directory -Path $fixture.Path
        $null = New-Item -ItemType File -Path (Join-Path $fixture.Path 'tests')
        {
            Initialize-AvmModule -Path $fixture.Path -Ecosystem bicep -ModuleType resource `
                -InputObject $fixture.InputObject -SkipModuleVersionCheck -WhatIf
        } | Should -Throw '*Scaffold directory must use exact casing*'
        Test-Path -LiteralPath (Join-Path $fixture.Path 'metadata.json') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $fixture.Path 'main.bicep') | Should -BeFalse
    }

    It 'rejects an existing scaffold directory with the wrong casing before writing' {
        $fixture = New-InitializationFixture
        $fixture.InputObject.telemetryIdPrefix = '46d3xbcp.res.123abcd'
        $null = New-Item -ItemType Directory -Path $fixture.Path
        $wrongPath = Join-Path $fixture.Path 'Tests'
        $null = New-Item -ItemType Directory -Path $wrongPath
        {
            Initialize-AvmModule -Path $fixture.Path -Ecosystem bicep -ModuleType resource `
                -InputObject $fixture.InputObject -SkipModuleVersionCheck
        } | Should -Throw '*Scaffold directory must use exact casing*'
        Test-Path -LiteralPath (Join-Path $fixture.Path 'metadata.json') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $fixture.Path 'main.bicep') | Should -BeFalse
        Test-Path -LiteralPath $wrongPath | Should -BeTrue
    }

    It 'rejects a Bicep module path whose existing directory differs only by case' {
        $fixture = New-InitializationFixture
        $fixture.InputObject.telemetryIdPrefix = '46d3xbcp.res.123abcd'
        $wrongPath = Join-Path (Split-Path $fixture.Path -Parent) 'Storage-Account'
        $null = New-Item -ItemType Directory -Path $wrongPath
        {
            Initialize-AvmModule -Path $fixture.Path -Ecosystem bicep -ModuleType resource `
                -InputObject $fixture.InputObject -SkipModuleVersionCheck
        } | Should -Throw '*Bicep module directory must use exact casing*'
        Test-Path -LiteralPath (Join-Path $wrongPath 'metadata.json') | Should -BeFalse
        Test-Path -LiteralPath $wrongPath | Should -BeTrue
    }

    It 'preserves an independently described source and version while adding only missing scaffold files' {
        $fixture = New-InitializationFixture
        $fixture.InputObject.telemetryIdPrefix = '46d3xbcp.res.123abcd'
        $null = New-Item -ItemType Directory -Path $fixture.Path
        $sourcePath = Join-Path $fixture.Path 'main.bicep'
        $versionPath = Join-Path $fixture.Path 'version.json'
        [System.IO.File]::WriteAllText($sourcePath, "metadata name = 'Authored name'`nmetadata description = 'Authored deployment details.'`n")
        [System.IO.File]::WriteAllText($versionPath, "{`"version`":`"8.3`"}`n")
        $sourceBytes = [System.IO.File]::ReadAllBytes($sourcePath)
        $versionBytes = [System.IO.File]::ReadAllBytes($versionPath)

        $result = Initialize-AvmModule -Path $fixture.Path -Ecosystem bicep -ModuleType resource `
            -InputObject $fixture.InputObject -SkipModuleVersionCheck

        $result.Changed | Should -BeTrue
        $result.PlannedFiles | Should -Be @(
            'metadata.json', 'CHANGELOG.md', 'tests/e2e/defaults/main.test.bicep',
            'tests/e2e/waf-aligned/main.test.bicep'
        )
        [System.IO.File]::ReadAllBytes($sourcePath) | Should -Be $sourceBytes
        [System.IO.File]::ReadAllBytes($versionPath) | Should -Be $versionBytes
        $result.Metadata.moduleDescription | Should -BeExactly 'Deploys a Storage Account.'
        (Test-AvmModuleMetadata -Path $fixture.Path -Ecosystem bicep -ModuleType resource `
                -CheckSource -SkipModuleVersionCheck).Status | Should -Be 'pass'
    }

    It 'rejects missing source metadata literals before scaffolding other files' {
        $fixture = New-InitializationFixture
        $fixture.InputObject.telemetryIdPrefix = '46d3xbcp.res.123abcd'
        $null = New-Item -ItemType Directory -Path $fixture.Path
        $sourcePath = Join-Path $fixture.Path 'main.bicep'
        [System.IO.File]::WriteAllText($sourcePath, "metadata name = 'Authored name'`n")
        $sourceBefore = [System.IO.File]::ReadAllBytes($sourcePath)

        {
            Initialize-AvmModule -Path $fixture.Path -Ecosystem bicep -ModuleType resource `
                -InputObject $fixture.InputObject -SkipModuleVersionCheck
        } | Should -Throw '*main.bicep must declare metadata description*'
        Test-Path -LiteralPath (Join-Path $fixture.Path 'metadata.json') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $fixture.Path 'version.json') | Should -BeFalse
        [System.IO.File]::ReadAllBytes($sourcePath) | Should -Be $sourceBefore
    }

    It 'keeps the single authored source prefix when creating missing metadata without rewriting main.bicep' {
        $fixture = New-InitializationFixture
        $null = New-Item -ItemType Directory -Path $fixture.Path
        $sourcePath = Join-Path $fixture.Path 'main.bicep'
        $prefix = '46d3xbcp.res.123abcd'
        [System.IO.File]::WriteAllText($sourcePath, @"
metadata name = 'Authored name'
metadata description = 'Deploys a Storage Account.'
resource avmTelemetry 'Microsoft.Resources/deployments@2025-04-01' = {
  name: '$prefix.`${uniqueString(resourceGroup().id)}'
}
"@)
        $before = [System.IO.File]::ReadAllBytes($sourcePath)
        $result = InModuleScope Avm.Authoring -Parameters @{ Target = $fixture.Path; Values = $fixture.InputObject } {
            param($Target, $Values)
            Mock Get-AvmCatalogTelemetryPrefix { @() }
            Mock New-AvmTelemetryIdPrefix {
                throw [System.InvalidOperationException]::new('Must preserve authored prefix.')
            }
            Initialize-AvmModule -Path $Target -Ecosystem bicep -ModuleType resource `
                -InputObject $Values -SkipModuleVersionCheck
        }
        $result.Metadata.telemetryIdPrefix | Should -BeExactly $prefix
        $result.PlannedFiles | Should -Not -Contain 'main.bicep'
        [System.IO.File]::ReadAllBytes($sourcePath) | Should -Be $before
    }

    It 'generates metadata for an existing <Form> source without changing it' -TestCases @(
        @{
            Form = 'registry'
            Declaration = "var telemetryIdPrefix = loadJsonContent('metadata.json', 'telemetryIdPrefix')"
            Reference = '${telemetryIdPrefix}'
        }
        @{
            Form = 'legacy'
            Declaration = "var avmTelemetryIdPrefix = loadJsonContent('metadata.json', '$.telemetryIdPrefix')"
            Reference = '${avmTelemetryIdPrefix}'
        }
    ) {
        param($Declaration, $Reference)
        $fixture = New-InitializationFixture
        $null = New-Item -ItemType Directory -Path $fixture.Path
        $sourcePath = Join-Path $fixture.Path 'main.bicep'
        $source = @'
metadata name = 'Authored name'
metadata description = 'Authored deployment details.'
<declaration>
resource avmTelemetry 'Microsoft.Resources/deployments@2025-04-01' = {
  name: '<reference>.${uniqueString(resourceGroup().id)}'
}
'@.Replace('<declaration>', $Declaration).Replace('<reference>', $Reference)
        [System.IO.File]::WriteAllText($sourcePath, $source)
        $before = [System.IO.File]::ReadAllBytes($sourcePath)
        $result = InModuleScope Avm.Authoring -Parameters @{ Target = $fixture.Path; Values = $fixture.InputObject } {
            param($Target, $Values)
            Mock Get-AvmCatalogTelemetryPrefix { @() }
            Mock New-AvmTelemetryIdPrefix { '46d3xbcp.res.123abcd' }
            Initialize-AvmModule -Path $Target -Ecosystem bicep -ModuleType resource `
                -InputObject $Values -SkipModuleVersionCheck
        }
        $result.Metadata.telemetryIdPrefix | Should -BeExactly '46d3xbcp.res.123abcd'
        $result.Metadata.moduleDescription | Should -BeExactly 'Deploys a Storage Account.'
        $result.PlannedFiles | Should -Not -Contain 'main.bicep'
        [System.IO.File]::ReadAllBytes($sourcePath) | Should -Be $before
    }

    It 'rejects a prefix conflicting with existing source before writing metadata or version files' {
        $fixture = New-InitializationFixture
        $fixture.InputObject.telemetryIdPrefix = '46d3xbcp.res.different'
        $null = New-Item -ItemType Directory -Path $fixture.Path
        $sourcePath = Join-Path $fixture.Path 'main.bicep'
        [System.IO.File]::WriteAllText($sourcePath, @"
metadata name = 'Authored name'
metadata description = 'Deploys a Storage Account.'
resource avmTelemetry 'Microsoft.Resources/deployments@2025-04-01' = {
  name: '46d3xbcp.res.123abcd.`${uniqueString(resourceGroup().id)}'
}
"@)
        $before = [System.IO.File]::ReadAllBytes($sourcePath)
        {
            Initialize-AvmModule -Path $fixture.Path -Ecosystem bicep -ModuleType resource `
                -InputObject $fixture.InputObject -SkipModuleVersionCheck
        } | Should -Throw '*conflicts with existing main.bicep prefix*'
        Test-Path -LiteralPath (Join-Path $fixture.Path 'metadata.json') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $fixture.Path 'version.json') | Should -BeFalse
        [System.IO.File]::ReadAllBytes($sourcePath) | Should -Be $before
    }

    It 'scaffolds a telemetry-free utility without generating an unused prefix' {
        $fixture = New-InitializationFixture -Kind utl
        $result = InModuleScope Avm.Authoring -Parameters @{ Target = $fixture.Path; Values = $fixture.InputObject } {
            param($Target, $Values)
            Mock Get-AvmCatalogTelemetryPrefix { throw [System.InvalidOperationException]::new('No telemetry expected.') }
            Initialize-AvmModule -Path $Target -Ecosystem bicep -ModuleType utility `
                -InputObject $Values -SkipModuleVersionCheck
        }
        $result.Metadata.Contains('telemetryIdPrefix') | Should -BeFalse
        (Get-Content -LiteralPath (Join-Path $fixture.Path 'main.bicep') -Raw) |
            Should -Not -Match 'avmTelemetry'
        (Test-AvmModuleMetadata -Path $fixture.Path -Ecosystem bicep -ModuleType utility `
                -CheckSource -SkipModuleVersionCheck).Status | Should -Be 'pass'
    }

    It 'escapes authored metadata literals without altering the JSON values' {
        $fixture = New-InitializationFixture
        $fixture.InputObject.moduleDisplayName = "Owner's storage"
        $fixture.InputObject.moduleDescription = 'Literal ${owner}, a \ path' + "`n" + "Another line's value."
        $fixture.InputObject.telemetryIdPrefix = '46d3xbcp.res.123abcd'
        $result = Initialize-AvmModule -Path $fixture.Path -Ecosystem bicep -ModuleType resource `
            -InputObject $fixture.InputObject -SkipModuleVersionCheck
        $source = Get-Content -LiteralPath (Join-Path $fixture.Path 'main.bicep') -Raw
        $literals = InModuleScope Avm.Authoring -Parameters @{ Source = $source } {
            param($Source)
            Get-AvmBicepMetadataLiteral -Source $Source
        }
        $literals.name | Should -BeExactly $result.Metadata.moduleDisplayName
        $literals.description | Should -BeExactly $result.Metadata.moduleDescription
        (Test-AvmModuleMetadata -Path $fixture.Path -Ecosystem bicep -ModuleType resource `
                -CheckSource -SkipModuleVersionCheck).Status | Should -Be 'pass'
    }

    It 'initializes the missing root and each child through the requested deep target in one call' {
        $fixture = New-InitializationFixture
        $path = Join-Path -Path $fixture.Path -ChildPath 'blob-service' -AdditionalChildPath 'container'
        $fixture.InputObject.telemetryIdPrefix = '46d3xbcp.res.123abcd'
        $parentInput = @{
            moduleDisplayName = 'Blob Services'
            moduleDescription = 'Deploys a blob service.'
            canonicalType = 'Microsoft.Storage/storageAccounts/blobServices'
        }
        $targetInput = @{
            moduleDisplayName = 'Blob Containers'
            moduleDescription = 'Deploys a blob container.'
            canonicalType = 'Microsoft.Storage/storageAccounts/blobServices/containers'
        }

        $result = Initialize-AvmModule -Path $path -Ecosystem bicep -ModuleType resource `
            -ChildModule -InputObject $targetInput `
            -AncestorInputObject @{ '.' = $fixture.InputObject; 'blob-service' = $parentInput } -SkipModuleVersionCheck

        $result.Changed | Should -BeTrue
        $result.PlannedFiles | Should -Be @(
            'metadata.json', 'main.bicep', 'version.json', 'CHANGELOG.md',
            'tests/e2e/defaults/main.test.bicep', 'tests/e2e/waf-aligned/main.test.bicep',
            'blob-service/metadata.json', 'blob-service/main.bicep',
            'blob-service/container/metadata.json', 'blob-service/container/main.bicep'
        )
        $result.Metadata.moduleDisplayName | Should -BeExactly 'Blob Containers'
        $result.Metadata.Contains('owners') | Should -BeFalse
        $result.Metadata.Contains('telemetryIdPrefix') | Should -BeFalse
        foreach ($child in @('blob-service', 'blob-service/container')) {
            $childPath = Join-Path $fixture.Path $child
            Test-Path -LiteralPath (Join-Path $childPath 'version.json') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $childPath 'tests') | Should -BeFalse
            (Test-AvmModuleMetadata -Path $childPath -Ecosystem bicep -ModuleType resource `
                    -ChildModule -CheckSource -SkipModuleVersionCheck).Status | Should -Be 'pass'
        }
        (Test-AvmModuleMetadata -Path $fixture.Path -Ecosystem bicep -ModuleType resource `
                -CheckSource -SkipModuleVersionCheck).Status | Should -Be 'pass'
    }

    It 'leaves deep module directories absent after planning a complete chain under WhatIf' {
        $fixture = New-InitializationFixture
        $fixture.InputObject.telemetryIdPrefix = '46d3xbcp.res.123abcd'
        $path = Join-Path -Path $fixture.Path -ChildPath 'blob-service' -AdditionalChildPath 'container'
        $ancestor = @{
            '.' = $fixture.InputObject
            'blob-service' = @{
                moduleDisplayName = 'Blob Services'
                moduleDescription = 'Deploys a blob service.'
                canonicalType = 'Microsoft.Storage/storageAccounts/blobServices'
            }
        }
        $target = @{
            moduleDisplayName = 'Blob Containers'
            moduleDescription = 'Deploys a blob container.'
            canonicalType = 'Microsoft.Storage/storageAccounts/blobServices/containers'
        }

        $plan = Initialize-AvmModule -Path $path -Ecosystem bicep -ModuleType resource `
            -ChildModule -InputObject $target -AncestorInputObject $ancestor `
            -SkipModuleVersionCheck -WhatIf
        $plan.Changed | Should -BeFalse
        $plan.PlannedFiles | Should -HaveCount 10
        Test-Path -LiteralPath $fixture.Path | Should -BeFalse
    }

    It 'creates a helper child without inventing telemetry or child ownership' {
        $fixture = New-InitializationFixture
        $fixture.InputObject.telemetryIdPrefix = '46d3xbcp.res.123abcd'
        $childPath = Join-Path $fixture.Path 'helper'
        $helper = @{
            moduleDisplayName = 'Helper'
            moduleDescription = 'Provides helper parameters.'
            canonicalType = 'helper'
        }
        $result = Initialize-AvmModule -Path $childPath -Ecosystem bicep -ModuleType resource `
            -ChildModule -InputObject $helper -AncestorInputObject @{ '.' = $fixture.InputObject } `
            -SkipModuleVersionCheck
        $result.Metadata.Contains('telemetryIdPrefix') | Should -BeFalse
        $result.Metadata.Contains('owners') | Should -BeFalse
        (Test-AvmModuleMetadata -Path $childPath -Ecosystem bicep -ModuleType resource `
                -ChildModule -CheckSource -SkipModuleVersionCheck).Status | Should -Be 'pass'
        Test-Path -LiteralPath (Join-Path $childPath 'version.json') | Should -BeFalse
    }

    It 'uses existing ancestors without changing their source, metadata, or prefix' {
        $fixture = New-InitializationFixture
        $fixture.InputObject.telemetryIdPrefix = '46d3xbcp.res.123abcd'
        $null = Initialize-AvmModule -Path $fixture.Path -Ecosystem bicep -ModuleType resource `
            -InputObject $fixture.InputObject -SkipModuleVersionCheck
        $parentPath = Join-Path $fixture.Path 'blob-service'
        $parentInput = @{
            moduleDisplayName = 'Blob Services'
            moduleDescription = 'Deploys a blob service.'
            canonicalType = 'Microsoft.Storage/storageAccounts/blobServices'
        }
        $null = Initialize-AvmModule -Path $parentPath -Ecosystem bicep -ModuleType resource `
            -ChildModule -Proposed -InputObject $parentInput -SkipModuleVersionCheck
        $rootMetadata = [System.IO.File]::ReadAllBytes((Join-Path $fixture.Path 'metadata.json'))
        $rootSource = [System.IO.File]::ReadAllBytes((Join-Path $fixture.Path 'main.bicep'))
        $parentMetadata = [System.IO.File]::ReadAllBytes((Join-Path $parentPath 'metadata.json'))
        $targetInput = @{
            moduleDisplayName = 'Blob Containers'
            moduleDescription = 'Deploys a blob container.'
            canonicalType = 'Microsoft.Storage/storageAccounts/blobServices/containers'
        }
        $targetPath = Join-Path $parentPath 'container'

        $result = Initialize-AvmModule -Path $targetPath -Ecosystem bicep -ModuleType resource `
            -ChildModule -InputObject $targetInput -SkipModuleVersionCheck

        $result.PlannedFiles | Should -Be @(
            'blob-service/main.bicep', 'blob-service/container/metadata.json', 'blob-service/container/main.bicep'
        )
        [System.IO.File]::ReadAllBytes((Join-Path $fixture.Path 'metadata.json')) | Should -Be $rootMetadata
        [System.IO.File]::ReadAllBytes((Join-Path $fixture.Path 'main.bicep')) | Should -Be $rootSource
        [System.IO.File]::ReadAllBytes((Join-Path $parentPath 'metadata.json')) | Should -Be $parentMetadata
        (Initialize-AvmModule -Path $targetPath -Ecosystem bicep -ModuleType resource `
                -ChildModule -SkipModuleVersionCheck).Changed | Should -BeFalse
    }

    It 'names the missing ancestor and fields in noninteractive mode before creating anything' {
        $fixture = New-InitializationFixture
        $path = Join-Path -Path $fixture.Path -ChildPath 'blob-service' -AdditionalChildPath 'container'
        $input = @{
            moduleDisplayName = 'Blob Containers'
            moduleDescription = 'Deploys a blob container.'
            canonicalType = 'Microsoft.Storage/storageAccounts/blobServices/containers'
        }
        InModuleScope Avm.Authoring -Parameters @{ Target = $path; Values = $input } {
            param($Target, $Values)
            Mock Test-AvmInteractiveHost { $false }
            Mock Read-Host { throw [System.InvalidOperationException]::new('Must not prompt in CI.') }
            Mock Get-AvmCatalogTelemetryPrefix { throw [System.InvalidOperationException]::new('Must validate before fetch.') }
            {
                Initialize-AvmModule -Path $Target -Ecosystem bicep -ModuleType resource `
                    -ChildModule -InputObject $Values -SkipModuleVersionCheck
            } | Should -Throw "*ancestor '.'*moduleDisplayName*moduleDescription*canonicalType*owners*"
            Should -Invoke Get-AvmCatalogTelemetryPrefix -Exactly 0
            Should -Invoke Read-Host -Exactly 0
        }
        Test-Path -LiteralPath $fixture.Path | Should -BeFalse
    }

    It 'names a partially specified missing intermediate child and its missing fields' {
        $fixture = New-InitializationFixture
        $fixture.InputObject.telemetryIdPrefix = '46d3xbcp.res.123abcd'
        $targetPath = Join-Path -Path $fixture.Path -ChildPath 'blob-service' -AdditionalChildPath 'container'
        $targetInput = @{
            moduleDisplayName = 'Blob Containers'
            moduleDescription = 'Deploys a blob container.'
            canonicalType = 'Microsoft.Storage/storageAccounts/blobServices/containers'
        }
        InModuleScope Avm.Authoring -Parameters @{
            Target = $targetPath
            Values = $targetInput
            RootInput = $fixture.InputObject
        } {
            param($Target, $Values, $RootInput)
            Mock Test-AvmInteractiveHost { $false }
            {
                Initialize-AvmModule -Path $Target -Ecosystem bicep -ModuleType resource `
                    -ChildModule -InputObject $Values -AncestorInputObject @{
                        '.' = $RootInput
                        'blob-service' = @{ moduleDescription = 'Provided description.' }
                    } -SkipModuleVersionCheck
            } | Should -Throw "*ancestor 'blob-service'*moduleDisplayName*canonicalType*"
        }
        Test-Path -LiteralPath $fixture.Path | Should -BeFalse
    }

    It 'prompts for each missing ancestor field before writing the complete chain' {
        $fixture = New-InitializationFixture
        $path = Join-Path -Path $fixture.Path -ChildPath 'blob-service' -AdditionalChildPath 'container'
        $targetInput = @{
            moduleDisplayName = 'Blob Containers'
            moduleDescription = 'Deploys a blob container.'
            canonicalType = 'Microsoft.Storage/storageAccounts/blobServices/containers'
        }
        $probe = InModuleScope Avm.Authoring -Parameters @{ Target = $path; Values = $targetInput } {
            param($Target, $Values)
            $script:answers = @(
                'Storage Accounts', 'Deploys a Storage Account.', 'Microsoft.Storage/storageAccounts', '',
                'Blob Services', 'Deploys a blob service.', 'Microsoft.Storage/storageAccounts/blobServices'
            )
            $script:answerIndex = 0
            Mock Test-AvmInteractiveHost { $true }
            Mock Read-Host {
                $answer = $script:answers[$script:answerIndex]
                $script:answerIndex++
                return $answer
            }
            Mock Get-AvmCatalogTelemetryPrefix { @() }
            Mock New-AvmTelemetryIdPrefix { '46d3xbcp.res.123abcd' }
            $created = Initialize-AvmModule -Path $Target -Ecosystem bicep -ModuleType resource `
                -ChildModule -InputObject $Values -SkipModuleVersionCheck
            Should -Invoke Read-Host -Exactly 7
            return [pscustomobject]@{ Result = $created; AnswerCount = $script:answerIndex }
        }
        $probe.AnswerCount | Should -Be 7
        $probe.Result.PlannedFiles | Should -HaveCount 10
        $probe.Result.Metadata.Contains('owners') | Should -BeFalse
        (Get-Content -LiteralPath (Join-Path (Split-Path -Path $path -Parent) 'metadata.json') -Raw |
                ConvertFrom-Json).moduleDisplayName | Should -BeExactly 'Blob Services'
    }

    It 'rejects malformed ancestor values before writing an otherwise valid root plan' {
        $fixture = New-InitializationFixture
        $fixture.InputObject.telemetryIdPrefix = '46d3xbcp.res.123abcd'
        $path = Join-Path -Path $fixture.Path -ChildPath 'blob-service' -AdditionalChildPath 'container'
        $targetInput = @{
            moduleDisplayName = 'Blob Containers'
            moduleDescription = 'Deploys a blob container.'
            canonicalType = 'Microsoft.Storage/storageAccounts/blobServices/containers'
        }
        {
            Initialize-AvmModule -Path $path -Ecosystem bicep -ModuleType resource `
                -ChildModule -InputObject $targetInput -AncestorInputObject @{
                    '.' = $fixture.InputObject
                    'blob-service' = @{
                        moduleDisplayName = 'Bad parent'
                        moduleDescription = 'Bad metadata.'
                        canonicalType = 'invalid-type'
                    }
                } -SkipModuleVersionCheck
        } | Should -Throw "*ancestor 'blob-service'*canonicalType*"
        Test-Path -LiteralPath $fixture.Path | Should -BeFalse
    }

    It 'rejects wrong-cased, escaping, and target keys or non-dictionary ancestor data' -TestCases @(
        @{ Key = 'Blob-Service'; Value = @{} }
        @{ Key = '../other-module'; Value = @{} }
        @{ Key = 'blob-service/container'; Value = @{} }
        @{ Key = '.'; Value = 'not a dictionary'; RootOnly = $true }
    ) {
        param($Key, $Value, $RootOnly)
        $fixture = New-InitializationFixture
        $path = if ($RootOnly) { $fixture.Path }
        else { Join-Path -Path $fixture.Path -ChildPath 'blob-service' -AdditionalChildPath 'container' }
        $targetInput = @{ moduleDisplayName = 'Blob Containers' }
        $ancestors = @{ $Key = $Value }
        {
            Initialize-AvmModule -Path $path -Ecosystem bicep -ModuleType resource `
                -ChildModule:(-not $RootOnly) -InputObject $targetInput `
                -AncestorInputObject $ancestors -SkipModuleVersionCheck
        } | Should -Throw '*AncestorInputObject*'
        Test-Path -LiteralPath $fixture.Path | Should -BeFalse
    }

    It 'does not allow ancestor metadata inputs to make Proposed or Terraform initialization recursive' {
        $fixture = New-InitializationFixture
        {
            Initialize-AvmModule -Path $fixture.Path -Ecosystem bicep -ModuleType resource `
                -Proposed -AncestorInputObject @{ '.' = $fixture.InputObject } -SkipModuleVersionCheck
        } | Should -Throw '*only supported for full Bicep child initialization*'
        $terraformPath = Join-Path $TestDrive ('terraform-azure-avm-res-' + [guid]::NewGuid().ToString('N'))
        {
            Initialize-AvmModule -Path $terraformPath -Ecosystem terraform -ModuleType resource `
                -AncestorInputObject @{ '.' = $fixture.InputObject } -SkipModuleVersionCheck
        } | Should -Throw '*only supported for full Bicep child initialization*'
        Test-Path -LiteralPath $fixture.Path | Should -BeFalse
        Test-Path -LiteralPath $terraformPath | Should -BeFalse
    }

    It 'rejects a path whose module kind or child scope disagrees with the command' {
        $fixture = New-InitializationFixture
        {
            Initialize-AvmModule -Path $fixture.Path -Ecosystem bicep -ModuleType utility `
                -InputObject $fixture.InputObject -SkipModuleVersionCheck
        } | Should -Throw '*does not match the Bicep module path*'
        {
            Initialize-AvmModule -Path (Join-Path $fixture.Path 'blob-service') `
                -Ecosystem bicep -ModuleType resource -InputObject $fixture.InputObject -SkipModuleVersionCheck
        } | Should -Throw '*Use -ChildModule only for a nested Bicep module path*'
        Test-Path -LiteralPath $fixture.Path | Should -BeFalse
    }

    It 'rejects repeated prefixes across the planned chain before creating any files' {
        $fixture = New-InitializationFixture
        $child = Join-Path $fixture.Path 'blob-service'
        $null = New-Item -ItemType Directory -Path $child -Force
        [System.IO.File]::WriteAllText((Join-Path $child 'version.json'), "{`"version`":`"0.1`"}`n")
        $childInput = @{
            moduleDisplayName = 'Blob Services'
            moduleDescription = 'Deploys a blob service.'
            canonicalType = 'Microsoft.Storage/storageAccounts/blobServices'
        }
        InModuleScope Avm.Authoring -Parameters @{ Target = $child; RootInput = $fixture.InputObject; Values = $childInput } {
            param($Target, $RootInput, $Values)
            Mock Get-AvmCatalogTelemetryPrefix { @() }
            Mock New-AvmTelemetryIdPrefix { '46d3xbcp.res.123abcd' }
            {
                Initialize-AvmModule -Path $Target -Ecosystem bicep -ModuleType resource -ChildModule `
                    -InputObject $Values -AncestorInputObject @{ '.' = $RootInput } -SkipModuleVersionCheck
            } | Should -Throw '*repeated in the planned Bicep module chain*'
            Should -Invoke New-AvmTelemetryIdPrefix -Exactly 1 -ParameterFilter {
                $KnownPrefix -contains '46d3xbcp.res.123abcd'
            } -Because 'the generated child prefix should avoid the planned root identifier'
        }
        Test-Path -LiteralPath (Join-Path $fixture.Path 'metadata.json') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $child 'metadata.json') | Should -BeFalse
    }

    It 'rolls back every new file and directory when a later root test directory cannot be created' {
        $fixture = New-InitializationFixture
        $fixture.InputObject.telemetryIdPrefix = '46d3xbcp.res.123abcd'
        InModuleScope Avm.Authoring -Parameters @{ Target = $fixture.Path; Values = $fixture.InputObject } {
            param($Target, $Values)
            Mock New-Item {
                if ((Split-Path -Path $Path -Leaf) -eq 'waf-aligned') {
                    throw [System.IO.IOException]::new('Simulated late scaffold failure.')
                }
                [System.IO.Directory]::CreateDirectory($Path)
            } -ParameterFilter { $ItemType -eq 'Directory' }
            {
                Initialize-AvmModule -Path $Target -Ecosystem bicep -ModuleType resource `
                    -InputObject $Values -SkipModuleVersionCheck
            } | Should -Throw '*Simulated late scaffold failure*'
        }
        Test-Path -LiteralPath $fixture.Path | Should -BeFalse
        Test-Path -LiteralPath (Split-Path -Path $fixture.Path -Parent) | Should -BeTrue
    }

    It 'rolls back root and intermediate files if creation fails at the final child' {
        $fixture = New-InitializationFixture
        $fixture.InputObject.telemetryIdPrefix = '46d3xbcp.res.123abcd'
        $path = Join-Path -Path $fixture.Path -ChildPath 'blob-service' -AdditionalChildPath 'container'
        $parentInput = @{
            moduleDisplayName = 'Blob Services'
            moduleDescription = 'Deploys a blob service.'
            canonicalType = 'Microsoft.Storage/storageAccounts/blobServices'
        }
        $targetInput = @{
            moduleDisplayName = 'Blob Containers'
            moduleDescription = 'Deploys a blob container.'
            canonicalType = 'Microsoft.Storage/storageAccounts/blobServices/containers'
        }
        InModuleScope Avm.Authoring -Parameters @{
            Target = $path
            RootInput = $fixture.InputObject
            ParentInput = $parentInput
            Values = $targetInput
        } {
            param($Target, $RootInput, $ParentInput, $Values)
            Mock New-Item {
                if ((Split-Path -Path $Path -Leaf) -eq 'container') {
                    throw [System.IO.IOException]::new('Simulated child directory failure.')
                }
                [System.IO.Directory]::CreateDirectory($Path)
            } -ParameterFilter { $ItemType -eq 'Directory' }
            {
                Initialize-AvmModule -Path $Target -Ecosystem bicep -ModuleType resource -ChildModule `
                    -InputObject $Values -AncestorInputObject @{
                        '.' = $RootInput
                        'blob-service' = $ParentInput
                    } -SkipModuleVersionCheck
            } | Should -Throw '*Simulated child directory failure*'
        }
        Test-Path -LiteralPath $fixture.Path | Should -BeFalse
        Test-Path -LiteralPath (Split-Path -Path $fixture.Path -Parent) | Should -BeTrue
    }

    It 'dispatches avm init to full local Bicep scaffolding' {
        $fixture = New-InitializationFixture
        $fixture.InputObject.telemetryIdPrefix = '46d3xbcp.res.123abcd'
        $result = avm -SkipModuleVersionCheck init -Ecosystem bicep -ModuleType resource `
            -Path $fixture.Path -InputObject $fixture.InputObject --passthru
        $result.Changed | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $fixture.Path 'main.bicep')) | Should -BeTrue
    }
}
