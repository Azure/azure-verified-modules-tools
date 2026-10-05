#Requires -Version 7.4
param(
    [Parameter(Mandatory)]
    [object[]] $Validations
)

Describe 'Module metadata: <Scope>' -ForEach @($Validations | ForEach-Object { @{ Validation = $_; Scope = $_.Path } }) {
    BeforeAll {
        if ($Validation.CheckSource) {
            . $Validation.SourceParser
        }
    }
    It 'matches the packaged root or child schema' -Tag 'AVM_METADATA_SCHEMA' {
        $errors = @()
        $valid = Test-Json -Json $Validation.Json -Schema $Validation.Schemas.Shape `
            -ErrorAction SilentlyContinue -ErrorVariable errors
        $valid | Should -BeTrue -Because (@($errors | ForEach-Object { $_.Exception.Message }) -join ' ')
    }

    if ($Validation.ShapeValid) {
        It 'identifies the requested module kind' -Tag 'AVM_METADATA_KIND' {
            Test-Json -Json $Validation.Json -Schema $Validation.Schemas.Kind -ErrorAction SilentlyContinue |
                Should -BeTrue -Because 'canonicalType must identify the requested kind, or a permitted child helper'
        }

        It 'uses the ecosystem and module-kind telemetry marker' -Tag 'AVM_METADATA_TELEMETRY' {
            Test-Json -Json $Validation.Json -Schema $Validation.Schemas.Telemetry -ErrorAction SilentlyContinue |
                Should -BeTrue -Because 'current and historical telemetry prefixes must match this ecosystem and module kind'
        }

        It 'does not repeat the current telemetry prefix in its history' -Tag 'AVM_METADATA_TELEMETRY' {
            Test-Json -Json $Validation.Json -Schema $Validation.Schemas.History -ErrorAction SilentlyContinue |
                Should -BeTrue -Because 'alternativeTelemetryIdPrefixes must not contain telemetryIdPrefix'
        }

        It 'supplies telemetry when required for this scope' -Tag 'AVM_METADATA_TELEMETRY' {
            Test-Json -Json $Validation.Json -Schema $Validation.Schemas.RequiredTelemetry -ErrorAction SilentlyContinue |
                Should -BeTrue -Because 'published or instrumented non-helper modules require telemetryIdPrefix'
        }

        It 'has unique owner handles ignoring case' -Tag 'AVM_METADATA_OWNER' {
            Test-Json -Json $Validation.OwnerJson -Schema $Validation.Schemas.Owners -ErrorAction SilentlyContinue |
                Should -BeTrue -Because 'owner handles are case-insensitive'
        }

        if ($Validation.CheckSource) {
            It 'uses a regular main.bicep with exact casing when source exists' -Tag 'AVM_METADATA_SOURCE' {
                $files = @($Validation.SourceItems | Where-Object { $_.Name -ieq 'main.bicep' })
                if ($files.Count -gt 0) {
                    $files | Should -HaveCount 1
                    $files[0].Name | Should -BeExactly 'main.bicep' -Because 'main.bicep requires exact casing'
                    $files[0].PSIsContainer | Should -BeFalse
                    ($files[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint) | Should -Be 0
                }
                else {
                    $files | Should -HaveCount 0
                }
            }

            It 'includes main.bicep when version or compiled output exists' -Tag 'AVM_METADATA_SOURCE' {
                $markers = @($Validation.SourceItems | Where-Object { $_.Name -ieq 'version.json' -or $_.Name -ieq 'main.json' })
                $sources = @($Validation.SourceItems | Where-Object { $_.Name -ieq 'main.bicep' })
                ($markers.Count -eq 0 -or $sources.Count -gt 0) |
                    Should -BeTrue -Because 'main.bicep is required when version.json or main.json exists'
            }

            if ($null -ne $Validation.SourceText) {
                It 'declares a literal source metadata name' -Tag 'AVM_METADATA_SOURCE' {
                    (Get-AvmBicepMetadataLiteral -Source $Validation.SourceText -Name name)['name'] |
                        Should -BeOfType ([string])
                }

                It 'declares a literal source metadata description' -Tag 'AVM_METADATA_SOURCE' {
                    (Get-AvmBicepMetadataLiteral -Source $Validation.SourceText -Name description)['description'] |
                        Should -BeOfType ([string])
                }
            }
        }
    }
}
