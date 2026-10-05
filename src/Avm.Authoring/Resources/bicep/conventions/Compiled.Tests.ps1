#Requires -Version 7.4
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'leaf', Justification = 'Pester BeforeAll shares this value with It blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'description', Justification = 'Pester BeforeAll shares this value with It blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'required', Justification = 'Pester BeforeAll shares this value with It blocks.')]
param(
    [Parameter(Mandatory)]
    [System.Collections.IDictionary] $Convention
)

$cases = @($Convention.CompiledInputs | ForEach-Object { @{ Case = $_; Label = $_.Label; IssuePath = $_.IssuePath } })
$Convention.NativeCompiledExpected = 0

Describe 'Compiled Bicep: <Label>' -ForEach $cases {
    $rgSchema = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
    $requiresTelemetry = $Case.Versioned -and $Case.Resources.Count -gt 0
    $checksPrefix = $requiresTelemetry -or $Case.LegacyPrefix -or $Case.ScaffoldPrefix
    $disableChildren = $Case.Scope.ModuleType -ceq 'res' -and
    -not ($Case.Scope.IsTopLevel -and $Case.Scope.ScopeDirectories.Count -gt 0)
    $commonParameters = @('diagnosticSettings', 'roleAssignments', 'lock', 'managedIdentities', 'privateEndpoints', 'customerManagedKey')
    $commonCases = @(if ($Case.Scope.ModuleType -ceq 'res') {
            foreach ($name in $commonParameters) {
                if ($Case.TemplateParameters.Contains($name)) { @{ Name = $name } }
            }
        })
    $primaryLocations = @($Case.PrimaryResources | Where-Object {
            $_.Resource['location'] -and $_.Resource['location'] -cne 'global'
        } | ForEach-Object { @{ Resource = $_; Identifier = $_.Identifier } })
    $hasIdentity = $Case.Scope.ModuleType -ceq 'res' -and
    $Case.IdentityDefinition -is [System.Collections.IDictionary] -and
    $Case.IdentityDefinition['properties'] -is [System.Collections.IDictionary] -and
    $Case.IdentityDefinition['properties'].Contains('systemAssigned')
    $Convention.NativeCompiledExpected += 11 + (6 * $Case.Parameters.Count) +
    (4 * $Case.Definitions.psbase.Count) + $Case.Variables.psbase.Count + (2 * $Case.Outputs.psbase.Count) +
    (3 * $Case.Telemetry.Count) + $Case.Referenced.Count + $commonCases.Count + $primaryLocations.Count
    if ($Case.ArtifactInspectable) {
        $Convention.NativeCompiledExpected++
        if ($null -ne $Case.ArtifactBytes) { $Convention.NativeCompiledExpected++ }
    }
    if ($Case.Template['$schema'] -ceq $rgSchema -and $Case.TemplateParameters.Contains('location')) { $Convention.NativeCompiledExpected++ }
    if ($Case.TemplateParameters.Contains('tags')) { $Convention.NativeCompiledExpected++ }
    if ($requiresTelemetry) { $Convention.NativeCompiledExpected += 3 }
    if ($checksPrefix) { $Convention.NativeCompiledExpected += 4 }
    if ($Case.Referenced.Count -gt 0 -and $disableChildren) { $Convention.NativeCompiledExpected++ }
    if ($Case.Resources.Count -gt 0 -and $Case.Template['$schema'] -ceq $rgSchema) { $Convention.NativeCompiledExpected++ }
    if ($Case.Resources.Count -gt 0 -and $Case.Scope.ModuleType -ceq 'res') { $Convention.NativeCompiledExpected++ }
    if ($Case.PrimaryResources.Count -gt 0) { $Convention.NativeCompiledExpected += 2 }
    if ($hasIdentity) { $Convention.NativeCompiledExpected++ }

    It 'uses a current deployment schema' -Tag 'avm.bicep.compiled-schema' {
        $Case.Template['$schema'] | Should -BeIn @(
            'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
            'https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#'
            'https://schema.management.azure.com/schemas/2019-08-01/managementGroupDeploymentTemplate.json#'
            'https://schema.management.azure.com/schemas/2019-08-01/tenantDeploymentTemplate.json#'
        )
    }
    It 'uses HTTPS for the deployment schema' -Tag 'avm.bicep.compiled-schema-https' {
        [string]$Case.Template['$schema'] | Should -MatchExactly '^https://'
    }
    It 'contains the required ARM template elements' -Tag 'avm.bicep.compiled-required-fields' {
        foreach ($name in @('$schema', 'contentVersion', 'resources')) {
            $Case.Template.Contains($name) | Should -BeTrue -Because "$name is required in an ARM template"
        }
    }
    It 'has a nonempty compiled metadata name' -Tag 'avm.bicep.compiled-metadata-name' {
        $Case.Template['metadata'] | Should -BeOfType ([System.Collections.IDictionary])
        [string]$Case.Template['metadata']['name'] | Should -Not -BeNullOrEmpty
        [string]$Case.Template['metadata']['name'] | Should -Match '\S'
    }
    It 'has a nonempty compiled metadata description' -Tag 'avm.bicep.compiled-metadata-description' {
        $Case.Template['metadata'] | Should -BeOfType ([System.Collections.IDictionary])
        [string]$Case.Template['metadata']['description'] | Should -Match '\S'
    }
    It 'has a parseable ARM resource collection' -Tag 'avm.bicep.compiled-resource-shape' {
        $Case.ResourceError | Should -BeNullOrEmpty
    }
    It 'has parseable parameter and UDT schemas' -Tag 'avm.bicep.compiled-parameter-shape' {
        $Case.ParameterError | Should -BeNullOrEmpty
    }
    It 'represents compiled variables as an object' -Tag 'avm.bicep.variable-shape' {
        ($null -eq $Case.Template['variables'] -or $Case.Template['variables'] -is [System.Collections.IDictionary]) |
            Should -BeTrue
    }
    It 'represents compiled outputs as an object' -Tag 'avm.bicep.output-shape' {
        ($null -eq $Case.Template['outputs'] -or $Case.Template['outputs'] -is [System.Collections.IDictionary]) |
            Should -BeTrue
    }
    It 'does not hardcode a telemetry prefix in source' -Tag 'avm.bicep.telemetry-literal' {
        $Case.Source | Should -Not -Match '46d3xbcp\.'
    }
    It 'does not declare two metadata-backed telemetry readers' -Tag 'avm.bicep.telemetry-source' {
        ($Case.LegacyPrefix -and $Case.ScaffoldPrefix) | Should -BeFalse
    }

    if ($Case.ArtifactInspectable) {
        It 'includes the checked-in compiled template' -Tag 'avm.bicep.json-missing', 'file:main.json' {
            ($null -ne $Case.ArtifactBytes) | Should -BeTrue -Because 'run avm pre-commit and commit main.json'
        }
        if ($null -ne $Case.ArtifactBytes) {
            It 'matches the checked-in template to the compiler output' -Tag 'avm.bicep.json-stale', 'file:main.json' {
                [System.Linq.Enumerable]::SequenceEqual(
                    [byte[]]$Case.ArtifactBytes,
                    [System.Text.UTF8Encoding]::new($false).GetBytes($Case.CompiledJson)) |
                    Should -BeTrue -Because 'run avm pre-commit and commit the generated main.json'
            }
        }
    }
    if ($Case.Template['$schema'] -ceq $rgSchema -and $Case.TemplateParameters.Contains('location')) {
        It 'defaults resource-group location to the resource group or global' -Tag 'avm.bicep.parameter-location' {
            $Case.TemplateParameters['location']['defaultValue'] | Should -BeIn @('[resourceGroup().Location]', 'global')
        }
    }

    if ($Case.Parameters.Count -gt 0) {
        Context 'Parameter <Parameter.Name>' -ForEach @($Case.Parameters | ForEach-Object { @{ Parameter = $_ } }) {
            BeforeAll {
                $schema = $Parameter.Schema
                $leaf = ($Parameter.Name -split '\.')[-1]
                $description = if ($schema['metadata'] -is [System.Collections.IDictionary] -and
                    $schema['metadata']['description'] -is [string]) { $schema['metadata']['description'] } else { '' }
                $nullableDefinition = $false
                if ($schema.Contains('$ref')) {
                    $reference = [regex]::Match([string]$schema['$ref'], '^#/definitions/(?<name>.+)$')
                    $definitionName = $reference.Groups['name'].Value.Replace('~1', '/').Replace('~0', '~')
                    $nullableDefinition = $Case.Definitions[$definitionName]['nullable'] -eq $true
                }
                $required = -not $schema.Contains('defaultValue') -and $schema['nullable'] -ne $true -and -not $nullableDefinition
            }
            It 'uses camelCase unless explicitly exempted' -Tag 'avm.bicep.parameter-name' {
                $excepted = @($Case.ParameterNameExceptions | Where-Object {
                        $Case.Scope.ModuleRelativePath -clike $_['modulePathPattern'] -and $leaf -cin $_['parameters']
                    }).Count -gt 0
                ($excepted -or ($leaf -cmatch '^[a-z]' -and -not $leaf.Contains('-') -and -not $leaf.Contains('_'))) |
                    Should -BeTrue
            }
            It 'has a category and complete description' -Tag 'avm.bicep.parameter-description' {
                $description | Should -MatchExactly '(?s)^[A-Z][a-zA-Z]+\. .+\.$'
            }
            It 'explains when a conditional value is required' -Tag 'avm.bicep.parameter-condition' {
                (-not $description.StartsWith('Conditional.', [System.StringComparison]::Ordinal) -or
                $description -cmatch '\. Required if .+') | Should -BeTrue
            }
            It 'does not describe an optional value as required' -Tag 'avm.bicep.parameter-optional' {
                ($required -or -not $description.StartsWith('Required.', [System.StringComparison]::Ordinal)) | Should -BeTrue
            }
            It 'describes required values as Required or Conditional' -Tag 'avm.bicep.parameter-required' {
                (-not $required -or $description.StartsWith('Required.', [System.StringComparison]::Ordinal) -or
                $description.StartsWith('Conditional.', [System.StringComparison]::Ordinal)) | Should -BeTrue
            }
            It 'uses explicit object, UDT or resource-derived types' -Tag @(
                'avm.bicep.parameter-untyped-object'
                $(if ($Case.StrictObjects) { 'severity:error' } else { 'severity:warning' })
            ) {
                $item = $schema['items']
                $arrayOfObjects = $schema['type'] -ceq 'array' -and
                $item -is [System.Collections.IDictionary] -and $item['type'] -ceq 'object'
                $target = if ($arrayOfObjects) { $item } else { $schema }
                $derived = $target['metadata'] -is [System.Collections.IDictionary] -and
                $target['metadata'].Contains('__bicep_resource_derived_type!')
                ($schema['type'] -cne 'object' -and -not $arrayOfObjects -or
                $target.Contains('properties') -or $derived -or (-not $arrayOfObjects -and $target.Contains('$ref'))) |
                    Should -BeTrue
            }
        }

    }
    if ($Case.Definitions.psbase.Count -gt 0) {
        Context 'UDT <Name>' -ForEach @($Case.Definitions.psbase.Keys | ForEach-Object { @{ Name = $_ } }) {
            It 'has an object schema' -Tag 'avm.bicep.udt-shape' {
                $Case.Definitions[$Name] | Should -BeOfType ([System.Collections.IDictionary])
            }
            It 'is not itself an array' -Tag 'avm.bicep.udt-array' {
                ($Case.Definitions[$Name] -isnot [System.Collections.IDictionary] -or
                $Case.Definitions[$Name]['type'] -cne 'array') | Should -BeTrue
            }
            It 'is not itself nullable' -Tag 'avm.bicep.udt-nullable' {
                ($Case.Definitions[$Name] -isnot [System.Collections.IDictionary] -or
                $Case.Definitions[$Name]['nullable'] -ne $true) | Should -BeTrue
            }
            It 'uses camelCase with a Type suffix' -Tag 'avm.bicep.udt-name' {
                [string]$Name | Should -MatchExactly '^(.+\.)?[a-z][a-zA-Z0-9]*Type$'
            }
        }
    }
    if ($commonCases.Count -gt 0) {
        It 'uses a UDT reference for common parameter <Name>' -ForEach $commonCases -Tag 'avm.bicep.parameter-udt-ref' {
            $schema = $Case.TemplateParameters[$Name]
            $reference = if ($schema['items'] -is [System.Collections.IDictionary]) { $schema['items']['$ref'] } else { $schema['$ref'] }
            [string]$reference | Should -MatchExactly '^#/definitions/.+$'
        }
    }
    if ($Case.TemplateParameters.Contains('tags')) {
        It 'makes tags nullable' -Tag 'avm.bicep.parameter-tags-nullable' {
            $Case.TemplateParameters['tags']['nullable'] | Should -Be $true
        }
    }
    if ($Case.Variables.psbase.Count -gt 0) {
        It 'uses a camelCase compiled variable <Name>' -ForEach @($Case.Variables.psbase.Keys | ForEach-Object { @{ Name = $_ } }) -Tag 'avm.bicep.variable-name' {
            [string]$Name | Should -MatchExactly '^(?:[a-z]+[a-zA-Z0-9]+|\$fxv#[0-9]+)$'
        }

    }
    if ($requiresTelemetry) {
        It 'provides the standard telemetry opt-out parameter' -Tag 'avm.bicep.telemetry-parameter' {
            $parameter = $Case.TemplateParameters['enableTelemetry']
            $parameter | Should -BeOfType ([System.Collections.IDictionary])
            $parameter['type'] | Should -BeExactly 'bool'
            $parameter['defaultValue'] | Should -BeOfType ([bool])
            $parameter['defaultValue'] | Should -BeTrue
            $parameter['metadata'] | Should -BeOfType ([System.Collections.IDictionary])
            $parameter['metadata']['description'] | Should -BeExactly $Case.TelemetryDescription
        }
        It 'includes a telemetry deployment for a versioned module with resources' -Tag 'avm.bicep.telemetry-deployment' {
            $Case.Telemetry.Count | Should -BeGreaterThan 0
        }
        It 'loads the telemetry prefix from metadata.json' -Tag 'avm.bicep.telemetry-source' {
            ($Case.LegacyPrefix -or $Case.ScaffoldPrefix) | Should -BeTrue
        }
    }
    if ($Case.Telemetry.Count -gt 0) {
        Context 'Telemetry deployment <Identifier>' -ForEach @($Case.Telemetry | ForEach-Object { @{ Deployment = $_; Identifier = $_.Identifier } }) {
            It 'is gated by enableTelemetry' -Tag 'avm.bicep.telemetry-condition' {
                $Deployment.Resource['condition'] | Should -BeExactly "[parameters('enableTelemetry')]"
            }
            It 'includes the standard telemetry information output' -Tag 'avm.bicep.telemetry-output' {
                $properties = $Deployment.Resource['properties']
                $properties | Should -BeOfType ([System.Collections.IDictionary])
                $properties['template'] | Should -BeOfType ([System.Collections.IDictionary])
                $properties['template']['outputs'] | Should -BeOfType ([System.Collections.IDictionary])
                $properties['template']['outputs']['telemetry'] | Should -BeOfType ([System.Collections.IDictionary])
                $properties['template']['outputs']['telemetry']['value'] |
                    Should -BeExactly 'For more information, see https://aka.ms/avm/TelemetryInfo'
            }
            It 'starts the deployment name with the metadata-backed prefix' -Tag 'avm.bicep.telemetry-name' {
                $prefix = [regex]::Escape("variables('$($Case.PrefixName)')")
                ([string]$Deployment.Resource['name'] -cmatch "^\[format\('\{0\}[^']*'\s*,\s*$prefix\s*(?:,|\))" -or
                [string]$Deployment.Resource['name'] -cmatch "^\[concat\(\s*$prefix\s*(?:,|\))") | Should -BeTrue
            }
        }
    }
    if ($checksPrefix) {
        It 'has a regular metadata file for telemetry verification' -Tag 'avm.bicep.telemetry-metadata', 'file:metadata.json' {
            $Case.MetadataRegular | Should -BeTrue
        }
        It 'has strict JSON metadata for telemetry verification' -Tag 'avm.bicep.telemetry-metadata', 'file:metadata.json' {
            $Case.MetadataError | Should -BeNullOrEmpty
        }
        It 'provides a nonempty metadata telemetry prefix' -Tag 'avm.bicep.telemetry-metadata', 'file:metadata.json' {
            $Case.Metadata | Should -BeOfType ([System.Collections.IDictionary])
            $Case.Metadata['telemetryIdPrefix'] | Should -BeOfType ([string])
            $Case.Metadata['telemetryIdPrefix'] | Should -Match '\S'
        }
        It 'matches the compiled telemetry prefix to metadata including one variable alias' -Tag 'avm.bicep.telemetry-prefix' {
            $compiled = $Case.Variables[$Case.PrefixName]
            if ($compiled -is [string]) {
                $alias = [regex]::Match($compiled, "^\[variables\('(?<name>[^']+)'\)\]$")
                if ($alias.Success) { $compiled = $Case.Variables[$alias.Groups['name'].Value] }
            }
            [string]$compiled | Should -Match '\S'
            if ($null -ne $Case.Metadata -and $Case.Metadata['telemetryIdPrefix'] -is [string]) {
                $compiled | Should -BeExactly $Case.Metadata['telemetryIdPrefix']
            }
        }
    }
    if ($Case.Referenced.Count -gt 0 -and $disableChildren) {
        It 'disables telemetry in referenced resource modules' -Tag 'avm.bicep.telemetry-child-variable' {
            $Case.Variables['enableReferencedModulesTelemetry'] | Should -BeOfType ([bool])
            $Case.Variables['enableReferencedModulesTelemetry'] | Should -BeFalse
        }
    }
    if ($Case.Referenced.Count -gt 0) {
        It 'forwards telemetry to referenced deployment <Identifier>' -ForEach @($Case.Referenced | ForEach-Object { @{ Deployment = $_; Identifier = $_.Identifier } }) -Tag 'avm.bicep.telemetry-child-forwarding' {
            $disable = $Case.Scope.ModuleType -ceq 'res' -and
            -not ($Case.Scope.IsTopLevel -and $Case.Scope.ScopeDirectories.Count -gt 0)
            $expected = if ($disable) { "[variables('enableReferencedModulesTelemetry')]" } else { "[parameters('enableTelemetry')]" }
            $parameters = $Deployment.Resource['properties']['parameters']
            $parameters | Should -BeOfType ([System.Collections.IDictionary])
            $parameters['enableTelemetry'] | Should -BeOfType ([System.Collections.IDictionary])
            $parameters['enableTelemetry']['value'] | Should -BeExactly $expected
        }

    }
    if ($Case.Outputs.psbase.Count -gt 0) {
        Context 'Output <Name>' -ForEach @($Case.Outputs.psbase.Keys | ForEach-Object { @{ Name = $_ } }) {
            It 'uses camelCase' -Tag 'avm.bicep.output-name' {
                ([string]$Name -cmatch '^[a-z]' -and -not ([string]$Name).Contains('-') -and -not ([string]$Name).Contains('_')) |
                    Should -BeTrue
            }
            It 'has a complete-sentence description' -Tag 'avm.bicep.output-description' {
                $output = $Case.Outputs[$Name]
                $output | Should -BeOfType ([System.Collections.IDictionary])
                $output['metadata'] | Should -BeOfType ([System.Collections.IDictionary])
                [string]$output['metadata']['description'] | Should -MatchExactly '(?s)^[A-Z].+\.$'
            }
        }
    }
    if ($Case.Resources.Count -gt 0 -and $Case.Template['$schema'] -ceq $rgSchema) {
        It 'outputs the resource-group name' -Tag 'avm.bicep.output-resource-group' {
            $Case.Outputs.Contains('resourceGroupName') | Should -BeTrue
        }
    }
    if ($Case.Resources.Count -gt 0 -and $Case.Scope.ModuleType -ceq 'res') {
        It 'identifies the primary ARM resource type in the README title' -Tag 'avm.bicep.primary-resource-type', 'file:README.md' {
            $Case.PrimaryType | Should -Not -BeNullOrEmpty
        }
    }
    if ($Case.PrimaryResources.Count -gt 0) {
        It 'outputs the primary resource name' -Tag 'avm.bicep.output-name' {
            $Case.Outputs.Contains('name') | Should -BeTrue
        }
        It 'outputs the primary resource ID' -Tag 'avm.bicep.output-resourceId' {
            $Case.Outputs.Contains('resourceId') | Should -BeTrue
        }
    }
    if ($primaryLocations.Count -gt 0) {
        It 'derives location from primary resource <Identifier>' -ForEach $primaryLocations -Tag 'avm.bicep.output-location' {
            $Case.Outputs['location'] | Should -BeOfType ([System.Collections.IDictionary])
            $expression = [string]$Case.Outputs['location']['value']
            $symbol = "reference\('" + [regex]::Escape($Resource.Identifier) + "'(?:,|\))"
            ($expression.Contains($Case.PrimaryType, [System.StringComparison]::OrdinalIgnoreCase) -or
            ($Resource.Identifier -and [regex]::IsMatch($expression, $symbol))) | Should -BeTrue
        }
    }
    if ($hasIdentity) {
        It 'outputs a nullable system-assigned principal ID without an empty-string fallback' -Tag 'avm.bicep.output-principal-id' {
            $principal = $Case.Outputs['systemAssignedMIPrincipalId']
            $principal | Should -BeOfType ([System.Collections.IDictionary])
            $principal['type'] | Should -BeExactly 'string'
            $principal['nullable'] | Should -Be $true
            [string]$principal['value'] | Should -Not -MatchExactly "coalesce\(.+, ''\)"
        }
    }
}
