#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Unit coverage for the synthetic Azure credential that lets the policy stage
# run a real 'terraform plan' without a real credential and without reaching
# Azure. These tests exercise the endpoint over loopback only; they never
# touch the network beyond 127.0.0.1.

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'New-AvmFakeAzureToken' {
    BeforeAll {
        $script:decoded = InModuleScope 'Avm.Authoring' {
            $issued = [System.DateTimeOffset]::new(2026, 1, 1, 0, 0, 0, [System.TimeSpan]::Zero)
            $token = New-AvmFakeAzureToken `
                -TenantId '11111111-1111-1111-1111-111111111111' `
                -ClientId '22222222-2222-2222-2222-222222222222' `
                -ObjectId '33333333-3333-3333-3333-333333333333' `
                -IssuedAt $issued `
                -ExpiresAt $issued.AddHours(12)

            $segments = $token -split '\.'
            $expand = {
                param([string] $Segment)
                $padded = $Segment.Replace('-', '+').Replace('_', '/')
                switch ($padded.Length % 4) {
                    2 { $padded += '==' }
                    3 { $padded += '=' }
                }
                [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($padded))
            }

            [pscustomobject]@{
                SegmentCount  = $segments.Count
                SignatureText = $segments[2]
                Header        = (& $expand $segments[0]) | ConvertFrom-Json
                Claims        = (& $expand $segments[1]) | ConvertFrom-Json
            }
        }
    }

    It 'emits three JWT segments with an empty signature' {
        # An unsigned token is the point: this must never be mistakable for a
        # credential that could authenticate anywhere.
        $script:decoded.SegmentCount | Should -Be 3
        $script:decoded.SignatureText | Should -BeNullOrEmpty
        $script:decoded.Header.alg | Should -Be 'none'
    }

    It 'carries the identifiers the Azure providers read while configuring' {
        $script:decoded.Claims.tid | Should -Be '11111111-1111-1111-1111-111111111111'
        $script:decoded.Claims.appid | Should -Be '22222222-2222-2222-2222-222222222222'
        $script:decoded.Claims.oid | Should -Be '33333333-3333-3333-3333-333333333333'
        $script:decoded.Claims.sub | Should -Be '33333333-3333-3333-3333-333333333333'
        $script:decoded.Claims.aud | Should -Be 'https://management.azure.com/'
    }

    It 'back-dates nbf so a modest clock skew cannot reject the token' {
        $script:decoded.Claims.nbf | Should -BeLessThan $script:decoded.Claims.iat
        $script:decoded.Claims.exp | Should -BeGreaterThan $script:decoded.Claims.iat
    }
}

Describe 'Start-AvmFakeAzureCredential' {
    BeforeAll {
        $script:credential = InModuleScope 'Avm.Authoring' {
            Start-AvmFakeAzureCredential
        }
    }

    AfterAll {
        InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:credential } {
            param($C)
            Stop-AvmFakeAzureCredential -Credential $C
        }
    }

    It 'listens on loopback only' {
        # Binding beyond loopback would expose the endpoint to the network.
        $script:credential.Endpoint | Should -Match '^http://127\.0\.0\.1:\d+/metadata/identity/oauth2/token$'
        ([System.Net.IPEndPoint]$script:credential.Listener.LocalEndpoint).Address.ToString() |
            Should -Be '127.0.0.1'
    }

    It 'serves a managed-identity token response the Azure providers accept' {
        $response = Invoke-RestMethod -Uri $script:credential.Endpoint -TimeoutSec 10
        $response.token_type | Should -Be 'Bearer'
        $response.resource | Should -Be 'https://management.azure.com/'
        $response.access_token | Should -Match '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.$'
        [int64]$response.expires_on | Should -BeGreaterThan ([System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    }

    It 'answers repeatedly, because each provider acquires its own token' {
        foreach ($attempt in 1..3) {
            (Invoke-RestMethod -Uri $script:credential.Endpoint -TimeoutSec 10).token_type |
                Should -Be 'Bearer' -Because "request $attempt must succeed"
        }
    }

    It 'points the providers at the loopback endpoint via managed identity' {
        $script:credential.EnvVars['ARM_USE_MSI'] | Should -Be 'true'
        $script:credential.EnvVars['ARM_MSI_ENDPOINT'] | Should -Be $script:credential.Endpoint
    }

    It 'disables every other credential source so an ambient credential cannot leak in' {
        # Without this a maintainer's az login, or a trusted runner's OIDC
        # token, would silently make the policy plan reach real Azure.
        $script:credential.EnvVars['ARM_USE_CLI'] | Should -Be 'false'
        $script:credential.EnvVars['ARM_USE_OIDC'] | Should -Be 'false'
        $script:credential.EnvVars['ARM_USE_AKS_WORKLOAD_IDENTITY'] | Should -Be 'false'
        foreach ($name in @(
                'ARM_CLIENT_SECRET'
                'ARM_CLIENT_CERTIFICATE_PATH'
                'ARM_CLIENT_CERTIFICATE_PASSWORD'
                'ARM_OIDC_TOKEN'
                'ARM_OIDC_TOKEN_FILE_PATH'
                'ARM_OIDC_REQUEST_TOKEN'
                'ARM_OIDC_REQUEST_URL'
            )) {
            $script:credential.EnvVars.ContainsKey($name) | Should -BeTrue -Because "$name must be cleared"
            $script:credential.EnvVars[$name] | Should -BeNullOrEmpty
        }
    }

    It 'disables the provider behaviours that would otherwise call Azure' {
        # Enhanced validation lists locations and resource providers from ARM;
        # registration writes to the subscription. Both must be off.
        $script:credential.EnvVars['ARM_PROVIDER_ENHANCED_VALIDATION'] | Should -Be 'false'
        $script:credential.EnvVars['ARM_RESOURCE_PROVIDER_REGISTRATIONS'] | Should -Be 'none'
        $script:credential.EnvVars['ARM_SKIP_PROVIDER_REGISTRATION'] | Should -BeNullOrEmpty
    }

    It 'uses reserved all-zero identifiers that cannot match a real tenant' {
        foreach ($name in @('ARM_SUBSCRIPTION_ID', 'ARM_TENANT_ID', 'ARM_CLIENT_ID')) {
            $script:credential.EnvVars[$name] | Should -Match '^0{8}-0{4}-0{4}-0{4}-0{11}[0-9]$'
        }
    }
}

Describe 'Test-AvmAzureCredentialAvailable' {
    It 'reports no credential when nothing is configured' {
        InModuleScope 'Avm.Authoring' {
            Test-AvmAzureCredentialAvailable -EnvVars @{
                ARM_SUBSCRIPTION_ID = '11111111-1111-1111-1111-111111111111'
                ARM_TENANT_ID       = '22222222-2222-2222-2222-222222222222'
                ARM_CLIENT_ID       = '33333333-3333-3333-3333-333333333333'
            } | Should -BeFalse
        }
    }

    It 'detects a client secret or certificate' {
        InModuleScope 'Avm.Authoring' {
            Test-AvmAzureCredentialAvailable -EnvVars @{ ARM_CLIENT_SECRET = 'secret' } |
                Should -BeTrue
            Test-AvmAzureCredentialAvailable -EnvVars @{ ARM_CLIENT_CERTIFICATE_PATH = '/tmp/cert.pfx' } |
                Should -BeTrue
        }
    }

    It 'detects OIDC only when there is something to exchange' {
        InModuleScope 'Avm.Authoring' {
            # The switch alone is how a fork-triggered run looks: no token is
            # ever minted for it, so this must not count as a credential.
            Test-AvmAzureCredentialAvailable -EnvVars @{ ARM_USE_OIDC = 'true' } |
                Should -BeFalse
            Test-AvmAzureCredentialAvailable -EnvVars @{
                ARM_USE_OIDC                   = 'true'
                ACTIONS_ID_TOKEN_REQUEST_TOKEN = 'runner-token'
            } | Should -BeTrue
        }
    }

    It 'detects managed identity and workload identity' {
        InModuleScope 'Avm.Authoring' {
            Test-AvmAzureCredentialAvailable -EnvVars @{ ARM_USE_MSI = 'true' } | Should -BeTrue
            Test-AvmAzureCredentialAvailable -EnvVars @{ ARM_USE_AKS_WORKLOAD_IDENTITY = 'true' } |
                Should -BeTrue
        }
    }

    It 'treats a disabled switch as no credential' {
        InModuleScope 'Avm.Authoring' {
            Test-AvmAzureCredentialAvailable -EnvVars @{
                ARM_USE_MSI  = 'false'
                ARM_USE_OIDC = 'false'
            } | Should -BeFalse
        }
    }
}

Describe 'Stop-AvmFakeAzureCredential' {
    It 'stops the listener so the port is released' {
        $probe = InModuleScope 'Avm.Authoring' {
            $credential = Start-AvmFakeAzureCredential
            $port = ([System.Net.IPEndPoint]$credential.Listener.LocalEndpoint).Port
            Stop-AvmFakeAzureCredential -Credential $credential

            $reachable = $true
            try {
                $client = [System.Net.Sockets.TcpClient]::new()
                $connect = $client.ConnectAsync([System.Net.IPAddress]::Loopback, $port)
                $reachable = $connect.Wait(2000) -and -not $connect.IsFaulted
                $client.Close()
            }
            catch {
                $reachable = $false
            }
            [pscustomobject]@{ Reachable = $reachable }
        }

        $probe.Reachable | Should -BeFalse
    }

    It 'tolerates a null credential so callers can clean up unconditionally' {
        # This runs from a finally block; it must never mask the real failure.
        {
            InModuleScope 'Avm.Authoring' { Stop-AvmFakeAzureCredential -Credential $null }
        } | Should -Not -Throw
    }

    It 'never throws when the endpoint was already disposed' {
        {
            InModuleScope 'Avm.Authoring' {
                $credential = Start-AvmFakeAzureCredential
                Stop-AvmFakeAzureCredential -Credential $credential
                Stop-AvmFakeAzureCredential -Credential $credential
            }
        } | Should -Not -Throw
    }
}
