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
