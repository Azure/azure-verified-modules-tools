#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmBicepDocsCompiledParameter' {
    It 'indexes array and dictionary union variants with compiled descriptions and en-US enum order' {
        $template = @{
            parameters = @{
                config = @{ '$ref' = '#/definitions/configType' }
                configs = @{ type = 'array'; items = @{ '$ref' = '#/definitions/configType' } }
                aliased = @{ '$ref' = '#/definitions/aliasedType' }
                arrayAliased = @{ type = 'array'; items = @{ '$ref' = '#/definitions/aliasedType' } }
                pooled = @{ type = 'array'; items = @{ '$ref' = '#/definitions/poolType' } }
                poolMap = @{ type = 'object'; additionalProperties = @{
                        '$ref' = '#/definitions/poolType'
                    }
                }
                nullableMap = @{
                    type                 = 'object'
                    nullable             = $true
                    additionalProperties = @{ type = 'string' }
                }
                vpnTypes = @{
                    type  = 'array'
                    items = @{ type = 'string'; allowedValues = @('AAD', 'Certificate') }
                }
                computeTypes = @{
                    type  = 'array'
                    items = @{ '$ref' = '#/definitions/computeType' }
                }
                resources = @{
                    type       = 'object'
                    properties = @{
                        limits = @{ '$ref' = '#/definitions/resourceLimits' }
                    }
                }
                database = @{
                    type       = 'object'
                    properties = @{
                        port = @{ type = 'int'; nullable = $true; minValue = 10000; maxValue = 10000 }
                    }
                }
                derivedModel = @{
                    type     = 'object'
                    metadata = @{ '__bicep_resource_derived_type!' = 'Microsoft.Example/models' }
                }
                derivedWithChildren = @{
                    type       = 'object'
                    metadata   = @{ '__bicep_resource_derived_type!' = 'Microsoft.Example/models' }
                    properties = @{ child = @{ type = 'string' } }
                }
                constrainedPriority = @{ type = 'int'; minValue = 0; maxValue = 1000 }
                tupleRules = @{
                    type        = 'array'
                    prefixItems = @(@{ type = 'object'; properties = @{ name = @{ type = 'string' } } })
                    items       = $false
                }
                alert = @{ '$ref' = '#/definitions/alertType' }
                secureAlert = @{ '$ref' = '#/definitions/secureAlertType' }
                free = @{ nullable = $true }
                image = @{ type = 'string'; metadata = @{
                        example = @('mcr.microsoft.com/k8se/quickstart-jobs:latest',
                            'docker.io/library/image:latest')
                    }
                }
                protectedSettings = @{
                    type       = 'secureObject'
                    properties = @{ commandToExecute = @{ type = 'string' } }
                }
                objectExample = @{
                    type     = 'object'
                    metadata = @{ example = [ordered]@{
                            Environment = 'Production'
                            Owner       = 'TeamName'
                        }
                    }
                }
                tags = @{ type = 'object'; metadata = @{ example = "  {`n    key: 'value'`n  }`n" } }
                resourceEnum = @{
                    type = 'string'
                    metadata = @{ '__bicep_resource_derived_type!' = 'Microsoft.Web/sites' }
                }
                outbound = @{ type = 'object'; additionalProperties = @{
                        '$ref' = '#/definitions/configType'
                    }
                }
            }
            definitions = @{
                computeType = @{
                    type          = 'string'
                    allowedValues = @('azure-container-app', 'azure-container-instance')
                }
                resourceLimits = @{
                    type          = 'object'
                    allowedValues = @(
                        @{ cpu = '0.25'; memory = '0.5Gi' },
                        @{ cpu = '0.5'; memory = '1Gi' }
                    )
                }
                aliasedType = @{ '$ref' = '#/definitions/deepType' }
                deepType = @{
                    type       = 'object'
                    properties = @{ innerValue = @{ type = 'string' } }
                }
                poolType = @{
                    type       = 'object'
                    properties = @{ autoScale = @{ '$ref' = '#/definitions/aliasedType' } }
                }
                alertType = @{
                    type          = 'object'
                    discriminator = @{
                        propertyName = 'kind'
                        mapping      = [ordered]@{
                            Webtest  = @{ '$ref' = '#/definitions/webtestType' }
                            Single   = @{ '$ref' = '#/definitions/singleType' }
                            Multiple = @{ '$ref' = '#/definitions/multipleType' }
                        }
                    }
                }
                secureAlertType = @{
                    type          = 'secureObject'
                    discriminator = @{
                        propertyName = 'kind'
                        mapping      = [ordered]@{
                            Webtest = @{ '$ref' = '#/definitions/webtestType' }
                            Single  = @{ '$ref' = '#/definitions/singleType' }
                        }
                    }
                }
                webtestType = @{ type = 'object' }
                singleType = @{ type = 'object' }
                multipleType = @{ type = 'object' }
                configType = @{
                    type          = 'object'
                    discriminator = @{
                        propertyName = 'kind'
                        mapping      = @{
                            premium = @{ '$ref' = '#/definitions/premiumType' }
                        }
                    }
                }
                premiumType = @{
                    type       = 'object'
                    metadata   = @{ description = 'The type of a premium configuration.' }
                    properties = @{
                        kind = @{ type = 'string'; allowedValues = @('premium') }
                        disk = @{
                            type          = 'string'
                            allowedValues = @('PremiumV2_LRS', 'Premium_LRS', 'Premium_ZRS')
                        }
                        retention = @{ type = 'int'; allowedValues = @(120, 30, 60) }
                        apiMode = @{
                            type     = 'string'
                            metadata = @{ '__bicep_resource_derived_type!' = 'Microsoft.Web/sites' }
                        }
                    }
                }
            }
        }
        $details = InModuleScope 'Avm.Authoring' -Parameters @{ T = $template } {
            param($T)
            Get-AvmBicepDocsCompiledParameter -Template $T -SourcePath 'synthetic/main.json'
        }
        $details['configs'].Type | Should -BeExactly 'array'
        $details['config'].Type | Should -BeExactly 'object'
        $details['config'].LegacyType | Should -BeNullOrEmpty
        $details['config'].DocumentChildren | Should -BeTrue
        $details['aliased'].Type | Should -BeExactly 'object'
        $details['aliased'].LegacyType | Should -BeExactly ''
        $details['aliased'].DocumentChildren | Should -BeFalse
        $details.ContainsKey('aliased.innerValue') | Should -BeTrue
        $details['arrayAliased'].Type | Should -BeExactly 'array'
        $details['arrayAliased'].LegacyType | Should -BeNullOrEmpty
        $details['arrayAliased'].DocumentChildren | Should -BeFalse
        $details['pooled.autoScale'].LegacyType | Should -BeExactly ''
        $details['pooled.autoScale'].DocumentChildren | Should -BeFalse
        $details.ContainsKey('pooled.autoScale.innerValue') | Should -BeTrue
        $details['poolMap.>Any_other_property<.autoScale'].LegacyType | Should -BeExactly ''
        $details['poolMap.>Any_other_property<.autoScale'].DocumentChildren |
            Should -BeFalse
        $details['nullableMap'].Required | Should -BeFalse
        $details['nullableMap.>Any_other_property<'].Required | Should -BeTrue
        $details['vpnTypes'].AllowedValues.Count | Should -Be 0
        $details['computeTypes'].AllowedValues | Should -Be @(
            'azure-container-app', 'azure-container-instance')
        $details['computeTypes'].AllowedValuesFromReference | Should -BeTrue
        $details['resources.limits'].AllowedValues.Count | Should -Be 2
        $details['resources.limits'].AllowedValuesFromReference | Should -BeTrue
        $details['resources.limits'].AllowedValues[0].cpu | Should -BeExactly '0.25'
        $details['database.port'].MinValue | Should -Be 10000
        $details['database.port'].MaxValue | Should -Be 10000
        $details['derivedModel'].IsResourceDerived | Should -BeTrue
        $details['derivedModel'].DocumentChildren | Should -BeFalse
        $details['derivedWithChildren'].DocumentChildren | Should -BeTrue
        $details['constrainedPriority'].MinValue | Should -Be 0
        $details['constrainedPriority'].MaxValue | Should -Be 1000
        $details['tupleRules'].DocumentChildren | Should -BeFalse
        $details['alert'].VariantOrder | Should -Be @('Webtest', 'Single', 'Multiple')
        $details['secureAlert'].Type | Should -BeExactly 'secureObject'
        $details['secureAlert'].DocumentChildren | Should -BeTrue
        $details['secureAlert'].HasDiscriminator | Should -BeTrue
        $details['config'].HasDiscriminator | Should -BeTrue
        $details['configs'].HasDiscriminator | Should -BeTrue
        $details['free'].Type | Should -BeExactly ''
        $details['protectedSettings'].Type | Should -BeExactly 'secureObject'
        $details['protectedSettings'].DocumentChildren | Should -BeFalse
        $details['objectExample'].Example -is [System.Collections.IDictionary] | Should -BeTrue
        $details['objectExample'].Example['Environment'] | Should -BeExactly 'Production'
        $details['tags'].Example | Should -BeExactly "  {`n    key: 'value'`n  }`n"
        $details['image'].Example | Should -Be @(
            'mcr.microsoft.com/k8se/quickstart-jobs:latest', 'docker.io/library/image:latest')
        $details['resourceEnum'].IsResourceDerived | Should -BeTrue
        $details['resourceEnum'].HasDiscriminator | Should -BeFalse
        $details['resourceEnum'].AllowedValues.Count | Should -Be 0
        $details['free'].IsResourceDerived | Should -BeFalse
        $details['configs.kind-premium.apiMode'].IsResourceDerived | Should -BeTrue
        $details['config.kind-premium'].Description |
            Should -BeExactly 'The type of a premium configuration.'
        @($details['configs.kind-premium.disk'].AllowedValues) |
            Should -Be @('Premium_LRS', 'Premium_ZRS', 'PremiumV2_LRS')
        @($details['outbound.>Any_other_property<.kind-premium.retention'].AllowedValues) |
            Should -Be @(30, 60, 120)
        @($details['config.kind-premium.kind'].AllowedValues) | Should -Be @('premium')
    }

    It 'reports invalid compiled definition references rather than emitting incomplete documentation' {
        {
            InModuleScope 'Avm.Authoring' {
                Get-AvmBicepDocsCompiledParameter -Template @{
                    parameters = @{ config = @{ '$ref' = '#/definitions/missingType' } }
                } -SourcePath 'synthetic/main.json'
            }
        } | Should -Throw '*references missing definition*'
    }

    It 'does not promote array item type examples to the parameter while retaining authored examples' {
        $template = @{
            parameters = @{
                entries = @{
                    type     = 'array'
                    nullable = $true
                    items    = @{ '$ref' = '#/definitions/entryType' }
                }
                authoredEntries = @{
                    type     = 'array'
                    metadata = @{ example = "[{ name: 'parameter-level' }]" }
                    items    = @{ '$ref' = '#/definitions/entryType' }
                }
                scalarEntries = @{
                    type  = 'array'
                    items = @{ type = 'string'; metadata = @{ example = 'item-level' } }
                }
            }
            definitions = @{
                entryType = @{
                    type       = 'object'
                    metadata   = @{ example = "[[{ name: 'type-level' }]" }
                    properties = @{
                        name = @{
                            type     = 'string'
                            metadata = @{ example = 'property-level' }
                        }
                    }
                }
            }
        }

        $details = InModuleScope 'Avm.Authoring' -Parameters @{ T = $template } {
            param($T)
            Get-AvmBicepDocsCompiledParameter -Template $T -SourcePath 'synthetic/main.json'
        }

        $details['entries'].Example | Should -BeNullOrEmpty
        $details['authoredEntries'].Example | Should -BeExactly "[{ name: 'parameter-level' }]"
        $details['scalarEntries'].Example | Should -BeNullOrEmpty
        $details['entries.name'].Example | Should -BeExactly 'property-level'
    }

    It 'rejects invalid compiled example types instead of silently dropping them' {
        {
            InModuleScope 'Avm.Authoring' {
                Get-AvmBicepDocsCompiledParameter -Template @{
                    parameters = @{ image = @{
                            type = 'string'; metadata = @{ example = @('valid', 42) }
                        }
                    }
                } -SourcePath 'synthetic/main.json'
            }
        } | Should -Throw '*must be a string, an object, or an array of strings*'
    }

    It 'rejects invalid array item examples even though item examples are not rendered' {
        {
            InModuleScope 'Avm.Authoring' {
                Get-AvmBicepDocsCompiledParameter -Template @{
                    parameters = @{
                        entries = @{
                            type  = 'array'
                            items = @{ type = 'string'; metadata = @{ example = @('valid', 42) } }
                        }
                    }
                } -SourcePath 'synthetic/main.json'
            }
        } | Should -Throw '*must be a string, an object, or an array of strings*'
    }
}
