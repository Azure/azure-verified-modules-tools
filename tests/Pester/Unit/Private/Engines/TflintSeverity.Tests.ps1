#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Native AVM TFLint severity' {
    It 'keeps deferred-rule identities and demotion logic out of the module' {
        $sourcePath = Join-Path $script:moduleRoot 'Engines' 'Terraform' 'Invoke-AvmTerraformLint.ps1'
        $source = Get-Content -LiteralPath $sourcePath -Raw
        $deferredRules = @(
            'avm_azapi_data_response_export_values_required'
            'avm_azapi_response_export_values_required'
            'avm_interface_ignore_body_changes'
            'avm_interface_resource_types'
            'avm_interface_retry'
            'avm_interface_timeouts'
            'avm_output_entire_resource_disallowed'
            'avm_provider_azurerm_disallowed'
        )

        $source | Should -Not -Match 'Get-AvmDeferredAzapiRule|Test-AvmDeferredAzapiRule|AVM-DEFERRED-AZAPI'
        foreach ($rule in $deferredRules) {
            $source | Should -Not -Match ([regex]::Escape($rule)) -Because 'severity ownership belongs to TFLint configuration'
        }
    }

    It 'preserves the severity reported by TFLint for a formerly deferred rule' {
        $payload = @{
            issues = @(
                @{
                    rule    = @{ name = 'avm_provider_azurerm_disallowed'; severity = 'warning' }
                    message = "provider 'azurerm' is disallowed"
                    range   = @{ filename = 'main.tf'; start = @{ line = 4; column = 2 } }
                }
            )
        } | ConvertTo-Json -Depth 10

        $issue = InModuleScope 'Avm.Authoring' -Parameters @{ Payload = $payload } {
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
                    })).Issues[0]
        }

        $issue.Severity | Should -BeExactly 'warning'
        $issue.Code | Should -BeExactly 'avm_provider_azurerm_disallowed'
        $issue.File | Should -BeExactly 'main.tf'
        $issue.Line | Should -Be 4
        $issue.Column | Should -Be 2
    }

    It 'retains a plugin-provided notice and its source location' {
        $payload = @{
            issues = @(
                @{
                    rule    = @{ name = 'avm_output_entire_resource_disallowed'; severity = 'notice' }
                    message = 'output `resource` is an entire resource output'
                    range   = @{ filename = 'outputs.tf'; start = @{ line = 12; column = 3 } }
                }
            )
        } | ConvertTo-Json -Depth 10

        $issue = InModuleScope 'Avm.Authoring' -Parameters @{ Payload = $payload } {
            param($Payload)

            Mock Invoke-AvmProcess {
                [pscustomobject]@{ ExitCode = 0; StdOut = $Payload; StdErr = '' }
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
                    })).Issues[0]
        }

        $issue.Severity | Should -BeExactly 'notice'
        $issue.Code | Should -BeExactly 'avm_output_entire_resource_disallowed'
        $issue.File | Should -BeExactly 'outputs.tf'
        $issue.Line | Should -Be 12
        $issue.Column | Should -Be 3
    }
}
