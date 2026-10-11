#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force

    function Invoke-NativeCompiledFixture {
        param($Template, $Scope, [string]$Root)

        $run = InModuleScope Avm.Authoring -Parameters @{ T = $Template; S = $Scope; R = $Root } {
            param($T, $S, $R)
            $json = ConvertTo-Json -InputObject $T -Depth 100
            [System.IO.File]::WriteAllText((Join-Path $R 'main.json'), $json, [System.Text.UTF8Encoding]::new($false))
            $module = [pscustomobject]@{ Template = $T; Scope = $S; Path = Join-Path $R 'main.bicep'; Json = $json }
            $convention = @{
                Root                   = $R
                CompiledInputs         = @(Get-AvmBicepCompiledConventionInput -Module $module)
                NativeCompiledExpected = 0
            }
            $suite = Join-Path (Get-Module Avm.Authoring).ModuleBase 'Resources' 'bicep' 'conventions' 'Compiled.Tests.ps1'
            $summary = Invoke-AvmBicepPesterSuite -Files @($suite) -WorkingDirectory $R `
                -Mode Convention -ConventionData $convention -EnvVars @{} -InProcess
            @{ Summary = $summary; Expected = $convention.NativeCompiledExpected }
        }
        @($run.Summary.Issues | Where-Object { $_.Code -like 'avm.bicep.pester-*' }).Count |
            Should -Be 0 -Because (@($run.Summary.Issues | ForEach-Object { $_.Message }) -join '; ')
        $run.Expected | Should -BeGreaterThan 11
        $run.Summary.Total | Should -Be $run.Expected
        ($run.Summary.Passed + $run.Summary.Failed) | Should -Be $run.Expected
        return $run.Summary.Issues
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: native compiled Bicep requirements' -Tag Component {
    BeforeEach {
        Set-Content -LiteralPath (Join-Path $TestDrive 'main.bicep') -Value '' -Encoding utf8NoBOM
        $script:scope = [pscustomobject]@{
            Path               = $TestDrive
            ModuleType         = 'res'
            ModuleRelativePath = 'avm/res/mock/widget'
            IsTopLevel         = $true
            ScopeDirectories   = @()
        }
        $script:template = [ordered]@{
            '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
            contentVersion = '1.0.0.0'
            metadata       = @{ name = 'Mock widget'; description = 'Deploys a mock widget.' }
            resources      = @()
            parameters     = [ordered]@{
                settings = [ordered]@{
                    '$ref'   = '#/definitions/settingsType'
                    metadata = @{ description = 'Required. Widget settings.' }
                }
            }
            definitions    = [ordered]@{
                settingsType = [ordered]@{
                    type       = 'object'
                    properties = [ordered]@{
                        enabled       = [ordered]@{
                            type     = 'bool'
                            metadata = @{ description = 'Required. Enable the widget.' }
                        }
                        optionalCount = [ordered]@{
                            type     = 'int'
                            nullable = $true
                            metadata = @{ description = 'Optional. Number of widgets.' }
                        }
                        items         = [ordered]@{
                            type         = 'array'
                            defaultValue = @()
                            items        = [ordered]@{
                                type       = 'object'
                                properties = [ordered]@{
                                    childValue = [ordered]@{
                                        type     = 'string'
                                        metadata = @{ description = 'Conditional. Required if enabled.' }
                                    }
                                }
                            }
                            metadata     = @{ description = 'Optional. Widget items.' }
                        }
                    }
                }
            }
        }
    }

    It 'flattens referenced UDTs and array item properties without treating the UDT as a top-level parameter' {
        $template = $script:template
        $names = InModuleScope 'Avm.Authoring' -Parameters @{ T = $template } {
            param($T)
            @(Get-AvmBicepConventionParameter -Template $T).Name
        }

        $names | Should -Contain 'settings'
        $names | Should -Contain 'settings.enabled'
        $names | Should -Contain 'settings.optionalCount'
        $names | Should -Contain 'settings.items'
        $names | Should -Contain 'settings.items.childValue'
        $names | Should -Not -Contain 'settingsType'
    }

    It 'accepts well-described required and nullable nested properties' {
        $template = $script:template
        $scope = $script:scope
        $issues = @(Invoke-NativeCompiledFixture -Template $template -Scope $scope -Root $TestDrive)

        $issues.Count | Should -Be 0
    }

    It 'rejects an empty compiled metadata <Property>' -TestCases @(
        @{ Property = 'name' }
        @{ Property = 'description' }
    ) {
        param($Property)
        $script:template['metadata'][$Property] = ' '
        $issues = @(Invoke-NativeCompiledFixture -Template $script:template -Scope $script:scope -Root $TestDrive)
        $issues.Code | Should -Contain "avm.bicep.compiled-metadata-$Property"
    }

    It 'names bad nested parameter casing, requiredness, and conditional descriptions' {
        $properties = $script:template['definitions']['settingsType']['properties']
        $properties['Bad_name'] = [ordered]@{
            type = 'bool'; metadata = @{ description = 'Conditional. Unclear.' }
        }
        $properties['optionalCount']['metadata']['description'] = 'Required. A value.'
        $template = $script:template
        $scope = $script:scope
        $issues = @(Invoke-NativeCompiledFixture -Template $template -Scope $scope -Root $TestDrive)

        $issues.Code | Should -Contain 'avm.bicep.parameter-name'
        $issues.Code | Should -Contain 'avm.bicep.parameter-condition'
        $issues.Code | Should -Contain 'avm.bicep.parameter-optional'
        @($issues | Where-Object Code -EQ 'avm.bicep.parameter-name')[0].Message |
            Should -Match 'settings.Bad_name'
    }

    It 'requires a description sentence and a requiredness prefix for nonnullable parameters' {
        $script:template['parameters']['settings']['metadata']['description'] = 'widget settings'
        $template = $script:template
        $scope = $script:scope
        $issues = @(Invoke-NativeCompiledFixture -Template $template -Scope $scope -Root $TestDrive)

        $issues.Code | Should -Contain 'avm.bicep.parameter-description'
        $issues.Code | Should -Contain 'avm.bicep.parameter-required'
    }

    It 'resolves discriminator variants and checks their nested properties' {
        $script:template['parameters']['variant'] = @{
            '$ref'   = '#/definitions/variantType'
            metadata = @{ description = 'Required. Widget variant.' }
        }
        $script:template['definitions']['variantType'] = @{
            type          = 'object'
            discriminator = @{
                propertyName = 'kind'; mapping = @{ one = '#/definitions/firstVariantType' }
            }
        }
        $script:template['definitions']['firstVariantType'] = @{
            type       = 'object'
            properties = @{
                'Bad_name' = @{
                    type = 'string'; metadata = @{ description = 'Required. Variant value.' }
                }
            }
        }
        $template = $script:template
        $scope = $script:scope
        $issues = @(Invoke-NativeCompiledFixture -Template $template -Scope $scope -Root $TestDrive)

        @($issues | Where-Object {
                $_.Code -eq 'avm.bicep.parameter-name' -and
                $_.Message -match 'variant.one.Bad_name'
            }).Count | Should -Be 1
    }

    It 'does not mark a reference to a nullable definition as a required parameter' {
        $script:template['definitions']['settingsType']['nullable'] = $true
        $script:template['parameters']['settings']['metadata']['description'] = 'Optional. Widget settings.'
        $template = $script:template
        $scope = $script:scope
        $issues = @(Invoke-NativeCompiledFixture -Template $template -Scope $scope -Root $TestDrive)

        $issues.Code | Should -Contain 'avm.bicep.udt-nullable'
        $issues.Code | Should -Not -Contain 'avm.bicep.parameter-required'
    }

    It 'warns for untyped objects before version 1 and fails them at version 1' {
        $script:template['parameters']['untyped'] = [ordered]@{
            type         = 'object'
            defaultValue = @{}
            metadata     = @{ description = 'Optional. Untyped configuration.' }
        }
        $script:template['parameters']['untypedItems'] = [ordered]@{
            type         = 'array'
            defaultValue = @()
            items        = @{ type = 'object' }
            metadata     = @{ description = 'Optional. Untyped array.' }
        }
        $template = $script:template
        $scope = $script:scope
        Set-Content -LiteralPath (Join-Path $TestDrive 'version.json') -Value '{"version":"0.1"}' -Encoding utf8NoBOM
        $warning = @(Invoke-NativeCompiledFixture -Template $template -Scope $scope -Root $TestDrive)
        Set-Content -LiteralPath (Join-Path $TestDrive 'version.json') -Value '{"version":"1.0"}' -Encoding utf8NoBOM
        $enforced = @(Invoke-NativeCompiledFixture -Template $template -Scope $scope -Root $TestDrive)
        $results = [pscustomobject]@{ Warning = $warning; Enforced = $enforced }

        @($results.Warning | Where-Object Code -EQ 'avm.bicep.parameter-untyped-object').Count |
            Should -Be 2
        @($results.Warning | Where-Object Severity -EQ 'warning').Count | Should -Be 2
        @($results.Enforced | Where-Object Code -EQ 'avm.bicep.parameter-untyped-object').Count |
            Should -Be 2
        @($results.Enforced | Where-Object Severity -EQ 'error').Count | Should -Be 2
    }

    It 'requires resource interface UDT references and nullable tags' {
        $script:template['parameters']['managedIdentities'] = [ordered]@{
            type       = 'object'
            properties = @{}
            metadata   = @{ description = 'Required. Managed identities.' }
        }
        $script:template['parameters']['tags'] = [ordered]@{
            type       = 'object'
            properties = @{}
            metadata   = @{ description = 'Required. Resource tags.' }
        }
        $template = $script:template
        $scope = $script:scope
        $issues = @(Invoke-NativeCompiledFixture -Template $template -Scope $scope -Root $TestDrive)

        $issues.Code | Should -Contain 'avm.bicep.parameter-udt-ref'
        $issues.Code | Should -Contain 'avm.bicep.parameter-tags-nullable'
        $template['parameters']['managedIdentities'] = @{
            '$ref' = '#/definitions/settingsType'
            metadata = @{ description = 'Required. Managed identities.' }
        }
        $template['parameters']['tags']['nullable'] = $true
        $template['parameters']['tags']['metadata']['description'] = 'Optional. Resource tags.'
        @(Invoke-NativeCompiledFixture -Template $template -Scope $scope -Root $TestDrive).Count |
            Should -Be 0
    }

    It 'rejects array, nullable, and incorrectly named UDT definitions' {
        $script:template['parameters'].Clear()
        $script:template['definitions']['Bad_type'] = @{
            type = 'array'; nullable = $true
        }
        $script:template['definitions']['bad_nameType'] = @{
            type = 'object'; properties = @{}
        }
        $template = $script:template
        $scope = $script:scope
        $issues = @(Invoke-NativeCompiledFixture -Template $template -Scope $scope -Root $TestDrive)

        $issues.Code | Should -Contain 'avm.bicep.udt-array'
        $issues.Code | Should -Contain 'avm.bicep.udt-nullable'
        @($issues | Where-Object Code -EQ 'avm.bicep.udt-name').Count | Should -Be 2
    }

    It 'normalizes array and symbolic ARM resources and rejects malformed entries' {
        $template = $script:template
        $items = InModuleScope 'Avm.Authoring' -Parameters @{ T = $template } {
            param($T)
            $T['resources'] = @(@{ type = 'Microsoft.Mock/widgets' })
            $legacy = @(Get-AvmBicepConventionResource -Template $T)
            $T['languageVersion'] = '2.0'
            $T['resources'] = [ordered]@{ widget = @{ type = 'Microsoft.Mock/widgets' } }
            $symbolic = @(Get-AvmBicepConventionResource -Template $T)
            [pscustomobject]@{ Legacy = $legacy; Symbolic = $symbolic }
        }

        $items.Legacy.Count | Should -Be 1
        $items.Legacy[0].Identifier | Should -Be ''
        $items.Symbolic.Count | Should -Be 1
        $items.Symbolic[0].Identifier | Should -Be 'widget'
        InModuleScope 'Avm.Authoring' -Parameters @{ T = $template } {
            param($T)
            $T['resources'] = @{ bad = 'not a resource' }
            { Get-AvmBicepConventionResource -Template $T } |
                Should -Throw '*must be an object*'
        }
    }

    It 'requires a nullable string principal-ID output without an empty fallback' {
        $script:template['parameters']['managedIdentities'] = @{
            '$ref'   = '#/definitions/managedIdentitiesType'
            metadata = @{ description = 'Required. Managed identities.' }
        }
        $script:template['definitions']['managedIdentitiesType'] = @{
            type = 'object'; properties = @{
                systemAssigned = @{
                    type = 'bool'; defaultValue = $false
                    metadata = @{ description = 'Optional. Enable system-assigned identity.' }
                }
            }
        }
        $template = $script:template
        $scope = $script:scope
        $template['outputs'] = @{}
        $missing = @(Invoke-NativeCompiledFixture -Template $template -Scope $scope -Root $TestDrive)
        $template['outputs']['systemAssignedMIPrincipalId'] = @{
            type = 'string'; nullable = $true; value = "[coalesce(variables('principal'), '')]"
            metadata = @{ description = 'The principal ID.' }
        }
        $fallback = @(Invoke-NativeCompiledFixture -Template $template -Scope $scope -Root $TestDrive)
        $template['outputs']['systemAssignedMIPrincipalId']['value'] = "[variables('principal')]"
        $valid = @(Invoke-NativeCompiledFixture -Template $template -Scope $scope -Root $TestDrive)
        $issues = [pscustomobject]@{ Missing = $missing; Fallback = $fallback; Valid = $valid }

        $issues.Missing.Code | Should -Contain 'avm.bicep.output-principal-id'
        $issues.Fallback.Code | Should -Contain 'avm.bicep.output-principal-id'
        $issues.Valid.Count | Should -Be 0
    }
}
