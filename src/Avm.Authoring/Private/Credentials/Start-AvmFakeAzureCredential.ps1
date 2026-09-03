function Start-AvmFakeAzureCredential {
    <#
    .SYNOPSIS
        Serve a synthetic Azure access token over loopback so the real Azure
        Terraform providers configure without a real credential.

    .DESCRIPTION
        The policy stage plans every example with the genuine azurerm and
        azapi providers, so the JSON it evaluates is the same document a
        credentialled 'terraform plan -out' plus 'terraform show -json'
        produces. Those providers refuse to configure until they can obtain
        an access token, so this helper serves one in the managed-identity
        response shape from a loopback socket.

        The token is an unsigned JWT carrying reserved all-zero identifiers.
        It is not a credential: nothing signs it, Azure rejects it, and it
        grants no access. A create-only plan against an empty state makes no
        Azure API calls, so the token is only ever parsed locally for the
        claims the providers read while configuring.

        The returned EnvVars also disable every ambient authentication
        method, the provider's Azure-backed enhanced validation, and
        resource-provider registration. Those are the only remaining
        provider behaviours that would otherwise reach Azure, so a policy
        plan cannot contact Azure even on a machine holding real
        credentials.

        A raw socket serves the response rather than HttpListener, which
        needs an http.sys URL reservation on Windows that an unelevated
        contributor or a locked-down runner may be unable to create.

        Callers must pass the returned object to
        Stop-AvmFakeAzureCredential.

    .PARAMETER SubscriptionId
        Subscription identifier reported to the providers.

    .PARAMETER TenantId
        Tenant identifier reported to the providers.

    .PARAMETER ClientId
        Client identifier reported to the providers.

    .PARAMETER ObjectId
        Principal identifier reported to the providers.

    .OUTPUTS
        pscustomobject with Endpoint, EnvVars, Listener, Worker and Runspace.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateNotNullOrEmpty()]
        [string] $SubscriptionId = '00000000-0000-0000-0000-000000000001',

        [ValidateNotNullOrEmpty()]
        [string] $TenantId = '00000000-0000-0000-0000-000000000002',

        [ValidateNotNullOrEmpty()]
        [string] $ClientId = '00000000-0000-0000-0000-000000000003',

        [ValidateNotNullOrEmpty()]
        [string] $ObjectId = '00000000-0000-0000-0000-000000000004'
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $issuedAt = [System.DateTimeOffset]::UtcNow
    $expiresAt = $issuedAt.AddHours(12)
    $token = New-AvmFakeAzureToken `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ObjectId $ObjectId `
        -IssuedAt $issuedAt `
        -ExpiresAt $expiresAt

    $payload = [ordered]@{
        access_token = $token
        client_id    = $ClientId
        expires_in   = [string][int]($expiresAt - $issuedAt).TotalSeconds
        expires_on   = [string]$expiresAt.ToUnixTimeSeconds()
        not_before   = [string]$issuedAt.ToUnixTimeSeconds()
        resource     = 'https://management.azure.com/'
        token_type   = 'Bearer'
    }
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes(
        (ConvertTo-Json -InputObject ([pscustomobject]$payload) -Compress))
    $headBytes = [System.Text.Encoding]::ASCII.GetBytes((
            "HTTP/1.1 200 OK`r`n" +
            "Content-Type: application/json`r`n" +
            ("Content-Length: {0}`r`n" -f $bodyBytes.Length) +
            "Connection: close`r`n`r`n"))
    $response = [byte[]]($headBytes + $bodyBytes)

    $listener = [System.Net.Sockets.TcpListener]::new(
        [System.Net.IPAddress]::Loopback,
        0)
    $listener.Start()
    $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port

    $worker = {
        param(
            [System.Net.Sockets.TcpListener] $Listener,
            [byte[]] $Response
        )

        while ($true) {
            try {
                $client = $Listener.AcceptTcpClient()
            }
            catch {
                # Stop-AvmFakeAzureCredential stops the listener, which is
                # the only supported way out of this loop.
                break
            }

            try {
                $client.ReceiveTimeout = 2000
                $client.SendTimeout = 2000
                $stream = $client.GetStream()
                $null = $stream.Read([byte[]]::new(8192), 0, 8192)
                $stream.Write($Response, 0, $Response.Length)
                $stream.Flush()
            }
            catch {
                # A client that disconnects mid-request must not take the
                # endpoint down; the provider retries token acquisition.
            }
            finally {
                $client.Close()
            }
        }
    }

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $shell = [powershell]::Create()
    $shell.Runspace = $runspace
    $null = $shell.AddScript($worker.ToString())
    $null = $shell.AddArgument($listener)
    $null = $shell.AddArgument($response)
    $null = $shell.BeginInvoke()

    $endpoint = 'http://127.0.0.1:{0}/metadata/identity/oauth2/token' -f $port
    Write-AvmLog `
        -Level Verbose `
        -Message ("policy: synthetic Azure token endpoint listening on {0}" -f $endpoint) |
        Out-Null

    return [pscustomobject]@{
        Endpoint = $endpoint
        Listener = $listener
        Worker   = $shell
        Runspace = $runspace
        EnvVars  = @{
            # Managed identity is the only provider authentication mode that
            # takes its token from a caller-supplied endpoint without
            # contacting Entra.
            ARM_USE_MSI                         = 'true'
            ARM_MSI_ENDPOINT                    = $endpoint
            ARM_SUBSCRIPTION_ID                 = $SubscriptionId
            ARM_TENANT_ID                       = $TenantId
            ARM_CLIENT_ID                       = $ClientId

            # Remove every other credential source so an ambient credential
            # can never be picked up by a policy plan.
            ARM_USE_CLI                         = 'false'
            ARM_USE_OIDC                        = 'false'
            ARM_USE_AKS_WORKLOAD_IDENTITY       = 'false'
            ARM_CLIENT_SECRET                   = $null
            ARM_CLIENT_CERTIFICATE_PATH         = $null
            ARM_CLIENT_CERTIFICATE_PASSWORD     = $null
            ARM_OIDC_TOKEN                      = $null
            ARM_OIDC_TOKEN_FILE_PATH            = $null
            ARM_OIDC_REQUEST_TOKEN              = $null
            ARM_OIDC_REQUEST_URL                = $null

            # Enhanced validation lists locations and resource providers from
            # ARM, and registration writes to the subscription.
            ARM_PROVIDER_ENHANCED_VALIDATION    = 'false'
            ARM_RESOURCE_PROVIDER_REGISTRATIONS = 'none'
            ARM_SKIP_PROVIDER_REGISTRATION      = $null
        }
    }
}
