#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    & (Join-Path $PSScriptRoot '..' '..' '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $moduleRoot 'Avm.Authoring.psd1')
    & (Get-Module Avm.Authoring) {
        function script:Get-AzKeyVaultSecret {
            [CmdletBinding()]
            param($VaultName, $Name)
            throw 'Unexpected Key Vault call.'
        }
        function script:Get-AzResourceProvider {
            [CmdletBinding()]
            param($ProviderNamespace)
            throw 'Unexpected provider call.'
        }
        function script:Get-AzLocation {
            [CmdletBinding()]
            param()
            throw 'Unexpected location call.'
        }
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Bicep workflow CI parameter inputs' {
    It 'retains authored keys and count and resolves aliases without regard to case' {
        InModuleScope Avm.Authoring {
            $actual = Get-AvmBicepCiParameter -TemplateParameters @{
                keys = @{ type = 'array' }; count = @{ type = 'int' }
                storageName = @{ type = 'string' }; literal_name = @{ type = 'string' }
            } -Variables @{
                CI_KEYS = '["first"]'; CI_COUNT = '4'; ci_STORAGE_NAME = 'storage'
                CI__literal_name = 'literal'; unrelated = 'ignored'
            }
            $actual.psbase.Count | Should -Be 4
            ($actual['keys'] -is [array]) | Should -BeTrue
            $actual['keys'].Count | Should -Be 1
            $actual['keys'][0] | Should -Be 'first'
            $actual['count'] | Should -Be 4
            $actual['storageName'] | Should -Be 'storage'
            $actual['literal_name'] | Should -Be 'literal'
        }
    }

    It 'gives secrets precedence before conversion and CI_ precedence within either source' {
        InModuleScope Avm.Authoring {
            Mock Write-AvmLog {}
            $actual = Get-AvmBicepCiParameter -TemplateParameters @{
                count = @{ type = 'int' }; choice = @{ type = 'string' }
            } -Variables @{
                CI_COUNT = 'invalid but superseded'
                CI_CHOICE = 'readable variable'
                CI__choice = 'literal variable'
            } -Secrets @{
                CI_COUNT = '7'; CI_CHOICE = 'readable secret'; CI__choice = 'literal secret'
            }
            $actual['count'] | Should -Be 7
            $actual['choice'] | Should -Be 'readable secret'
            Should -Invoke Write-AvmLog -Exactly 2 -ParameterFilter { $Level -eq 'Warning' }
        }
    }

    It 'rejects ambiguous winning aliases even when a later source overrides them' {
        InModuleScope Avm.Authoring {
            { Get-AvmBicepCiParameter -TemplateParameters @{ name = @{ type = 'string' } } `
                    -Variables @{ CI_N_AME = 'one'; CI_NAME = 'two' } -Secrets @{ CI_NAME = 'three' } } |
                Should -Throw -ExpectedMessage '*Multiple CI variables*'
        }
    }

    It 'does not expose an invalid value in the error for <Type>' -ForEach @(
        @{ Type = 'int'; Value = 'do-not-print-this' }
        @{ Type = 'bool'; Value = '"do-not-print-this"' }
        @{ Type = 'array'; Value = '{"secret":"do-not-print-this"}' }
        @{ Type = 'object'; Value = '["do-not-print-this"]' }
        @{ Type = 'secureObject'; Value = '"do-not-print-this"' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ T = $Type; V = $Value } {
            param($T, $V)
            Mock Write-AvmLog {}
            $failure = $null
            try {
                $null = Get-AvmBicepCiParameter -TemplateParameters @{ input = @{ type = $T } } `
                    -Secrets @{ CI_INPUT = $V }
            }
            catch { $failure = $_ }
            $failure | Should -Not -BeNullOrEmpty
            $failure.Exception.Message | Should -BeLike '*CI parameter*'
            $failure.Exception.Message | Should -Not -Match 'do-not-print-this'
        }
    }

    It 'retains empty arrays, nested arrays, objects, booleans and 64-bit integers' {
        InModuleScope Avm.Authoring {
            $actual = Get-AvmBicepCiParameter -TemplateParameters @{
                empty = @{ type = 'array' }; nested = @{ type = 'array' }
                data = @{ type = 'object' }; enabled = @{ type = 'bool' }
                count = @{ type = 'int' }; secureData = @{ type = 'secureObject' }
            } -Variables @{
                CI_EMPTY = '[]'; CI_NESTED = '[[1]]'; CI_DATA = '{"keys":"value"}'
                CI_ENABLED = 'false'; CI_COUNT = '2147483648'; CI_SECURE_DATA = '{"value":"private"}'
            }
            ($actual['empty'] -is [array]) | Should -BeTrue
            $actual['empty'].Count | Should -Be 0
            ($actual['nested'][0] -is [array]) | Should -BeTrue
            $actual['nested'][0][0] | Should -Be 1
            $actual['data']['keys'] | Should -Be 'value'
            $actual['enabled'] | Should -BeFalse
            $actual['count'] | Should -BeOfType [long]
            $actual['secureData']['value'] | Should -Be 'private'
        }
    }

    It 'resolves referenced secure types and preserves empty secure strings' {
        InModuleScope Avm.Authoring {
            $actual = Get-AvmBicepCiParameter -TemplateParameters @{
                password = @{ '$ref' = '#/definitions/outer' }
                blank = @{ type = 'secureString' }
            } -TemplateDefinitions @{
                outer = @{ '$ref' = '#/definitions/a~1b~0c' }
                'a/b~c' = @{ type = 'secureString' }
            } -Secrets @{ CI_PASSWORD = 'private'; CI_BLANK = '' }
            $actual['password'] | Should -BeOfType [securestring]
            $actual['password'].Length | Should -Be 7
            $actual['blank'] | Should -BeOfType [securestring]
            $actual['blank'].Length | Should -Be 0
        }
    }

    It 'rejects an unsupported, missing or circular type reference: <Reference>' -ForEach @(
        @{ Reference = 'https://example.invalid/definition' }
        @{ Reference = '#/definitions/missing' }
        @{ Reference = '#/definitions/cycle' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Reference = $Reference } {
            param($Reference)
            { Get-AvmBicepCiParameter -TemplateParameters @{ name = @{ '$ref' = $Reference } } `
                    -TemplateDefinitions @{ cycle = @{ '$ref' = '#/definitions/cycle' } } `
                    -Variables @{ CI_NAME = 'private' } } | Should -Throw -ExpectedMessage '*reference*'
        }
    }

    It 'rejects case-colliding parameter names' {
        InModuleScope Avm.Authoring {
            $parameters = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
            $parameters.Add('name', @{ type = 'string' })
            $parameters.Add('NAME', @{ type = 'string' })
            { Get-AvmBicepCiParameter -TemplateParameters $parameters } |
                Should -Throw -ExpectedMessage '*ignoring case*'
        }
    }

    It 'excludes the reserved vault selector and fills only absent parameters from the legacy vault' {
        InModuleScope Avm.Authoring {
            $script:vaultValue = [securestring]::new()
            Mock Write-AvmLog {}
            Mock Get-AzKeyVaultSecret {
                if (-not $Name) {
                    return @(
                        @{ Name = 'CI-present' }, @{ Name = 'CI-literal_name' },
                        @{ Name = 'CI-ignored' }, @{ Name = 'unrelated' }
                    )
                }
                return @{ SecretValue = $script:vaultValue }
            }
            $actual = Get-AvmBicepCiParameter -TemplateParameters @{
                present = @{ type = 'string' }; literal_name = @{ type = 'secureString' }
                keyVaultName = @{ type = 'string' }
            } -Variables @{ CI_PRESENT = 'configured'; CI_KEY_VAULT_NAME = 'selector' } -KeyVaultName 'legacy'
            $actual['present'] | Should -Be 'configured'
            $actual['literal_name'] | Should -BeOfType [securestring]
            $actual.ContainsKey('keyVaultName') | Should -BeFalse
            Should -Invoke Get-AzKeyVaultSecret -Exactly 1 -ParameterFilter { $Name -eq 'CI-literal_name' }
            Should -Invoke Get-AzKeyVaultSecret -Exactly 2
        }
    }

    It 'does not query the legacy vault once all parameters are configured' {
        InModuleScope Avm.Authoring {
            Mock Get-AzKeyVaultSecret { throw 'Unexpected vault access.' }
            $null = Get-AvmBicepCiParameter -TemplateParameters @{ name = @{ type = 'string' } } `
                -Variables @{ CI_NAME = 'value' } -KeyVaultName 'legacy'
            Should -Invoke Get-AzKeyVaultSecret -Exactly 0
        }
    }
}

Describe 'Bicep workflow subscription pool' {
    It 'accepts a legacy fallback subscription without imposing a 28-subscription pool' {
        InModuleScope Avm.Authoring {
            $id = '00000000-0000-0000-0000-000000000001'
            (Select-AvmBicepWorkflowSubscription -FallbackSubscriptionId $id -CaseIndex 99).SubscriptionId |
                Should -Be $id
        }
    }

    It 'uses a shared integer seed for a stable balanced pool independent of JSON ordering' {
        InModuleScope Avm.Authoring {
            $entries = @(1..4 | ForEach-Object {
                    @{ id = ('00000000-0000-0000-0000-{0:D12}' -f $_); name = "test-$_" }
                })
            $pool = ConvertTo-Json -InputObject $entries -Compress
            $reversed = ConvertTo-Json -InputObject @($entries[3..0]) -Compress
            $selected = @(0..7 | ForEach-Object {
                    (Select-AvmBicepWorkflowSubscription -PoolJson $pool -RandomSeed 123 -CaseIndex $_).SubscriptionId
                })
            @($selected | Select-Object -Unique).Count | Should -Be 4
            ($selected[0..3] -join ',') | Should -Be ($selected[4..7] -join ',')
            foreach ($index in 0..3) {
                (Select-AvmBicepWorkflowSubscription -PoolJson $reversed -RandomSeed 123 -CaseIndex $index).SubscriptionId |
                    Should -Be $selected[$index]
            }
        }
    }

    It 'rejects invalid pools without falling back to another subscription: <Label>' -ForEach @(
        @{ Label = 'not JSON'; Json = 'broken' }
        @{ Label = 'object'; Json = '{}' }
        @{ Label = 'empty'; Json = '[]' }
        @{ Label = 'empty GUID'; Json = '[{"id":"00000000-0000-0000-0000-000000000000","name":"test"}]' }
        @{ Label = 'missing name'; Json = '[{"id":"00000000-0000-0000-0000-000000000001"}]' }
        @{ Label = 'duplicate'; Json = '[{"id":"00000000-0000-0000-0000-000000000001","name":"a"},{"id":"00000000-0000-0000-0000-000000000001","name":"b"}]' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Json = $Json } {
            param($Json)
            { Select-AvmBicepWorkflowSubscription -PoolJson $Json `
                    -FallbackSubscriptionId '00000000-0000-0000-0000-000000000002' } | Should -Throw
        }
    }
}

Describe 'Bicep workflow resource location selection' {
    It 'queries the canonical provider explicitly and uses only supported allowed recommended paired regions' {
        InModuleScope Avm.Authoring {
            Mock Get-AzResourceProvider {
                @{ ResourceTypes = @(@{
                            ResourceTypeName = 'storageAccounts'
                            Locations = @('East US', 'West Europe', 'Central US', 'Korea Central', 'Sweden Central')
                        }) }
            }
            Mock Get-AzLocation {
                @(
                    @{ Location = 'eastus'; DisplayName = 'East US'; PairedRegion = '{}'; RegionCategory = 'Recommended' }
                    @{ Location = 'westeurope'; DisplayName = 'West Europe'; PairedRegion = 'North Europe'; RegionCategory = 'Recommended' }
                    @{ Location = 'centralus'; DisplayName = 'Central US'; PairedRegion = 'East US'; RegionCategory = 'Recommended' }
                    @{ Location = 'koreacentral'; DisplayName = 'Korea Central'; PairedRegion = 'Korea South'; RegionCategory = 'Other' }
                    @{ Location = 'swedencentral'; DisplayName = 'Sweden Central'; PairedRegion = 'Sweden South'; RegionCategory = 'Recommended' }
                )
            }
            $actual = Get-AvmBicepResourceLocation -ResourceType 'Microsoft.Storage/storageAccounts' `
                -MetadataLocation 'westus' -UnavailableRegions 'Central US'
            $actual.Location | Should -Be 'swedencentral'
            $actual.IsGlobal | Should -BeFalse
            Should -Invoke Get-AzResourceProvider -Exactly 1 -ParameterFilter { $ProviderNamespace -eq 'Microsoft.Storage' }
        }
    }

    It 'uses the fixed metadata location only for explicit global availability' {
        InModuleScope Avm.Authoring {
            Mock Get-AzResourceProvider {
                @{ ResourceTypes = @(@{ ResourceTypeName = 'roleDefinitions'; Locations = @('Global') }) }
            }
            Mock Get-AzLocation { throw 'Global resources must not select another region.' }
            $actual = Get-AvmBicepResourceLocation -ResourceType 'Microsoft.Authorization/roleDefinitions' `
                -MetadataLocation 'West US'
            $actual.Location | Should -Be 'westus'
            $actual.IsGlobal | Should -BeTrue
            Should -Invoke Get-AzLocation -Exactly 0
        }
    }

    It 'rejects absent provider location metadata rather than treating it as global' {
        InModuleScope Avm.Authoring {
            Mock Get-AzResourceProvider { @{ ResourceTypes = @() } }
            { Get-AvmBicepResourceLocation -ResourceType 'Microsoft.Storage/storageAccounts' -MetadataLocation 'westus' } |
                Should -Throw -ExpectedMessage '*No location metadata*'
        }
    }

    It 'excludes failed and forbidden pattern-module regions and rejects exhausted candidates' {
        InModuleScope Avm.Authoring {
            (Get-AvmBicepResourceLocation -MetadataLocation 'westus' `
                    -AllowedRegions @('centralus', 'westeurope', 'swedencentral') `
                    -UnavailableRegions @('swedencentral')).Location | Should -Be 'centralus'
            { Get-AvmBicepResourceLocation -MetadataLocation 'westus' -AllowedRegions @('westeurope') } |
                Should -Throw -ExpectedMessage '*No supported*'
        }
    }
}

Describe 'Bicep workflow regional validation classification' {
    It 'accepts only wholly regional nested errors: <Label>' -ForEach @(
        @{ Label = 'capacity'; Code = 'AllocationFailed'; Message = 'Allocation capacity unavailable in this region.'; Expected = $true }
        @{ Label = 'zonal'; Code = 'ZonalAllocationFailed'; Message = 'No capacity in the requested zone.'; Expected = $true }
        @{ Label = 'SKU'; Code = 'SkuNotAvailable'; Message = 'This SKU is not available in the location.'; Expected = $true }
        @{ Label = 'ineligible'; Code = 'RequestDisallowedByAzure'; Message = 'See https://aka.ms/locationineligible.'; Expected = $true }
        @{ Label = 'unrelated policy'; Code = 'RequestDisallowedByAzure'; Message = 'Denied by policy.'; Expected = $false }
        @{ Label = 'misleading URL'; Code = 'RequestDisallowedByAzure'; Message = 'https://aka.ms/locationineligible-other'; Expected = $false }
        @{ Label = 'unrelated capacity'; Code = 'AllocationFailed'; Message = 'Subscription quota exceeded.'; Expected = $false }
        @{ Label = 'authorization'; Code = 'AuthorizationFailed'; Message = 'Capacity failure in this region.'; Expected = $false }
        @{ Label = 'unknown'; Code = 'Unknown'; Message = 'No capacity in this region.'; Expected = $false }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ C = $Code; M = $Message; Expected = $Expected } {
            param($C, $M, $Expected)
            $node = @{ error = @{ code = 'InvalidTemplateDeployment'; details = @(@{ code = $C; message = $M }) } }
            (Test-AvmBicepRegionalErrorNode -Node $node) | Should -Be $Expected
        }
    }

    It 'rejects mixed, empty, malformed and cyclic error trees' {
        InModuleScope Avm.Authoring {
            $regional = @{ code = 'AllocationFailed'; message = 'No capacity in this region.' }
            (Test-AvmBicepRegionalErrorNode -Node @($regional, @{ code = 'AuthorizationFailed' })) | Should -BeFalse
            (Test-AvmBicepRegionalErrorNode -Node @()) | Should -BeFalse
            (Test-AvmBicepRegionalErrorNode -Node @{ code = 'DeploymentFailed'; details = $regional }) | Should -BeFalse
            $cycle = @{ code = 'DeploymentFailed' }
            $cycle.details = @($cycle)
            (Test-AvmBicepRegionalErrorNode -Node $cycle) | Should -BeFalse
        }
    }

    It 'retains singleton native Details collections and rejects transport or authentication errors' {
        InModuleScope Avm.Authoring {
            $body = @([pscustomobject]@{
                    Code = 'InvalidTemplateDeployment'
                    Details = @([pscustomobject]@{ Code = 'AllocationFailed'; Message = 'No capacity in this region.' })
                })
            $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new('Validation failed.'), 'AvmBicepTemplateValidationFailed',
                [System.Management.Automation.ErrorCategory]::InvalidResult, $body)
            (Test-AvmBicepRegionalValidationError -ErrorRecord $errorRecord) | Should -BeTrue
            $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                [System.Net.Http.HttpRequestException]::new('Transport failed.'), 'AvmBicepTemplateValidationFailed',
                [System.Management.Automation.ErrorCategory]::InvalidResult, $body)
            (Test-AvmBicepRegionalValidationError -ErrorRecord $errorRecord) | Should -BeFalse
            $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new('Authorization failed.'), 'AvmBicepTemplateValidationFailed',
                [System.Management.Automation.ErrorCategory]::PermissionDenied, $body)
            (Test-AvmBicepRegionalValidationError -ErrorRecord $errorRecord) | Should -BeFalse
        }
    }
}

Describe 'Bicep workflow deployment preflight rejection' {
    It 'accepts the exact attempted name from a top-level native message or JSON response: <Format>' -ForEach @(
        @{ Format = 'native' }, @{ Format = 'json' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Format = $Format } {
            param($Format)
            $message = "The template deployment 'attempt-1' is not valid according to the validation procedure. Resource reported preflight validation errors."
            $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new("10:20:30 - Error: Code=InvalidTemplateDeployment; Message=$message"),
                'NativeDeploymentError', [System.Management.Automation.ErrorCategory]::InvalidResult, $null)
            if ($Format -eq 'json') {
                $errorRecord.ErrorDetails = [System.Management.Automation.ErrorDetails]::new(
                    (ConvertTo-Json -InputObject @{ error = @{ code = 'InvalidTemplateDeployment'; message = $message } }))
            }
            (Test-AvmBicepDeploymentPreflightRejection -ErrorRecord $errorRecord -DeploymentName 'attempt-1') | Should -BeTrue
            (Test-AvmBicepDeploymentPreflightRejection -ErrorRecord $errorRecord -DeploymentName 'another') | Should -BeFalse
        }
    }

    It 'never interprets nested hints or ambiguous transport outcomes as preflight rejection' {
        InModuleScope Avm.Authoring {
            $message = "The template deployment 'attempt-1' is not valid according to the validation procedure. Resource reported preflight validation errors."
            $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                [System.Net.Http.HttpRequestException]::new("Error: Code=InvalidTemplateDeployment; Message=$message"),
                'TransportError', [System.Management.Automation.ErrorCategory]::InvalidResult, $null)
            (Test-AvmBicepDeploymentPreflightRejection -ErrorRecord $errorRecord -DeploymentName 'attempt-1') | Should -BeFalse
            $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new("Something else: Error: Code=InvalidTemplateDeployment; Message=$message"),
                'NativeDeploymentError', [System.Management.Automation.ErrorCategory]::InvalidResult, $null)
            (Test-AvmBicepDeploymentPreflightRejection -ErrorRecord $errorRecord -DeploymentName 'attempt-1') | Should -BeFalse
        }
    }
}
