#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Integration: Bicep docs scoped examples' -Tag Integration -Skip:($env:AVM_OFFLINE -eq '1') {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        $script:moduleRoot = Join-Path $script:repoRoot 'src' 'Avm.Authoring'
        $script:fixtureRoot = Join-Path $script:repoRoot 'tests' 'fixtures' 'bicep-docs'
        Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
    }

    AfterAll {
        Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
    }

    It 'renders reassigned e2e examples in the scoped child without writing READMEs' {
        $root = Join-Path $TestDrive 'repository'
        $module = Join-Path $root 'avm' 'res' 'storage' 'storage-account'
        $scope = Join-Path $module 'rg-scope'
        $null = New-Item -ItemType Directory -Path $scope -Force
        Copy-Item -Path (Join-Path $script:fixtureRoot '*') -Destination $module -Recurse
        Copy-Item -LiteralPath (Join-Path $script:fixtureRoot 'main.bicep') `
            -Destination (Join-Path $scope 'main.bicep')
        Copy-Item -LiteralPath (Join-Path $script:fixtureRoot 'main.json') `
            -Destination (Join-Path $scope 'main.json')
        [System.IO.File]::WriteAllText(
            (Join-Path $module 'tests' 'e2e' 'rg-scope.max' '.e2eignore'),
            'Requires credentials.', [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::AppendAllText((Join-Path $scope 'main.bicep'), @'

@description('Optional. Assign roles.')
param roleAssignments object[] = []

@minValue(0)
@maxValue(365)
@allowed([30, 60, 90, 120])
@description('Optional. Number of days to retain logs.')
param retentionInDays int = 30

@description('Optional. Blob service settings.')
param blobServices object = {
  enableVersioning: true
}

@secure()
@description('Optional. Protected settings.')
param protectedSettings {
  @description('Optional. API key.')
  apiKey: string?
} = {}

@description('Optional. Neighbor after blob services.')
param blobServicesNext string = ''

@description('Optional. Container registry server.')
param inlineExample string = ''

@description('Optional. Container image.')
param image string = 'mcr.microsoft.com/k8se/quickstart-jobs:latest'

@description('Optional. Linux feature.')
param featureEnabled bool = false

@description('Optional. Redundant backup.')
param geoRedundantBackup string = 'Enabled' // WAF-aligned default

@description('Optional. Stop sequence.')
param stopSequence string = '\\n'

@description('Optional. Empty zones.')
param emptyZones string[] = [] // Preview

type authType = 'AAD' | 'Certificate' | 'Radius'

@description('Optional. VPN authentication types.')
param vpnAuthenticationTypes authType[] = []

@description('Optional. Monitoring agent configuration.')
param monitoringConfig object = {
  enabled: false
  dataCollectionRuleAssociations: []
}

@description('Optional. Scale-in policy.')
param scaleInPolicy object = {
  rules: [
    'Default'
  ]
}

@description('Optional. Allowed availability zones.')
param allowedZones int[] = [3, 1, 2]

@allowed(['Private', 'Public'])
@description('Optional. API-derived resource mode.')
param resourceDerivedMode string = 'Private'

@description('Optional. DNS record settings.')
param a {
  @description('Optional. Assign record roles.')
  roleAssignments: object[]
} = { roleAssignments: [] }

@description('Optional. Private endpoint settings.')
param privateEndpoints {
  @description('Optional. Assign private endpoint roles.')
  roleAssignments: object[]
} = { roleAssignments: [] }

@description('Optional. Slot settings.')
param slots {
  @description('Optional. Slot private endpoint settings.')
  privateEndpoints: {
    @description('Optional. Assign slot roles.')
    roleAssignments: object[]
  }
} = { privateEndpoints: { roleAssignments: [] } }

@description('Optional. File service settings.')
param fileServices {
  @description('Optional. Share settings.')
  shares: {
    @description('Optional. Assign share roles.')
    roleAssignments: object[]
  }
} = { shares: { roleAssignments: [] } }

@description('Optional. Table service settings.')
param tableServices {
  @description('Optional. Table settings.')
  tables: {
    @description('Optional. Assign table roles.')
    roleAssignments: object[]
  }
} = { tables: { roleAssignments: [] } }

@description('Optional. Sample rules.')
param documentedRules object[] = [
  {
    name: 'outer'
    details: {
      zeta: 'z'
      alpha: 'a'
    }
  }
]

@description('The type of a webhook destination.')
type webhookDestination = {
  @description('Required. Endpoint type.')
  endpointType: 'WebHook'
  @description('Optional. Destination URL.')
  url: string?
}

@description('The type of a storage destination.')
type storageDestination = {
  @description('Required. Endpoint type.')
  endpointType: 'Storage'
  @description('Optional. Destination resource.')
  resourceId: string?
}

@discriminator('endpointType')
type destinationType = webhookDestination | storageDestination

@description('Optional. Destination configuration.')
param destination destinationType = { endpointType: 'WebHook' }

@description('The type of an inner alias.')
type innerAlias = {
  @description('Required. The inner value.')
  innerValue: string
}

type outerAlias = innerAlias

@description('Optional. Aliased settings.')
param aliasedSettings outerAlias = { innerValue: 'demo' }

@description('Optional. Aliased custom libraries.')
param customLibraries innerAlias[] = []

@description('The type of pool scaling settings.')
type poolScaling = {
  @description('Required. The pool capacity.')
  capacity: int
}

type poolScalingAlias = poolScaling

type poolConfiguration = {
  @description('Optional. Autoscale settings.')
  autoScale: poolScalingAlias?
}

@description('Optional. Pool settings.')
param poolSettings poolConfiguration = {}

@description('Optional. Pool configurations.')
param poolSets poolConfiguration[] = []

@description('The type of web-test alert criteria.')
type webtestCriteria = {
  @description('Required. Alert kind.')
  kind: 'Webtest'
}

@description('The type of single-resource alert criteria.')
type singleCriteria = {
  @description('Required. Alert kind.')
  kind: 'Single'
  @description('Required. Resource ID.')
  resourceId: string
}

@description('The type of multi-resource alert criteria.')
type multipleCriteria = {
  @description('Required. Alert kind.')
  kind: 'Multiple'
}

@discriminator('kind')
type criteriaType = webtestCriteria | singleCriteria | multipleCriteria

@description('Optional. Alert criteria.')
param criteria criteriaType = {
  kind: 'Webtest'
}

@description('Optional. Criteria without defaults.')
param criteriaWithoutDefault criteriaType?

@description('Optional. Secure alert criteria.')
param secureCriteria criteriaType = { kind: 'Webtest' }

@description('Optional. Nested alert criteria.')
param nestedCriteria {
  @description('Optional. Nested criterion.')
  criterion: criteriaType?
} = {}

@description('The type of nullable nested criteria.')
type nullableCriteriaType = {
  @description('Optional. Nested criterion.')
  criterion: criteriaType?
}

@description('Optional. Next nullable criteria.')
param nullableNext nullableCriteriaType?

@description('Optional. Previous nullable criteria.')
param nullableCriteria nullableCriteriaType?

@description('Optional. Duplicated prefix settings.')
param doubledSettings {
  @description('Optional. Optional. Retain the second prefix.')
  field: string?
} = {}

@description('Optional. Sample tags.')
param sampleTags object = {}

@description('Optional. Final documented settings.')
param zzDocumentedSettings object = {
  enabled: true
}

@secure()
@description('The temporary registration token.')
output registrationToken string? = 'token'
'@)
        $compiledPath = Join-Path $scope 'main.json'
        $compiled = [System.IO.File]::ReadAllText($compiledPath) | ConvertFrom-Json -AsHashtable
        $compiled.parameters.roleAssignments = @{ type = 'array'; defaultValue = @() }
        $compiled.parameters.retentionInDays = @{
            type          = 'int'
            defaultValue  = 30
            allowedValues = @(30, 60, 90, 120)
            maxValue      = 365
            metadata      = @{ example = "    30`n      60`n    " }
        }
        $compiled.parameters.blobServices = @{
            type         = 'object'
            defaultValue = "[if(not(equals(parameters('kind'), 'FileStorage')), createObject('enableVersioning', true), createObject())]"
        }
        $compiled.parameters.protectedSettings = @{
            type       = 'secureObject'
            properties = @{
                apiKey = @{ type = 'string'; metadata = @{ description = 'Optional. API key.' } }
            }
        }
        $compiled.parameters.blobServicesNext = @{ type = 'string'; defaultValue = '' }
        $compiled.parameters.inlineExample = @{
            type     = 'string'
            metadata = @{ example = 'myregistry.azurecr.io' }
        }
        $compiled.parameters.image = @{
            type     = 'string'
            metadata = @{ example = @(
                    'mcr.microsoft.com/k8se/quickstart-jobs:latest',
                    'docker.io/library/image:latest',
                    'docker.io/hello-world:latest'
                )
            }
        }
        $compiled.parameters.featureEnabled = @{
            type         = 'bool'
            defaultValue = "[equals(parameters('kind'), 'linux')]"
        }
        $compiled.parameters.geoRedundantBackup = @{
            type         = 'string'
            defaultValue = 'Enabled'
        }
        $compiled.parameters.stopSequence = @{
            type         = 'string'
            defaultValue = '\n'
        }
        $compiled.parameters.emptyZones = @{
            type         = 'array'
            defaultValue = @()
        }
        $compiled.parameters.documentedRules = @{
            type         = 'array'
            defaultValue = @(
                [ordered]@{
                    name    = 'outer'
                    details = [ordered]@{
                        zeta  = 'z'
                        alpha = 'a'
                    }
                }
            )
        }
        $compiled.parameters.vpnAuthenticationTypes = @{
            type        = 'array'
            defaultValue = @()
            prefixItems = @(@{ type = 'string'; allowedValues = @('AAD', 'Certificate', 'Radius') })
        }
        $compiled.parameters.criteria = @{ '$ref' = '#/definitions/criteriaType' }
        $compiled.parameters.criteriaWithoutDefault = @{
            '$ref'  = '#/definitions/criteriaType'
            nullable = $true
        }
        $compiled.parameters.secureCriteria = @{ '$ref' = '#/definitions/secureCriteriaType' }
        $compiled.parameters.nestedCriteria = @{
            type         = 'object'
            defaultValue = @{}
            properties   = @{ criterion = @{ '$ref' = '#/definitions/criteriaType' } }
        }
        $compiled.parameters.nullableNext = @{
            '$ref'  = '#/definitions/nullableCriteriaType'
            nullable = $true
        }
        $compiled.parameters.nullableCriteria = @{
            '$ref'  = '#/definitions/nullableCriteriaType'
            nullable = $true
        }
        $compiled.parameters.doubledSettings = @{
            type         = 'object'
            defaultValue = @{}
            properties   = @{ field = @{
                    type     = 'string'
                    nullable = $true
                    metadata = @{ description = 'Optional. Optional. Retain the second prefix.' }
                }
            }
        }
        $compiled.parameters.sampleTags = @{
            type         = 'object'
            defaultValue = @{}
            metadata     = @{
                example = [ordered]@{
                    Environment = 'Production'
                    Owner       = 'TeamName'
                    CostCenter  = 'IT'
                    Application = 'MyApp'
                }
            }
        }
        $compiled.parameters.zzDocumentedSettings = @{
            type         = 'object'
            defaultValue = @{ enabled = $true }
        }
        $compiled.parameters.monitoringConfig = @{
            type         = 'object'
            defaultValue = [ordered]@{
                enabled                        = $false
                dataCollectionRuleAssociations = @()
            }
        }
        $compiled.parameters.scaleInPolicy = @{
            type         = 'object'
            defaultValue = @{ rules = @('Default') }
        }
        $compiled.parameters.allowedZones = @{
            type          = 'array'
            defaultValue  = @(3, 1, 2)
            allowedValues = @(1, 2, 3)
        }
        $compiled.parameters.resourceDerivedMode = @{
            type         = 'string'
            defaultValue = 'Private'
            metadata     = @{ '__bicep_resource_derived_type!' = 'Microsoft.Web/sites' }
        }
        $compiled.parameters.destination = @{
            type         = 'object'
            defaultValue = @{ endpointType = 'WebHook' }
            metadata     = @{
                description                       = 'Optional. Destination configuration.'
                '__bicep_resource_derived_type!' = 'Microsoft.EventGrid/eventSubscriptions'
            }
        }
        $compiled.parameters.aliasedSettings = @{
            '$ref'      = '#/definitions/outerAlias'
            defaultValue = @{ innerValue = 'demo' }
            metadata     = @{ description = 'Optional. Aliased settings.' }
        }
        $compiled.parameters.customLibraries = @{
            type         = 'array'
            defaultValue = @()
            items        = @{ '$ref' = '#/definitions/outerAlias' }
        }
        $compiled.parameters.poolSettings = @{
            '$ref' = '#/definitions/poolConfiguration'
        }
        $compiled.parameters.poolSets = @{
            type  = 'array'
            items = @{ '$ref' = '#/definitions/poolConfiguration' }
        }
        $compiled.definitions = @{
            nullableCriteriaType = @{
                type       = 'object'
                properties = @{ criterion = @{ '$ref' = '#/definitions/criteriaType' } }
            }
            outerAlias = @{ '$ref' = '#/definitions/innerAlias' }
            innerAlias = @{
                type       = 'object'
                properties = @{
                    innerValue = @{
                        type     = 'string'
                        metadata = @{ description = 'Required. The inner value.' }
                    }
                }
            }
            poolConfiguration = @{
                type       = 'object'
                properties = @{ autoScale = @{ '$ref' = '#/definitions/poolScalingAlias' } }
            }
            poolScalingAlias = @{ '$ref' = '#/definitions/poolScaling' }
            poolScaling = @{
                type       = 'object'
                properties = @{
                    capacity = @{
                        type     = 'int'
                        metadata = @{ description = 'Required. The pool capacity.' }
                    }
                }
            }
            criteriaType = @{
                type          = 'object'
                discriminator = @{
                    propertyName = 'kind'
                    mapping      = [ordered]@{
                        Webtest  = @{ '$ref' = '#/definitions/webtestCriteria' }
                        Single   = @{ '$ref' = '#/definitions/singleCriteria' }
                        Multiple = @{ '$ref' = '#/definitions/multipleCriteria' }
                    }
                }
            }
            secureCriteriaType = @{
                type          = 'secureObject'
                discriminator = @{
                    propertyName = 'kind'
                    mapping      = [ordered]@{
                        Webtest  = @{ '$ref' = '#/definitions/webtestCriteria' }
                        Single   = @{ '$ref' = '#/definitions/singleCriteria' }
                        Multiple = @{ '$ref' = '#/definitions/multipleCriteria' }
                    }
                }
            }
            webtestCriteria = @{
                type       = 'object'
                metadata   = @{ description = 'The type of web-test alert criteria.' }
                properties = @{ kind = @{ type = 'string'; allowedValues = @('Webtest') } }
            }
            singleCriteria = @{
                type       = 'object'
                metadata   = @{ description = 'The type of single-resource alert criteria.' }
                properties = @{
                    kind       = @{ type = 'string'; allowedValues = @('Single') }
                    resourceId = @{ type = 'string'; metadata = @{
                            description = 'Required. Resource ID.'
                        }
                    }
                }
            }
            multipleCriteria = @{
                type       = 'object'
                metadata   = @{ description = 'The type of multi-resource alert criteria.' }
                properties = @{ kind = @{ type = 'string'; allowedValues = @('Multiple') } }
            }
        }
        $compiled.variables = @{
            builtInRoleNames = [ordered]@{ Contributor = 'contributor-id' }
        }
        $compiled.outputs = @{
            registrationToken = @{ type = 'securestring'; nullable = $true }
            resourceId        = @{ type = 'string' }
        }
        $compiled.resources = @{
            workspace_privateEndpoints = @{
                type       = 'Microsoft.Resources/deployments'
                properties = @{
                    template = @{
                        variables = @{
                            builtInRoleNames = @{ 'Endpoint Reader' = 'endpoint-reader-id' }
                        }
                    }
                }
            }
            registry_privateEndpoints = @{
                type       = 'Microsoft.Resources/deployments'
                properties = @{
                    template = @{
                        variables = @{
                            builtInRoleNames = @{ 'Endpoint Reader' = 'endpoint-reader-id' }
                        }
                    }
                }
            }
            dnsZone_A = @{
                type       = 'Microsoft.Resources/deployments'
                properties = @{
                    template = @{
                        variables = @{
                            builtInRoleNames = @{
                                'DNS Zone Contributor' = 'dns-contributor-id'
                            }
                        }
                    }
                }
            }
            app_slots = @{
                type       = 'Microsoft.Resources/deployments'
                properties = @{
                    template = @{
                        variables = @{
                            builtInRoleNames = @{ 'Slot Reader' = 'slot-reader-id' }
                        }
                    }
                }
            }
            fileServices_shares = @{
                type       = 'Microsoft.Resources/deployments'
                properties = @{
                    template = @{
                        variables = @{
                            builtInRoleNames = @{ 'Share Reader' = 'share-reader-id' }
                        }
                    }
                }
            }
            tableServices_tables = @{
                type       = 'Microsoft.Resources/deployments'
                properties = @{
                    template = @{
                        variables = @{
                            builtInRoleNames = @{ 'Table Reader' = 'table-reader-id' }
                        }
                    }
                }
            }
        }
        [System.IO.File]::WriteAllText(
            $compiledPath, (ConvertTo-Json -InputObject $compiled -Depth 99),
            [System.Text.UTF8Encoding]::new($false))

        $template = Join-Path $root 'docs' 'templates' 'avm-readme-v1.scriban'
        $null = New-Item -ItemType Directory -Path (Split-Path $template -Parent) -Force
        Copy-Item -LiteralPath (Join-Path $script:moduleRoot 'Resources' 'bicep' 'avm-readme-v1.scriban') `
            -Destination $template
        $config = @'
{
  "documentation": {
    "template": { "file": "docs/templates/avm-readme-v1.scriban" },
    "examples": {
      "reassignments": [
        { "from": { "include": ["**/rg-scope.*/**"] }, "to": "rg-scope" }
      ]
    }
  }
}
'@
        [System.IO.File]::WriteAllText(
            (Join-Path $root 'bicepconfig.json'), $config, [System.Text.UTF8Encoding]::new($false))

        $roleValues = InModuleScope 'Avm.Authoring' -Parameters @{ S = $scope; R = $root } {
            param($S, $R)
            Get-AvmBicepDocsCustomValue -ModulePath $S `
                -RepositoryRoot $R -ToolPath 'mock-bicep'
        }
        $roleMaps = $roleValues.roleNames | ConvertFrom-Json -AsHashtable
        ($roleValues.compiledOutputs | ConvertFrom-Json -AsHashtable)['registrationToken'].type |
            Should -BeExactly 'securestring'
        @($roleMaps.Identifier) | Should -Contain 'dnsZone_A'
        @($roleMaps.Identifier) | Should -Contain 'app_slots'
        @($roleMaps | Where-Object Identifier -EQ 'dnsZone_A')[0].Names |
            Should -Be @('DNS Zone Contributor')

        $result = Invoke-AvmDocs -Path $root -CheckDrift -IncludeRenderedContent -SkipModuleVersionCheck
        $result.FilesSelected | Should -Be 3
        $result.FilesProcessed | Should -Be 3
        @($result.Issues | Where-Object { $_.Code -eq 'avm.bicep.docs-render-failed' }).Count |
            Should -Be 0
        $scoped = @($result.GeneratedReadmes | Where-Object {
                $_.Path -eq 'avm/res/storage/storage-account/rg-scope/README.md'
            })[0].Content
        $scoped | Should -Match '### Example 1: _Full example_'
        $scoped | Should -Match '### Example 2: _Minimal example_'
        @([regex]::Matches($scoped, '<summary>via Bicep module</summary>')).Count | Should -Be 2
        @([regex]::Matches($scoped, '<summary>via JSON parameters file</summary>')).Count |
            Should -Be 2
        @([regex]::Matches($scoped, '<summary>via Bicep parameters file</summary>')).Count |
            Should -Be 2
        $scoped | Should -Match '```text\nRequires credentials\.\n```\n\n<details>'
        $scoped | Should -Match '## Parameters\n\n\*\*Required parameters\*\*'
        $scoped | Should -Match '(?s)### Parameter: `name`.*?- Type: string\n\n### Parameter: `a`'
        $scoped | Should -Match 'Roles configurable by name:'
        $scoped | Should -Match "'Contributor'"
        $scoped | Should -Not -Match "'(Reader|Owner)'"
        $scoped | Should -Match '(?s)### Parameter: `a.roleAssignments`.*?- Roles configurable by name:\n  - `''DNS Zone Contributor''`'
        $rootEndpointRoles = [regex]::Match(
            $scoped, '(?s)### Parameter: `privateEndpoints.roleAssignments`(?<body>.*?)(?:### Parameter:|## Outputs)')
        $rootEndpointRoles.Success | Should -BeTrue
        $rootEndpointRoles.Groups['body'].Value | Should -Not -Match 'Roles configurable by name:'
        $slotEndpointRoles = [regex]::Match(
            $scoped, '(?s)### Parameter: `slots.privateEndpoints.roleAssignments`(?<body>.*?)(?:### Parameter:|## Outputs)')
        $slotEndpointRoles.Success | Should -BeTrue
        $slotEndpointRoles.Groups['body'].Value |
            Should -Match 'Roles configurable by name:\n  - `''Slot Reader''`'
        $shareRoles = [regex]::Match(
            $scoped, '(?s)### Parameter: `fileServices.shares.roleAssignments`(?<body>.*?)(?:### Parameter:|## Outputs)')
        $shareRoles.Success | Should -BeTrue
        $shareRoles.Groups['body'].Value | Should -Not -Match 'Roles configurable by name:'
        $tableRoles = [regex]::Match(
            $scoped, '(?s)### Parameter: `tableServices.tables.roleAssignments`(?<body>.*?)(?:### Parameter:|## Outputs)')
        $tableRoles.Success | Should -BeTrue
        $tableRoles.Groups['body'].Value |
            Should -Match 'Roles configurable by name:\n  - `''Contributor''`'
        $tableRoles.Groups['body'].Value | Should -Not -Match "'Table Reader'"
        $scoped | Should -Match '(?s)### Parameter: `retentionInDays`.*?- Allowed:\n  ```Bicep\n  \[\n    30\n    60\n    90\n    120\n'
        $scoped | Should -Match '(?s)### Parameter: `retentionInDays`.*?- Default: `30`\n- Allowed:'
        $retention = [regex]::Match(
            $scoped, '(?s)### Parameter: `retentionInDays`(?<body>.*?)### Parameter: `roleAssignments`')
        $retention.Success | Should -BeTrue
        $retention.Groups['body'].Value | Should -Not -Match '- MinValue:'
        $retention.Groups['body'].Value | Should -Match '- MaxValue: 365'
        $retention.Groups['body'].Value |
            Should -Match '- Example:\n  ```Bicep\n  30\n    60\n  ```'
        $inlineExample = [regex]::Match(
            $scoped, '(?s)### Parameter: `inlineExample`(?<body>.*?)(?:### Parameter:|## Outputs)')
        $inlineExample.Success | Should -BeTrue
        $inlineExample.Groups['body'].Value |
            Should -Match '- Example: `myregistry.azurecr.io`'
        $inlineExample.Groups['body'].Value | Should -Not -Match '```Bicep'
        $backup = [regex]::Match(
            $scoped, '(?s)### Parameter: `geoRedundantBackup`(?<body>.*?)(?:### Parameter:|## Outputs)')
        $backup.Success | Should -BeTrue
        $backup.Groups['body'].Value | Should -Match ([regex]::Escape('- Default: `''Enabled''`'))
        $backup.Groups['body'].Value | Should -Not -Match 'WAF-aligned default'
        $stopSequence = [regex]::Match(
            $scoped, '(?s)### Parameter: `stopSequence`(?<body>.*?)(?:### Parameter:|## Outputs)')
        $stopSequence.Success | Should -BeTrue
        $stopSequence.Groups['body'].Value |
            Should -Match ([regex]::Escape('- Default: `''\n''`'))
        $emptyZones = [regex]::Match(
            $scoped, '(?s)### Parameter: `emptyZones`(?<body>.*?)(?:### Parameter:|## Outputs)')
        $emptyZones.Success | Should -BeTrue
        $emptyZones.Groups['body'].Value | Should -Match ([regex]::Escape('- Default: `[]`'))
        $emptyZones.Groups['body'].Value | Should -Not -Match 'Preview'
        $vpnAuthenticationTypes = [regex]::Match(
            $scoped, '(?s)### Parameter: `vpnAuthenticationTypes`(?<body>.*?)(?:### Parameter:|## Outputs)')
        $vpnAuthenticationTypes.Success | Should -BeTrue
        $vpnAuthenticationTypes.Groups['body'].Value | Should -Not -Match '- Allowed:'
        $webtest = $scoped.IndexOf('### Variant: `criteria.kind-Webtest`', [System.StringComparison]::Ordinal)
        $single = $scoped.IndexOf('### Variant: `criteria.kind-Single`', [System.StringComparison]::Ordinal)
        $multiple = $scoped.IndexOf('### Variant: `criteria.kind-Multiple`', [System.StringComparison]::Ordinal)
        $webtest | Should -BeGreaterThan 0
        $single | Should -BeGreaterThan $webtest
        $multiple | Should -BeGreaterThan $single
        $scoped | Should -Match '### Parameter: `secureCriteria`'
        $scoped | Should -Match '- Discriminator: `kind`'
        $scoped | Should -Match '### Variant: `secureCriteria.kind-Webtest`'
        $scoped | Should -Match '\| `registrationToken` \| securestring \|'
        $discriminatorGap = [regex]::Match($scoped,
            '(?s)### Parameter: `criteria`.*?- Default:\n  ```Bicep\n.+?  ```(?<gap>\n+)- Discriminator: `kind`')
        $discriminatorGap.Groups['gap'].Value.Length | Should -Be 1
        $variantGap = [regex]::Match($scoped,
            '(?s)### Parameter: `criteria.kind-Webtest.kind`.*?  ```(?<gap>\n+)### Variant: `criteria.kind-Single`')
        $variantGap.Groups['gap'].Value.Length | Should -Be 2
        $plainGap = [regex]::Match($scoped,
            '(?s)### Parameter: `criteria.kind-Single.resourceId`.*?- Type: string(?<gap>\n+)### Variant: `criteria.kind-Multiple`')
        $plainGap.Groups['gap'].Value.Length | Should -Be 2
        $lastVariantGap = [regex]::Match($scoped,
            '(?s)### Parameter: `criteria.kind-Multiple.kind`.*?  ```(?<gap>\n+)### Parameter: `[A-Za-z]')
        $lastVariantGap.Groups['gap'].Value.Length | Should -Be 2
        $noDefaultGap = [regex]::Match($scoped,
            '(?s)### Parameter: `criteriaWithoutDefault.kind-Multiple.kind`.*?  ```(?<gap>\n+)### Parameter: `[A-Za-z]')
        $noDefaultGap.Groups['gap'].Value.Length | Should -Be 2
        $nestedGap = [regex]::Match($scoped,
            '(?s)### Parameter: `nestedCriteria.criterion.kind-Multiple.kind`.*?  ```(?<gap>\n+)### Parameter: `[A-Za-z]')
        $nestedGap.Groups['gap'].Value.Length | Should -Be 2
        $nullableGap = [regex]::Match($scoped,
            '(?s)### Parameter: `nullableCriteria.criterion.kind-Multiple.kind`.*?  ```(?<gap>\n+)### Parameter: `nullableNext`')
        $nullableGap.Groups['gap'].Value.Length | Should -Be 2
        $scoped | Should -Match '\| \[`field`\]\(#parameter-doubledsettingsfield\) \| string \| Optional\. Retain the second prefix\. \|'
        $scoped | Should -Match '### Parameter: `doubledSettings.field`\n\nOptional\. Retain the second prefix\.'
        $outputGap = [regex]::Match($scoped,
            '(?s)### Parameter: `zzDocumentedSettings`.*?  ```(?<gap>\n+)## Outputs')
        $outputGap.Groups['gap'].Value.Length | Should -Be 2
        $scoped | Should -Match '(?s)### Parameter: `sampleTags`.*?- Default: `\{\}`\n- Example:\n  ```Bicep\n  \{\n    Application: ''MyApp''\n    CostCenter: ''IT''\n    Environment: ''Production''\n    Owner: ''TeamName''\n  \}\n  ```'
        $scoped | Should -Match '(?s)### Parameter: `documentedRules`.*?- Default:\n  ```Bicep\n  \[\n    \{\n      details: \{\n        alpha: ''a''\n        zeta: ''z''\n      \}\n      name: ''outer''\n    \}\n  \]\n  ```'
        $scoped | Should -Match '(?s)### Parameter: `image`.*?- Example:\n  ```Bicep\n  mcr.microsoft.com/k8se/quickstart-jobs:latest\n  docker.io/library/image:latest\n  docker.io/hello-world:latest\n  ```'
        $scoped | Should -Match "(?s)### Parameter: ``featureEnabled``.*?- Default: ``\[equals\(parameters\('kind'\), 'linux'\)\]``"
        $scoped | Should -Not -Match "`r"
        $scoped | Should -Match '(?s)### Parameter: `monitoringConfig`.*?- Default:\n  ```Bicep\n  \{\n      dataCollectionRuleAssociations: \[\]\n      enabled: false\n  \}\n  ```'
        $scoped | Should -Match '(?s)### Parameter: `scaleInPolicy`.*?- Default:\n  ```Bicep\n  \{\n      rules: \[\n        ''Default''\n      \]\n  \}\n  ```'
        $scoped | Should -Match '(?s)### Parameter: `blobServices`.*?- Default: `\[if\(not\(equals\(parameters\(''kind''\), ''FileStorage''\)\), createObject\(''enableVersioning'', true\), createObject\(\)\)\]`\n\n### Parameter: `blobServicesNext`'
        $allowedZones = [regex]::Match(
            $scoped, '(?s)### Parameter: `allowedZones`(?<body>.*?)### Parameter: `blobServices`')
        $allowedZones.Success | Should -BeTrue
        [regex]::Match(
            $allowedZones.Groups['body'].Value, '  ```(?<gap>\n+)- Allowed:'
        ).Groups['gap'].Value.Length | Should -Be 1
        $allowedZones.Groups['body'].Value | Should -Match '  ```\n\n$'
        $derivedMode = [regex]::Match(
            $scoped,
            '(?s)### Parameter: `resourceDerivedMode`(?<body>.*?)### Parameter: `retentionInDays`')
        $derivedMode.Success | Should -BeTrue
        $derivedMode.Groups['body'].Value | Should -Not -Match '- Allowed:'
        $destination = [regex]::Match(
            $scoped, '(?s)### Parameter: `destination`(?<body>.*?)### Parameter: `location`')
        $destination.Success | Should -BeTrue
        $destination.Groups['body'].Value | Should -Not -Match '- Discriminator:'
        $scoped | Should -Not -Match '### Variant: `destination.endpointType-'
        $scoped | Should -Match '\| \[`aliasedSettings`\]\(#parameter-aliasedsettings\) \|  \| Aliased settings\. \|'
        $aliased = [regex]::Match(
            $scoped, '(?s)### Parameter: `aliasedSettings`(?<body>.*?)### Parameter: `blobServices`')
        $aliased.Success | Should -BeTrue
        $aliased.Groups['body'].Value | Should -Match '- Type: \n'
        $scoped | Should -Not -Match '### Parameter: `aliasedSettings.innerValue`'
        $scoped | Should -Match '### Parameter: `customLibraries`'
        $scoped | Should -Not -Match '### Parameter: `customLibraries.innerValue`'
        $scoped | Should -Match '### Parameter: `protectedSettings`'
        $scoped | Should -Not -Match '### Parameter: `protectedSettings.apiKey`'
        $scoped | Should -Match '(?s)### Parameter: `poolSettings.autoScale`.*?- Type: \n'
        $scoped | Should -Not -Match '### Parameter: `poolSettings.autoScale.capacity`'
        $scoped | Should -Not -Match '### Parameter: `poolSets.autoScale.capacity`'
        $scoped | Should -Match '(?s)### Parameter: `a`.*?\n\n\*\*Optional parameters\*\*\n\n\| Parameter \| Type \| Description \|'
        [regex]::Match($scoped, '(?<gap>\n+)## Outputs').Groups['gap'].Value.Length |
            Should -Be 2
        Test-Path -LiteralPath (Join-Path $scope 'README.md') | Should -BeFalse

        $mapping = $compiled.definitions.criteriaType.discriminator.mapping
        $singleCriteria = $mapping['Single']
        $mapping.Remove('Single')
        [System.IO.File]::WriteAllText(
            $compiledPath, (ConvertTo-Json -InputObject $compiled -Depth 99),
            [System.Text.UTF8Encoding]::new($false))
        $missingVariant = Invoke-AvmDocs -Path $root -CheckDrift -SkipModuleVersionCheck
        $variantFailures = @($missingVariant.Issues | Where-Object {
                $_.Code -eq 'avm.bicep.docs-render-failed'
            })
        $variantFailures.Count | Should -Be 1
        $variantFailures[0].Message | Should -Match 'discriminator variants differ'
        $mapping['Single'] = $singleCriteria

        $compiled.resources.registry_privateEndpoints.properties.template.variables.builtInRoleNames =
            @{ Owner = 'owner-id' }
        [System.IO.File]::WriteAllText(
            $compiledPath, (ConvertTo-Json -InputObject $compiled -Depth 99),
            [System.Text.UTF8Encoding]::new($false))
        $conflict = Invoke-AvmDocs -Path $root -CheckDrift -SkipModuleVersionCheck
        $renderFailures = @($conflict.Issues | Where-Object {
                $_.Code -eq 'avm.bicep.docs-render-failed'
            })
        $renderFailures.Count | Should -Be 1
        $renderFailures[0].Message | Should -Match 'conflicting compiled role names'

        $compiled.variables = @{}
        [System.IO.File]::WriteAllText(
            $compiledPath, (ConvertTo-Json -InputObject $compiled -Depth 99),
            [System.Text.UTF8Encoding]::new($false))
        $withoutRootRoleMap = Invoke-AvmDocs -Path $root -CheckDrift `
            -IncludeRenderedContent -SkipModuleVersionCheck
        @($withoutRootRoleMap.Issues | Where-Object Code -EQ 'avm.bicep.docs-render-failed').Count |
            Should -Be 0
        $withoutRootRoleMapScoped = @($withoutRootRoleMap.GeneratedReadmes | Where-Object {
                $_.Path -eq 'avm/res/storage/storage-account/rg-scope/README.md'
            })[0].Content
        $withoutRootRoleMapScoped | Should -Not -Match 'Roles configurable by name:'

        $invalidTest = [System.IO.Path]::Combine(
            $module, 'tests', 'e2e', 'rg-scope.minimal', 'main.test.bicep')
        $invalidSource = [System.IO.File]::ReadAllText($invalidTest).Replace(
            "name: 'avmdocs12345'", "wrongName: 'invalid'")
        [System.IO.File]::WriteAllText(
            $invalidTest, $invalidSource, [System.Text.UTF8Encoding]::new($false))
        $invalid = Invoke-AvmDocs -Path $root -CheckDrift `
            -IncludeRenderedContent -SkipModuleVersionCheck
        $invalid.Status | Should -BeExactly 'fail'
        $invalid.FilesProcessed | Should -Be 2
        $invalidFailures = @($invalid.Issues | Where-Object Code -EQ 'avm.bicep.docs-render-failed')
        $invalidFailures.Count | Should -Be 1
        $invalidFailures[0].Message |
            Should -Match 'unknown parameters: wrongName; missing required parameters: name'
        @($invalid.GeneratedReadmes | Where-Object {
                $_.Path -eq 'avm/res/storage/storage-account/rg-scope/README.md'
            }).Count | Should -Be 0
        { Invoke-AvmDocs -Path $root -SkipModuleVersionCheck } |
            Should -Throw '*unknown parameters: wrongName; missing required parameters: name*'
        Test-Path -LiteralPath (Join-Path $module 'README.md') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $scope 'README.md') | Should -BeFalse
    }

    It 'preserves compiled alias constraints and omits non-documentable native children' {
        $root = Join-Path $TestDrive 'compiled-constraints'
        $module = Join-Path $root 'avm' 'res' 'storage' 'storage-account'
        $null = New-Item -ItemType Directory -Path $module -Force
        Copy-Item -Path (Join-Path $script:fixtureRoot '*') -Destination $module -Recurse
        [System.IO.File]::AppendAllText((Join-Path $module 'main.bicep'), @'

@export()
type computeTargetType = ('azure-container-app' | 'azure-container-instance')

@description('Optional. Allowed compute targets.')
param computeTargets computeTargetType[] = []

@export()
type resourceLimitsType =
  | { cpu: '0.25', memory: '0.5Gi' }
  | { cpu: '0.5', memory: '1Gi' }

@description('Optional. Runner settings.')
param runner {
  @description('Optional. Container resources.')
  resources: resourceLimitsType?
} = {}

@description('The database settings.')
type databaseTypeForDocs = {
  @minValue(10000)
  @maxValue(10000)
  @description('Optional. TCP port.')
  port: int?
}

@description('Optional. Database settings.')
param databaseSettings databaseTypeForDocs?

type alertFirstType = {
  @description('Required. The alert kind.')
  'odata.type': 'First'
}

type alertSecondType = {
  @description('Required. The alert kind.')
  'odata.type': 'Second'
}

@discriminator('odata.type')
type dottedCriteriaType = alertFirstType | alertSecondType

@description('Optional. Dotted alert criteria.')
param dottedCriteria dottedCriteriaType?

@description('Optional. Provider model.')
param providerModel {
  @description('Optional. Provider model version.')
  version: string?
} = {}

@description('Optional. Tuple settings.')
param tupleSettings {
  @description('Optional. Named rules.')
  rules: [
    {
      @description('Required. Rule name.')
      name: string
    }
  ]?
} = {}

@description('Optional. Provider rules.')
param providerRules {
  @minValue(0)
  @maxValue(1000)
  @description('Optional. Rule priority.')
  rulePriority: int?
} = {}
'@)
        $compiledPath = Join-Path $module 'main.json'
        $compiled = [System.IO.File]::ReadAllText($compiledPath) | ConvertFrom-Json -AsHashtable
        $compiled.parameters.computeTargets = @{
            type         = 'array'
            defaultValue = @()
            items        = @{ '$ref' = '#/definitions/computeTargetType' }
            metadata     = @{ description = 'Optional. Allowed compute targets.' }
        }
        $compiled.parameters.runner = @{
            type         = 'object'
            defaultValue = @{}
            properties   = @{
                resources = @{
                    '$ref'   = '#/definitions/resourceLimitsType'
                    nullable = $true
                    metadata = @{ description = 'Optional. Container resources.' }
                }
            }
        }
        $compiled.parameters.databaseSettings = @{
            '$ref'  = '#/definitions/databaseTypeForDocs'
            nullable = $true
        }
        $compiled.parameters.dottedCriteria = @{
            '$ref'  = '#/definitions/dottedCriteriaType'
            nullable = $true
        }
        $compiled.parameters.providerModel = @{
            type         = 'object'
            defaultValue = @{}
            metadata     = @{
                description                      = 'Optional. Provider model.'
                '__bicep_resource_derived_type!' = 'Microsoft.Example/models'
            }
        }
        $compiled.parameters.tupleSettings = @{
            type         = 'object'
            defaultValue = @{}
            properties   = @{
                rules = @{
                    type        = 'array'
                    nullable    = $true
                    prefixItems = @(@{
                            type       = 'object'
                            properties = @{ name = @{ type = 'string' } }
                        })
                    items       = $false
                    metadata    = @{ description = 'Optional. Named rules.' }
                }
            }
        }
        $compiled.parameters.providerRules = @{
            type         = 'object'
            defaultValue = @{}
            properties   = @{
                rulePriority = @{
                    type     = 'int'
                    nullable = $true
                    metadata = @{
                        description                      = 'Optional. Rule priority.'
                        '__bicep_resource_derived_type!' = 'Microsoft.Example/rules'
                    }
                }
            }
        }
        $compiled.definitions = @{
            computeTargetType = @{
                type          = 'string'
                allowedValues = @('azure-container-app', 'azure-container-instance')
            }
            resourceLimitsType = @{
                type          = 'object'
                allowedValues = @(
                    @{ cpu = '0.25'; memory = '0.5Gi' },
                    @{ cpu = '0.5'; memory = '1Gi' }
                )
            }
            databaseTypeForDocs = @{
                type       = 'object'
                properties = @{
                    port = @{
                        type     = 'int'
                        nullable = $true
                        minValue = 10000
                        maxValue = 10000
                        metadata = @{ description = 'Optional. TCP port.' }
                    }
                }
            }
            dottedCriteriaType = @{
                type          = 'object'
                discriminator = @{
                    propertyName = 'odata.type'
                    mapping      = [ordered]@{
                        First  = @{ '$ref' = '#/definitions/alertFirstType' }
                        Second = @{ '$ref' = '#/definitions/alertSecondType' }
                    }
                }
            }
            alertFirstType = @{
                type       = 'object'
                properties = @{
                    'odata.type' = @{
                        type          = 'string'
                        allowedValues = @('First')
                        metadata      = @{ description = 'Required. The alert kind.' }
                    }
                }
            }
            alertSecondType = @{
                type       = 'object'
                properties = @{
                    'odata.type' = @{
                        type          = 'string'
                        allowedValues = @('Second')
                        metadata      = @{ description = 'Required. The alert kind.' }
                    }
                }
            }
        }
        [System.IO.File]::WriteAllText(
            $compiledPath, (ConvertTo-Json -InputObject $compiled -Depth 99),
            [System.Text.UTF8Encoding]::new($false))

        $template = Join-Path $root 'docs' 'templates' 'avm-readme-v1.scriban'
        $null = New-Item -ItemType Directory -Path (Split-Path $template -Parent) -Force
        Copy-Item -LiteralPath (Join-Path $script:moduleRoot 'Resources' 'bicep' 'avm-readme-v1.scriban') `
            -Destination $template
        [System.IO.File]::WriteAllText((Join-Path $root 'bicepconfig.json'), @'
{
  "documentation": {
    "template": { "file": "docs/templates/avm-readme-v1.scriban" }
  }
}
'@, [System.Text.UTF8Encoding]::new($false))

        $result = Invoke-AvmDocs -Path $root -CheckDrift -IncludeRenderedContent -SkipModuleVersionCheck
        $errors = @($result.Issues | Where-Object Code -EQ 'avm.bicep.docs-render-failed')
        $errors.Count | Should -Be 0 -Because (@($errors | ForEach-Object Message) -join '; ')
        $content = @($result.GeneratedReadmes | Where-Object {
                $_.Path -eq 'avm/res/storage/storage-account/README.md'
            })[0].Content

        $compute = [regex]::Match(
            $content, '(?s)### Parameter: `computeTargets`(?<body>.*?)(?=\n### Parameter:|\n## Outputs)')
        $compute.Success | Should -BeTrue
        $compute.Groups['body'].Value |
            Should -Match '- Allowed:\n  ```Bicep\n  \[\n    ''azure-container-app''\n    ''azure-container-instance''\n  \]\n  ```'
        $resources = [regex]::Match(
            $content, '(?s)### Parameter: `runner.resources`(?<body>.*?)(?=\n### Parameter:|\n## Outputs)')
        $resources.Success | Should -BeTrue
        $resources.Groups['body'].Value |
            Should -Match '- Allowed:\n  ```Bicep\n  \[\n    \{\n      cpu: ''0\.25''\n      memory: ''0\.5Gi''\n    \}\n    \{\n      cpu: ''0\.5''\n      memory: ''1Gi''\n    \}\n  \]\n  ```'
        $port = [regex]::Match(
            $content, '(?s)### Parameter: `databaseSettings.port`(?<body>.*?)(?=\n### Parameter:|\n## Outputs)')
        $port.Success | Should -BeTrue
        $port.Groups['body'].Value | Should -Match '- MinValue: 10000\n- MaxValue: 10000'
        @([regex]::Matches($content, '- Allowed:\n  ```Bicep\n  ''odata\.type'': \[')).Count |
            Should -Be 2
        $content | Should -Not -Match '### Parameter: `providerModel.version`'
        $content | Should -Not -Match '### Parameter: `tupleSettings.rules.name`'
        $priority = [regex]::Match(
            $content, '(?s)### Parameter: `providerRules.rulePriority`(?<body>.*?)(?=\n### Parameter:|\n## Outputs)')
        $priority.Success | Should -BeTrue
        $priority.Groups['body'].Value | Should -Not -Match '- (Min|Max)Value:'
        Test-Path -LiteralPath (Join-Path $module 'README.md') | Should -BeFalse
    }

    It 'renders native discriminated union variants and their nested parameters' {
        $root = Join-Path $TestDrive 'union-repository'
        $module = Join-Path $root 'avm' 'res' 'storage' 'storage-account'
        $null = New-Item -ItemType Directory -Path $module -Force
        Copy-Item -Path (Join-Path $script:fixtureRoot '*') -Destination $module -Recurse
        Remove-Item -LiteralPath (Join-Path $module 'main.json')
        $moduleSource = Join-Path $module 'main.bicep'
        [System.IO.File]::WriteAllText(
            $moduleSource,
            ([System.IO.File]::ReadAllText($moduleSource)).Replace(
                'param name string', "param name string = 'avmdocs12345'"),
            [System.Text.UTF8Encoding]::new($false))
        $minimalPath = Join-Path $module 'tests' 'e2e' 'rg-scope.minimal' 'main.test.bicep'
        [System.IO.File]::WriteAllText(
            $minimalPath,
            ([System.IO.File]::ReadAllText($minimalPath)).ReplaceLineEndings("`n").Replace(
                "    name: 'avmdocs12345'`n", ''),
            [System.Text.UTF8Encoding]::new($false))
        $examplePath = Join-Path $module 'tests' 'e2e' 'rg-scope.max' 'main.test.bicep'
        [System.IO.File]::WriteAllText(
            $examplePath,
            [System.IO.File]::ReadAllText($examplePath).Replace(
                "metadata name = 'Full example'",
                "metadata name = ' Function_App, using only defaults.'"))
        [System.IO.File]::AppendAllText((Join-Path $module 'main.bicep'), @'

@description('The type of a premium configuration.')
type premiumConfig = {
  @description('Required. The config kind.')
  kind: 'premium'
  @description('Optional. Premium setting.')
  value: string?
}

@description('The type of a basic configuration.')
type basicConfig = {
  @description('Required. The config kind.')
  kind: 'basic'
  @description('Optional. Basic setting.')
  enabled: bool?
}

@discriminator('kind')
type configType = premiumConfig | basicConfig

@description('The type of an advanced basic configuration.')
type advancedBasic = {
  @description('Required. The config kind.')
  kind: 'basic'
  @description('Optional. The nested settings.')
  settings: {
    @description('Optional. The nested value.')
    value: string?
  }
}

@description('The type of an advanced premium configuration.')
type advancedPremium = {
  @description('Required. The config kind.')
  kind: 'premium'
  @description('Optional. The nested settings.')
  settings: {
    @description('Optional. The nested value.')
    value: string?
  }
}

@discriminator('kind')
type advancedConfigType = advancedBasic | advancedPremium

@description('Optional. An advanced union configuration.')
param advancedConfig advancedConfigType = { kind: 'basic', settings: {} }

@description('Optional. The union config.')
param config configType = { kind: 'premium' }

@description('Optional. The array of union configs.')
param configs configType[] = []

@description('Optional. A nested configuration.')
param deepConfig {
  @description('Optional. The child settings.')
  child: {
    @description('Optional. A nested value.')
    value: string?
  }
} = { child: {} }

@description('Optional. A plain parent with a nested union.')
param unionContainer {
  @description('Optional. The nested union.')
  nested: advancedConfigType
  @description('Optional. The trailing primitive.')
  workloadProfileName: string?
} = {
  nested: { kind: 'basic', settings: {} }
}

@description('Optional. The parameter after a plain parent.')
param unionTail string = ''

@description('Optional. The labels by key.')
param labelConfig {
  @description('Required. The label for this key.')
  *: string
} = {}

@metadata({
  example: '''
  {
      tags: {}
  }
  '''
})
@description('Optional. The nested configuration.')
param objectConfig {
  @description('Optional. The nested tags.')
  tags: object?
} = {}

@description('Condition. Name of the search service.')
param searchServiceName string = ''

@description('Condition. A scalar switch.')
param switchEnabled bool = true

@description('Condition. A nullable value without a default.')
param zNullable string?

@description('Optional. The site settings.')
param siteConfig {
  @description('Optional. Keep the site running.')
  alwaysOn: bool?
  @description('Optional. Minimum TLS version.')
  minTlsVersion: string?
  @description('Optional. FTP mode.')
  ftpsState: string?
} = {
  alwaysOn: true
  minTlsVersion: '1.2'
  ftpsState: 'FtpsOnly'
}

@description('Optional. Site settings with no documented children.')
param siteDefaultOnly {
  alwaysOn: bool?
} = {
  alwaysOn: true
}

@description('Optional. The trailing description.\n')
param trailingDescription string = ''

@metadata({
  example: '''
  {
      "key1": "value1"
  }
  '''
})
@description('Optional. Resource tags.')
param tags object?

@description('Optional. Legacy category labels.')
param typoConfig {
  @description('Optinal. First legacy option.')
  first: string?
  @description('Optonal. Second legacy option.')
  second: string?
  @description('Legacy. A general unknown category.')
  third: string?
} = {}

@description('Optional. Zone array.')
param zoneArray int[] = [3, 1, 2]

@description('Optional. Cipher array.')
param zoneCipher string[] = ['TLS256', 'TLS128']

@description('Optional. Empty zone array.')
param zoneEmpty int[] = []
'@)
        $template = Join-Path $root 'docs' 'templates' 'avm-readme-v1.scriban'
        $null = New-Item -ItemType Directory -Path (Split-Path $template -Parent) -Force
        Copy-Item -LiteralPath (Join-Path $script:moduleRoot 'Resources' 'bicep' 'avm-readme-v1.scriban') `
            -Destination $template
        [System.IO.File]::WriteAllText((Join-Path $root 'bicepconfig.json'), @'
{
  "documentation": {
    "template": { "file": "docs/templates/avm-readme-v1.scriban" }
  }
}
'@, [System.Text.UTF8Encoding]::new($false))

        $result = Invoke-AvmDocs -Path $root -CheckDrift -IncludeRenderedContent -SkipModuleVersionCheck
        $renderErrors = @($result.Issues | Where-Object Code -EQ 'avm.bicep.docs-render-failed')
        $renderErrors.Count | Should -Be 0 -Because (
            @($renderErrors | ForEach-Object { $_.Message }) -join '; ')
        $content = @($result.GeneratedReadmes | Where-Object {
                $_.Path -eq 'avm/res/storage/storage-account/README.md'
            })[0].Content
        $emptyExample = [regex]::Match(
            $content, '(?s)### Example 2: _Minimal example_(?<body>.*?)## Parameters')
        $emptyExample.Success | Should -BeTrue
        $emptyExample.Groups['body'].Value | Should -Match 'params: \{\n\n  \}'
        $emptyExample.Groups['body'].Value |
            Should -Match 'using ''br/public:avm/res/storage/storage-account:<version>''\n\n\n```'
        $content | Should -Match '- Discriminator: `kind`'
        $content | Should -Match '\(#example-1-functionapp-using-only-defaults\)'
        $content | Should -Match '\| \[`premium`\]\(#variant-configkind-premium\) \| The type of a premium configuration\. \|'
        $content | Should -Match '### Variant: `configs.kind-basic`'
        $content | Should -Match '(?s)### Parameter: `advancedConfig.kind-premium.settings.value`.*?- Type: string\n\n### Parameter: `config`'
        $content | Should -Match '### Parameter: `configs.kind-basic.enabled`'
        $content | Should -Match '### Parameter: `config.kind-premium.value`'
        $content | Should -Match '(?s)### Parameter: `deepConfig.child.value`.*?- Type: string\n\n### Parameter: `labelConfig`'
        $content | Should -Match '(?s)### Parameter: `unionContainer.workloadProfileName`.*?- Type: string\n\n### Parameter: `unionTail`'
        $discriminatorGap = [regex]::Match(
            $content, '- Discriminator: `kind`(?<gap>\s*)<h4>').Groups['gap'].Value
        $discriminatorGap.Length | Should -Be 2
        $content | Should -Match '(?s)### Parameter: `config`.*?- Discriminator: `kind`\n\n<h4>The available variants are:</h4>'
        $content | Should -Match '### Variant: `config.kind-basic`\nThe type of a basic configuration\.\n\nTo use this variant'
        $variantGap = [regex]::Match(
            $content,
            '(?s)### Variant: `config\.kind-[^`]+`.*?- Type: (?:bool|string)(?<gap>\n+)### Variant: `config\.kind-[^`]+`'
        ).Groups['gap'].Value
        $variantGap.Length | Should -Be 2
        $nestedBoundary = [regex]::Match(
            $content,
            '(?s)### Parameter: `config.kind-basic.kind`(?<section>.*?)### Parameter: `config.kind-basic.enabled`')
        $nestedBoundary.Success | Should -BeTrue
        $nestedBoundary.Groups['section'].Value.EndsWith("`n`n") | Should -BeTrue
        $content | Should -Match '(?s)### Parameter: `labelConfig.>Any_other_property<`.*?- Required: Yes'
        $content | Should -Match '(?s)### Parameter: `labelConfig.>Any_other_property<`.*?- Type: string\n\n### Parameter: `location`'
        $content | Should -Match '(?s)### Parameter: `objectConfig.tags`.*?- Type: object\n\n### Parameter: `siteConfig`'
        $content | Should -Match '(?s)### Parameter: `siteConfig`.*?- Default:\n  ```Bicep\n  \{\n      alwaysOn: true\n      ftpsState: ''FtpsOnly''\n      minTlsVersion: ''1\.2''\n  \}\n  ```'
        $siteConfigDetails = [regex]::Match(
            $content, '(?s)### Parameter: `siteConfig`(?<body>.*?)### Parameter: `siteConfig.alwaysOn`')
        $siteConfigDetails.Success | Should -BeTrue
        [regex]::Match(
            $siteConfigDetails.Groups['body'].Value,
            '  ```(?<gap>\n+)\*\*Optional parameters\*\*'
        ).Groups['gap'].Value.Length | Should -Be 2
        $objectConfigDetails = [regex]::Match(
            $content, '(?s)### Parameter: `objectConfig`(?<body>.*?)### Parameter: `objectConfig.tags`')
        $objectConfigDetails.Success | Should -BeTrue
        [regex]::Match(
            $objectConfigDetails.Groups['body'].Value,
            '  ```(?<gap>\n+)\*\*Optional parameters\*\*'
        ).Groups['gap'].Value.Length | Should -Be 2
        $content | Should -Match '(?s)### Parameter: `siteConfig.minTlsVersion`.*?- Type: string\n\n### Parameter: `siteDefaultOnly`'
        $content | Should -Match '(?s)### Parameter: `siteDefaultOnly`.*?  ```\n\n### Parameter: `tags`'
        $content | Should -Match '\| \[`trailingDescription`\].*?The trailing description\.<p> \|'
        $content | Should -Match '### Parameter: `trailingDescription`\n\nThe trailing description\.<p>\n'
        $zoneArray = [regex]::Match(
            $content, '(?s)### Parameter: `zoneArray`(?<body>.*?)### Parameter: `zoneCipher`')
        $zoneArray.Success | Should -BeTrue
        $zoneArray.Groups['body'].Value |
            Should -Match '- Default:\n  ```Bicep\n  \[\n    1\n    2\n    3\n  \]\n  ```'
        $zoneCipher = [regex]::Match(
            $content, '(?s)### Parameter: `zoneCipher`(?<body>.*?)### Parameter: `zoneEmpty`')
        $zoneCipher.Success | Should -BeTrue
        $zoneCipher.Groups['body'].Value |
            Should -Match '- Default:\n  ```Bicep\n  \[\n    ''TLS128''\n    ''TLS256''\n  \]\n  ```'
        $zoneEmpty = [regex]::Match(
            $content, '(?s)### Parameter: `zoneEmpty`(?<body>.*?)### Parameter: `searchServiceName`')
        $zoneEmpty.Success | Should -BeTrue
        $zoneEmpty.Groups['body'].Value | Should -Match '- Default: `\[\]`'
        $zoneEmpty.Groups['body'].Value | Should -Not -Match '- Default:\n  ```'
        $content | Should -Match '\*\*Optinal parameters\*\*'
        $content | Should -Match '\*\*Optonal parameters\*\*'
        $content | Should -Match '\*\*Legacy parameters\*\*'
        $content | Should -Match '### Parameter: `typoConfig.first`'
        $content | Should -Match '### Parameter: `typoConfig.second`'
        $content | Should -Match '### Parameter: `typoConfig.third`'
        $content | Should -Match '\*\*Condition parameters\*\*'
        $content | Should -Match '### Parameter: `searchServiceName`'
        $content | Should -Match '(?s)### Parameter: `searchServiceName`.*?- Default: `''''`'
        $content | Should -Match '(?s)### Parameter: `switchEnabled`.*?- Default: `True`'
        $content | Should -Match '(?s)### Parameter: `switchEnabled`.*?- Default: `True`\n\n### Parameter: `zNullable`'
        $outputGap = [regex]::Match(
            $content, '(?<gap>\n+)## Outputs').Groups['gap'].Value
        $outputGap.Length | Should -Be 2
        $content | Should -Match '(?s)### Parameter: `tags`.*?- Example:\n  ```Bicep\n  \{\n      "key1": "value1"\n  \}\n  ```'
        Test-Path -LiteralPath (Join-Path $module 'README.md') | Should -BeFalse
    }
}
