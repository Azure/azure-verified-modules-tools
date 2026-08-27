#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# AVM-DEFERRED-AZAPI. Guard tests for the deferred rule demotion.
#
# These rules stay enabled in the packaged TFLint configurations and are demoted
# from 'error' to 'notice' at parse time, so they are reported on every run
# without failing the gate. The list covers three families: the TFFR6/7/8 AzAPI
# interface rules, the TFFR3 provider rule, and the TFFR2 output-shape rule. See
# issue #80 for the re-enable path.
#
# The list is pinned here on purpose: restoring enforcement for a rule should be
# a deliberate, reviewed change that updates this test alongside
# Get-AvmDeferredAzapiRule, not something that drifts silently.

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmDeferredAzapiRule' {
    It 'pins exactly the rules currently deferred' {
        $expected = @(
            'azapi_data_response_export_values'
            'azapi_response_export_values'
            'ignore_body_changes'
            'no_entire_resource_output_tffr2'
            'provider_azurerm_disallowed'
            'resource_types'
            'retry'
            'timeouts'
        )

        $actual = @(InModuleScope 'Avm.Authoring' { Get-AvmDeferredAzapiRule })

        ($actual | Sort-Object) -join ',' |
            Should -BeExactly (($expected | Sort-Object) -join ',') -Because 'restoring enforcement should update this test and Get-AvmDeferredAzapiRule together'
    }

    It 'returns no duplicates' {
        $actual = @(InModuleScope 'Avm.Authoring' { Get-AvmDeferredAzapiRule })
        @($actual | Sort-Object -Unique).Count | Should -Be $actual.Count
    }
}

Describe 'Test-AvmDeferredAzapiRule' {
    It 'matches every deferred rule' {
        $rules = @(InModuleScope 'Avm.Authoring' { Get-AvmDeferredAzapiRule })
        foreach ($rule in $rules) {
            InModuleScope 'Avm.Authoring' -Parameters @{ Code = $rule } {
                param($Code)
                Test-AvmDeferredAzapiRule -Code $Code
            } | Should -BeTrue -Because "$rule is deferred"
        }
    }

    It 'does not match an unrelated rule' {
        foreach ($code in @('terraform_unused_declarations', 'deprecated_lock_interface', 'provider_modtm_version_constraint')) {
            InModuleScope 'Avm.Authoring' -Parameters @{ Code = $code } {
                param($Code)
                Test-AvmDeferredAzapiRule -Code $Code
            } | Should -BeFalse -Because "$code must keep failing the gate"
        }
    }

    It 'does not match an empty or whitespace code' {
        foreach ($code in @('', '   ')) {
            InModuleScope 'Avm.Authoring' -Parameters @{ Code = $code } {
                param($Code)
                Test-AvmDeferredAzapiRule -Code $Code
            } | Should -BeFalse
        }
    }

    It 'matches case-sensitively' {
        InModuleScope 'Avm.Authoring' {
            Test-AvmDeferredAzapiRule -Code 'Provider_AzureRM_Disallowed'
        } | Should -BeFalse -Because 'tflint rule names are lowercase, so a cased variant is a different rule'
    }
}

Describe 'Invoke-AvmTflintScope severity demotion' {
    BeforeAll {
        # Minimal tflint --format=json payload: one deferred rule reported as an
        # error, one unrelated rule reported as an error.
        $script:payload = @{
            issues = @(
                @{
                    rule    = @{ name = 'provider_azurerm_disallowed'; severity = 'error' }
                    message = "provider 'azurerm' (source hashicorp/azurerm) is disallowed"
                    range   = @{ filename = 'main.tf'; start = @{ line = 1; column = 1 } }
                },
                @{
                    rule    = @{ name = 'terraform_unused_declarations'; severity = 'error' }
                    message = 'variable "unused" is declared but not used'
                    range   = @{ filename = 'variables.tf'; start = @{ line = 7; column = 1 } }
                }
            )
        } | ConvertTo-Json -Depth 10
    }

    It 'demotes a deferred rule to notice and leaves other rules alone' {
        $issues = @(InModuleScope 'Avm.Authoring' -Parameters @{ Payload = $script:payload } {
                param($Payload)

                Mock Invoke-AvmProcess {
                    [pscustomobject]@{ ExitCode = 2; StdOut = $Payload; StdErr = '' }
                }

                $scope = [pscustomobject]@{
                    Label   = 'root'
                    RelPath = '.'
                    Dir     = "$TestDrive"
                    Config  = 'unused.hcl'
                }

                (Invoke-AvmTflintScope -Scope $scope -Options ([pscustomobject]@{
                            TflintPath             = 'tflint'
                            MinimumFailureSeverity = 'warning'
                            StreamOutput           = $false
                        })).Issues
            })

        $deferred = $issues | Where-Object Code -eq 'provider_azurerm_disallowed'
        $other = $issues | Where-Object Code -eq 'terraform_unused_declarations'

        $deferred | Should -Not -BeNullOrEmpty -Because 'the finding must still be reported, not dropped'
        $deferred.Severity | Should -BeExactly 'notice'
        $deferred.File | Should -BeExactly 'main.tf'
        $deferred.Line | Should -Be 1

        $other | Should -Not -BeNullOrEmpty
        $other.Severity | Should -BeExactly 'error' -Because 'only the deferred rules are demoted'
    }

    It 'demotes no_entire_resource_output_tffr2 to notice and leaves other rules alone' {
        # TFFR2 is a Severity-SHOULD spec point that the ruleset reports as ERROR,
        # so it hard-failed the gate in about 38% of the fleet.
        $payload = @{
            issues = @(
                @{
                    rule    = @{ name = 'no_entire_resource_output_tffr2'; severity = 'error' }
                    message = 'output `resource` is an entire resource output'
                    range   = @{ filename = 'outputs.tf'; start = @{ line = 12; column = 3 } }
                },
                @{
                    rule    = @{ name = 'azapi_resource_tag'; severity = 'error' }
                    message = '`tags` is not defined in azapi_resource'
                    range   = @{ filename = 'main.tf'; start = @{ line = 4; column = 1 } }
                }
            )
        } | ConvertTo-Json -Depth 10

        $issues = @(InModuleScope 'Avm.Authoring' -Parameters @{ Payload = $payload } {
                param($Payload)

                Mock Invoke-AvmProcess {
                    [pscustomobject]@{ ExitCode = 2; StdOut = $Payload; StdErr = '' }
                }

                $scope = [pscustomobject]@{
                    Label   = 'root'
                    RelPath = '.'
                    Dir     = "$TestDrive"
                    Config  = 'unused.hcl'
                }

                (Invoke-AvmTflintScope -Scope $scope -Options ([pscustomobject]@{
                            TflintPath             = 'tflint'
                            MinimumFailureSeverity = 'warning'
                            StreamOutput           = $false
                        })).Issues
            })

        $deferred = $issues | Where-Object Code -eq 'no_entire_resource_output_tffr2'
        $other = $issues | Where-Object Code -eq 'azapi_resource_tag'

        $deferred | Should -Not -BeNullOrEmpty -Because 'the finding must still be reported with its location, not dropped'
        $deferred.Severity | Should -BeExactly 'notice'
        $deferred.File | Should -BeExactly 'outputs.tf'
        $deferred.Line | Should -Be 12
        $deferred.Column | Should -Be 3

        $other | Should -Not -BeNullOrEmpty
        $other.Severity | Should -BeExactly 'error' -Because 'azapi_resource_tag was enforced before 0.10.0 and still fails the gate'
    }
}
