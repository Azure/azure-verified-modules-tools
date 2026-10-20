#Requires -Version 7.4

BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
    Import-Module $manifest -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Terraform Azure authentication preflight' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            $script:authEnvironment = @{
                ARM_SUBSCRIPTION_ID = ''; ARM_TENANT_ID = ''; ARM_CLIENT_ID = ''
                ARM_CLIENT_SECRET = ''; ARM_CLIENT_SECRET_FILE_PATH = ''
                ARM_CLIENT_CERTIFICATE = ''; ARM_CLIENT_CERTIFICATE_PATH = ''
                ARM_USE_CLI = ''; ARM_USE_OIDC = ''; ARM_USE_MSI = ''
                ARM_USE_AKS_WORKLOAD_IDENTITY = ''
                AZURE_CLIENT_ID = ''; AZURE_TENANT_ID = ''; AZURE_FEDERATED_TOKEN_FILE = ''
            }
            $script:subscription = '11111111-1111-1111-1111-111111111111'
            $script:tenant = '22222222-2222-2222-2222-222222222222'
            Mock Resolve-AvmAzureCli {
                [pscustomobject]@{ Path = 'azure-cli'; ArgumentPrefix = @('-IBm', 'azure.cli'); EnvVars = @{ AZ_INSTALLER = 'MSI' } }
            }
            Mock Invoke-AvmProcess {
                [pscustomobject]@{
                    ExitCode = 0
                    StdOut = '{"subscriptionId":"11111111-1111-1111-1111-111111111111","tenantId":"22222222-2222-2222-2222-222222222222","state":"Enabled"}'
                    StdErr = ''
                }
            }
        }
    }

    It 'reports missing Azure CLI with actionable alternatives before any Terraform operation' {
        InModuleScope Avm.Authoring {
            Mock Resolve-AvmAzureCli { throw [AvmToolException]::new('missing CLI') }
            $caught = $null
            try { $null = Get-AvmTerraformAuthenticationEnvironment -Environment $script:authEnvironment }
            catch { $caught = $_.Exception }
            $caught.GetType().Name | Should -Be 'AvmConfigurationException'
            $caught.Message | Should -Match 'Azure CLI on PATH'
            $caught.Message | Should -Match 'az login'
            $caught.Message | Should -Match 'ARM_SUBSCRIPTION_ID'
            Should -Invoke Invoke-AvmProcess -Exactly 0
        }
    }

    It 'supplies CLI IDs to children without modifying the input environment or CLI selection' {
        InModuleScope Avm.Authoring {
            $script:authEnvironment.AZURE_CONFIG_DIR = 'example-cli-config'
            $script:authEnvironment.AZ_INSTALLER = 'overridden'
            $script:authEnvironment.TF_VAR_location = 'westus2'
            $result = Get-AvmTerraformAuthenticationEnvironment -Environment $script:authEnvironment
            $result.ARM_SUBSCRIPTION_ID | Should -Be $script:subscription
            $result.ARM_TENANT_ID | Should -Be $script:tenant
            $result.TF_VAR_location | Should -Be 'westus2'
            $script:authEnvironment.ARM_SUBSCRIPTION_ID | Should -Be ''
            $script:authEnvironment.ARM_TENANT_ID | Should -Be ''
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $FilePath -eq 'azure-cli' -and $ArgumentList[0] -eq '-IBm' -and
                $ArgumentList[2] -eq 'account' -and $ArgumentList[3] -eq 'show' -and
                $ArgumentList -notcontains 'login' -and $ArgumentList -notcontains 'set' -and
                $EnvVars.AZURE_CONFIG_DIR -eq 'example-cli-config' -and $EnvVars.AZ_INSTALLER -eq 'MSI' -and
                $TimeoutSec -eq 30 -and $IgnoreExitCode -and -not $StreamOutput
            }
        }
    }

    It 'checks an explicit subscription without selecting it globally' {
        InModuleScope Avm.Authoring {
            $script:authEnvironment.ARM_SUBSCRIPTION_ID = $script:subscription
            $null = Get-AvmTerraformAuthenticationEnvironment -Environment $script:authEnvironment
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[-2] -eq '--subscription' -and $ArgumentList[-1] -eq $script:subscription
            }
        }
    }

    It 'accepts complete non-CLI <Method> credentials without requiring Azure CLI' -ForEach @(
        @{ Method = 'secret'; Variables = @{ ARM_CLIENT_SECRET = 'synthetic-secret' } }
        @{ Method = 'secret file'; Variables = @{ ARM_CLIENT_SECRET_FILE_PATH = 'secret-file' } }
        @{ Method = 'certificate'; Variables = @{ ARM_CLIENT_CERTIFICATE_PATH = 'certificate-file' } }
        @{ Method = 'inline certificate'; Variables = @{ ARM_CLIENT_CERTIFICATE = 'synthetic-certificate' } }
        @{ Method = 'OIDC'; Variables = @{ ARM_USE_OIDC = 'true' } }
        @{ Method = 'managed identity'; Variables = @{ ARM_USE_MSI = 'true' } }
        @{ Method = 'AKS workload identity'; Variables = @{
                ARM_USE_AKS_WORKLOAD_IDENTITY = 'true'
                AZURE_CLIENT_ID = 'workload-client'; AZURE_TENANT_ID = 'workload-tenant'
                AZURE_FEDERATED_TOKEN_FILE = 'workload-token-file'
            } }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Variables = $Variables } {
            param($Variables)
            $script:authEnvironment.ARM_SUBSCRIPTION_ID = $script:subscription
            $script:authEnvironment.ARM_TENANT_ID = $script:tenant
            $script:authEnvironment.ARM_CLIENT_ID = 'test-client'
            $script:authEnvironment.ARM_USE_CLI = 'false'
            foreach ($name in $Variables.Keys) { $script:authEnvironment[$name] = $Variables[$name] }
            $result = Get-AvmTerraformAuthenticationEnvironment -Environment $script:authEnvironment
            $result.ARM_SUBSCRIPTION_ID | Should -Be $script:subscription
            Should -Invoke Resolve-AvmAzureCli -Exactly 0
            Should -Invoke Invoke-AvmProcess -Exactly 0
        }
    }

    It 'allows system-assigned managed identity without client or tenant variables' {
        InModuleScope Avm.Authoring {
            $script:authEnvironment.ARM_SUBSCRIPTION_ID = $script:subscription
            $script:authEnvironment.ARM_USE_MSI = 'true'
            $null = Get-AvmTerraformAuthenticationEnvironment -Environment $script:authEnvironment
            Should -Invoke Resolve-AvmAzureCli -Exactly 0
        }
    }

    It 'honors dotenv overrides ahead of inherited authentication variables' {
        InModuleScope Avm.Authoring {
            $original = [Environment]::GetEnvironmentVariable('ARM_CLIENT_SECRET', 'Process')
            try {
                [Environment]::SetEnvironmentVariable('ARM_CLIENT_SECRET', 'DO-NOT-PRINT-INHERITED', 'Process')
                $script:authEnvironment.Remove('ARM_CLIENT_SECRET')
                { Get-AvmTerraformAuthenticationEnvironment -Environment $script:authEnvironment } |
                    Should -Throw '*authentication is incomplete*'
                $script:authEnvironment.ARM_CLIENT_SECRET = ''
                $result = Get-AvmTerraformAuthenticationEnvironment -Environment $script:authEnvironment
                $result.ARM_SUBSCRIPTION_ID | Should -Be $script:subscription
                $result.ARM_CLIENT_SECRET | Should -Be ''
            }
            finally {
                [Environment]::SetEnvironmentVariable(
                    'ARM_CLIENT_SECRET', $(if ($null -eq $original) { [NullString]::Value } else { $original }), 'Process')
            }
        }
    }

    It 'reports incomplete <Method> inputs without falling back to Azure CLI or printing secrets' -ForEach @(
        @{ Method = 'service principal'; Variables = @{ ARM_CLIENT_SECRET = 'DO-NOT-PRINT-SECRET' }; Missing = 'ARM_SUBSCRIPTION_ID, ARM_TENANT_ID, ARM_CLIENT_ID' }
        @{ Method = 'OIDC'; Variables = @{ ARM_USE_OIDC = 'true' }; Missing = 'ARM_SUBSCRIPTION_ID, ARM_TENANT_ID, ARM_CLIENT_ID' }
        @{ Method = 'managed identity'; Variables = @{ ARM_USE_MSI = 'true' }; Missing = 'ARM_SUBSCRIPTION_ID' }
        @{ Method = 'AKS workload identity'; Variables = @{ ARM_USE_AKS_WORKLOAD_IDENTITY = 'true' }; Missing = 'AZURE_FEDERATED_TOKEN_FILE' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Variables = $Variables; Missing = $Missing } {
            param($Variables, $Missing)
            foreach ($name in $Variables.Keys) { $script:authEnvironment[$name] = $Variables[$name] }
            $caught = $null
            try { $null = Get-AvmTerraformAuthenticationEnvironment -Environment $script:authEnvironment }
            catch { $caught = $_.Exception }
            $caught.GetType().Name | Should -Be 'AvmConfigurationException'
            $caught.Message | Should -Match ([regex]::Escape($Missing))
            $caught.Message | Should -Not -Match 'DO-NOT-PRINT'
            Should -Invoke Resolve-AvmAzureCli -Exactly 0
        }
    }

    It 'rejects malformed subscriptions without echoing their values' {
        InModuleScope Avm.Authoring {
            $script:authEnvironment.ARM_SUBSCRIPTION_ID = 'DO-NOT-PRINT'
            { Get-AvmTerraformAuthenticationEnvironment -Environment $script:authEnvironment } |
                Should -Throw '*ARM_SUBSCRIPTION_ID must be a nonempty subscription GUID*'
            Should -Invoke Resolve-AvmAzureCli -Exactly 0
        }
    }

    It 'rejects disabled CLI without non-CLI credentials' {
        InModuleScope Avm.Authoring {
            $script:authEnvironment.ARM_USE_CLI = 'false'
            { Get-AvmTerraformAuthenticationEnvironment -Environment $script:authEnvironment } |
                Should -Throw '*ARM_USE_CLI disables Azure CLI*'
            Should -Invoke Resolve-AvmAzureCli -Exactly 0
        }
    }

    It 'rejects an invalid authentication flag without echoing its value' {
        InModuleScope Avm.Authoring {
            $script:authEnvironment.ARM_USE_OIDC = 'DO-NOT-PRINT'
            { Get-AvmTerraformAuthenticationEnvironment -Environment $script:authEnvironment } |
                Should -Throw "*'ARM_USE_OIDC' must be a boolean*"
            Should -Invoke Resolve-AvmAzureCli -Exactly 0
        }
    }

    It 'rejects unusable CLI account results: <Case>' -ForEach @(
        @{ Case = 'signed out'; Exit = 1; Payload = 'DO-NOT-PRINT' }
        @{ Case = 'malformed JSON'; Exit = 0; Payload = 'DO-NOT-PRINT' }
        @{ Case = 'missing account fields'; Exit = 0; Payload = '{}' }
        @{ Case = 'array instead of object'; Exit = 0; Payload = '[{"subscriptionId":"11111111-1111-1111-1111-111111111111","tenantId":"22222222-2222-2222-2222-222222222222","state":"Enabled"}]' }
        @{ Case = 'tenant-only login'; Exit = 0; Payload = '{"subscriptionId":"","tenantId":"22222222-2222-2222-2222-222222222222","state":"Enabled"}' }
        @{ Case = 'tenant ID used as subscription'; Exit = 0; Payload = '{"subscriptionId":"22222222-2222-2222-2222-222222222222","tenantId":"22222222-2222-2222-2222-222222222222","state":"Enabled"}' }
        @{ Case = 'disabled subscription'; Exit = 0; Payload = '{"subscriptionId":"11111111-1111-1111-1111-111111111111","tenantId":"22222222-2222-2222-2222-222222222222","state":"Disabled"}' }
        @{ Case = 'wrong subscription'; Exit = 0; Payload = '{"subscriptionId":"33333333-3333-3333-3333-333333333333","tenantId":"22222222-2222-2222-2222-222222222222","state":"Enabled"}' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Exit = $Exit; Payload = $Payload; Case = $Case } {
            param($Exit, $Payload, $Case)
            if ($Case -eq 'wrong subscription') {
                $script:authEnvironment.ARM_SUBSCRIPTION_ID = $script:subscription
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = $Exit; StdOut = $Payload; StdErr = 'DO-NOT-PRINT' } }
            $caught = $null
            try { $null = Get-AvmTerraformAuthenticationEnvironment -Environment $script:authEnvironment }
            catch { $caught = $_.Exception }
            $caught.GetType().Name | Should -Be 'AvmConfigurationException'
            $caught.Message | Should -Match 'Terraform Azure authentication'
            $caught.Message | Should -Not -Match 'DO-NOT-PRINT'
        }
    }

    It 'preserves an explicit tenant mismatch instead of replacing it with the CLI tenant' {
        InModuleScope Avm.Authoring {
            $script:authEnvironment.ARM_TENANT_ID = '33333333-3333-3333-3333-333333333333'
            { Get-AvmTerraformAuthenticationEnvironment -Environment $script:authEnvironment } |
                Should -Throw '*matching ARM_SUBSCRIPTION_ID/ARM_TENANT_ID*'
            $script:authEnvironment.ARM_TENANT_ID | Should -Be '33333333-3333-3333-3333-333333333333'
        }
    }

    It 'reports a broken or timed-out CLI without exposing captured native output: <Failure>' -ForEach @(
        @{ Failure = 'process' }, @{ Failure = 'timeout' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Failure = $Failure } {
            param($Failure)
            Mock Invoke-AvmProcess {
                if ($Failure -eq 'timeout') { throw [System.TimeoutException]::new('DO-NOT-PRINT') }
                throw [AvmProcessException]::new('DO-NOT-PRINT')
            }
            $caught = $null
            try { $null = Get-AvmTerraformAuthenticationEnvironment -Environment $script:authEnvironment }
            catch { $caught = $_.Exception }
            $caught.GetType().Name | Should -Be 'AvmConfigurationException'
            $caught.Message | Should -Match 'Terraform Azure authentication'
            $caught.Message | Should -Not -Match 'DO-NOT-PRINT'
        }
    }
}
