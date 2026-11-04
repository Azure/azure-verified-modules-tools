#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    & (Join-Path $PSScriptRoot '..' '..' '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $moduleRoot 'Avm.Authoring.psd1')
    & (Get-Module Avm.Authoring) {
        function script:Invoke-AzRestMethod {
            [CmdletBinding()]
            param($Method, $Path, $DefaultProfile)
            throw 'Unexpected Azure request.'
        }
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Bicep deployment diagnostics' {
    It 'redacts parameter values, secure strings, connection strings, bearer tokens and SAS values' {
        InModuleScope Avm.Authoring {
            $secure = ConvertTo-SecureString 'hidden-password' -AsPlainText -Force
            $secrets = @(Get-AvmBicepDiagnosticSecret -Parameters @{
                    password = $secure; nested = [pscustomobject]@{ item = 'private-value' }
                } -SecretInputs @{ CI_KEY = 'secret-from-ci' })
            $message = 'VaultNameNotValid: vault is too long; hidden-password private-value secret-from-ci; ' +
            'AccountKey=abcdef; sig=ABC123&sp=r; Authorization: Bearer abc.def.ghi; token="other-secret"'
            $actual = Protect-AvmBicepDiagnosticText -Text $message -SensitiveValues $secrets
            $actual | Should -Match 'VaultNameNotValid'
            foreach ($value in @('hidden-password', 'private-value', 'secret-from-ci', 'abcdef', 'ABC123', 'abc.def.ghi', 'other-secret')) {
                $actual | Should -Not -Match ([regex]::Escape($value))
            }
            $actual | Should -Match '\[REDACTED\]'
        }
    }

    It 'limits and sanitizes diagnostic text' {
        InModuleScope Avm.Authoring {
            (Protect-AvmBicepDiagnosticText -Text ('a' * 3000)).Length | Should -BeLessOrEqual 2060
            Protect-AvmBicepDiagnosticText -Text ('a' * 65537) | Should -Match 'omitted'
            Protect-AvmBicepDiagnosticText -Text "first`nsecond" | Should -BeExactly 'first second'
        }
    }

    It 'redacts encoded supplied secrets, basic authorization and JSON credential fields' {
        InModuleScope Avm.Authoring {
            $secret = 'fixture "private" value'
            $base64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($secret))
            $escaped = [uri]::EscapeDataString($secret)
            $jsonEscaped = (ConvertTo-Json -InputObject $secret -Compress).Trim('"')
            $message = "cause $base64 $escaped $jsonEscaped; Authorization: Basic Zml4dHVyZQ==; " +
            '{"client_secret":"a\"quoted-value","access_token":"example-token"}; sig=sample-signature'
            $actual = Protect-AvmBicepDiagnosticText -Text $message -SensitiveValues @($secret)
            foreach ($value in @($base64, $escaped, $jsonEscaped, 'Zml4dHVyZQ==', 'quoted-value', 'example-token', 'sample-signature')) {
                $actual | Should -Not -Match ([regex]::Escape($value))
            }
            $actual | Should -Match 'cause'
        }
    }

    It 'reports nested error details and correlation while confirming the exact failed deployment' {
        InModuleScope Avm.Authoring {
            $script:diagnosticMessages = [Collections.Generic.List[string]]::new()
            $id = '/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.Resources/deployments/test'
            $childId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Resources/deployments/child'
            Mock Write-AvmLog { $script:diagnosticMessages.Add($Message) }
            Mock Invoke-AzRestMethod {
                $body = if ($Path -like "$childId/operations?*") {
                    @{
                        value = @(@{ properties = @{
                                    provisioningState = 'Failed'
                                    statusMessage = @{ error = @{ code = 'NestedFailure'; message = 'nested cause' } }
                                } })
                    }
                }
                elseif ($Path -like '*/operations?*') {
                    @{
                        value = @(@{ properties = @{
                                    provisioningState = 'Failed'
                                    targetResource = @{ id = $childId; resourceType = 'Microsoft.Resources/deployments' }
                                    statusMessage = @{ error = @{
                                            code = 'DeploymentFailed'
                                            details = @(@{ code = 'VaultNameNotValid'; message = 'The vault name is invalid; password=secret'; target = 'vault' })
                                        } }
                                } })
                    }
                }
                else {
                    @{ id = $id; properties = @{ provisioningState = 'Failed'; correlationId = '12345678-1234-1234-1234-123456789abc' } }
                }
                @{ StatusCode = 200; Content = ($body | ConvertTo-Json -Depth 20 -Compress) }
            }
            $result = Write-AvmBicepDeploymentDiagnostic -DeploymentId $id -ReadDeployment
            $result | Should -BeExactly 'Failed'
            $text = $script:diagnosticMessages -join "`n"
            $text | Should -Match 'VaultNameNotValid'
            $text | Should -Match 'The vault name is invalid'
            $text | Should -Match 'target: vault'
            $text | Should -Match 'NestedFailure'
            $text | Should -Match 'nested cause'
            $text | Should -Match '12345678-1234-1234-1234-123456789abc'
            $text | Should -Not -Match 'password=secret'
            Should -Invoke Invoke-AzRestMethod -Exactly 3
        }
    }

    It 'does not confirm a different deployment or read its operations' {
        InModuleScope Avm.Authoring {
            Mock Write-AvmLog {}
            Mock Invoke-AzRestMethod {
                @{ StatusCode = 200; Content = '{"id":"/wrong","properties":{"provisioningState":"Failed"}}' }
            }
            $result = Write-AvmBicepDeploymentDiagnostic -DeploymentId '/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.Resources/deployments/test' -ReadDeployment
            $result | Should -BeExactly ''
            Should -Invoke Invoke-AzRestMethod -Exactly 1
            Should -Invoke Write-AvmLog -Exactly 1 -ParameterFilter { $Message -match 'could not be read' }
        }
    }

    It 'reports and redacts a failed operation with a plain-text status message' {
        InModuleScope Avm.Authoring {
            $id = '/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.Resources/deployments/test'
            $script:diagnosticMessages = [Collections.Generic.List[string]]::new()
            Mock Write-AvmLog { $script:diagnosticMessages.Add($Message) }
            Mock Invoke-AzRestMethod {
                $body = if ($Path -like '*/operations?*') {
                    @{ value = @(@{ properties = @{ provisioningState = 'Failed'; statusMessage = 'Invalid target: secret=fixture-value' } }) }
                }
                else { @{ id = $id; properties = @{ provisioningState = 'Failed' } } }
                @{ StatusCode = 200; Content = ($body | ConvertTo-Json -Depth 20 -Compress) }
            }
            $null = Write-AvmBicepDeploymentDiagnostic -DeploymentId $id -ReadDeployment
            $text = $script:diagnosticMessages -join ' '
            $text | Should -Match 'Invalid target'
            $text | Should -Not -Match 'fixture-value'
        }
    }

    It 'uses the captured profile for all reads and does not traverse a foreign nested deployment' {
        InModuleScope Avm.Authoring {
            $id = '/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.Resources/deployments/test'
            $foreign = '/subscriptions/00000000-0000-0000-0000-000000000002/providers/Microsoft.Resources/deployments/foreign'
            $script:profile = @{ Tenant = @{ Id = 'original-tenant' } }
            Mock Write-AvmLog {}
            Mock Invoke-AzRestMethod {
                $body = if ($Path -like '*/operations?*') {
                    @{ value = @(@{ properties = @{
                                    provisioningState = 'Failed'
                                    targetResource = @{ id = $foreign; resourceType = 'Microsoft.Resources/deployments' }
                                } }) }
                }
                else { @{ id = $id; properties = @{ provisioningState = 'Failed' } } }
                @{ StatusCode = 200; Content = ($body | ConvertTo-Json -Depth 20 -Compress) }
            }
            (Write-AvmBicepDeploymentDiagnostic -DeploymentId $id -ReadDeployment -DefaultProfile $script:profile) |
                Should -BeExactly 'Failed'
            Should -Invoke Invoke-AzRestMethod -Exactly 2 -ParameterFilter {
                [object]::ReferenceEquals($DefaultProfile, $script:profile)
            }
            Should -Invoke Invoke-AzRestMethod -Exactly 0 -ParameterFilter { $Path -like "$foreign/*" }
        }
    }
}
