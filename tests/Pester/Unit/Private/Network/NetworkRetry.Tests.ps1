#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Shared network retry' {
    BeforeAll {
        $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..')
        Import-Module (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    }

    AfterAll {
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $script:savedOverride = $env:AVM_NETWORK_RETRY_MAX_ATTEMPTS
        Remove-Item Env:AVM_NETWORK_RETRY_MAX_ATTEMPTS -ErrorAction SilentlyContinue
        InModuleScope 'Avm.Authoring' {
            Mock Wait-AvmRetryDelay
            Mock Write-Warning
        }
    }

    AfterEach {
        [Environment]::SetEnvironmentVariable('AVM_NETWORK_RETRY_MAX_ATTEMPTS', $script:savedOverride)
    }

    Context 'Invoke-AvmRetry' {
        It 'retries transient failures and returns the eventual result' {
            InModuleScope 'Avm.Authoring' {
                $state = @{ Calls = 0 }
                $result = Invoke-AvmRetry -RetryActivity 'probe' -RetryAction {
                    $state.Calls++
                    if ($state.Calls -lt 3) { throw [System.TimeoutException]::new('The operation has timed out.') }
                    'ok'
                }

                $result | Should -Be 'ok'
                $state.Calls | Should -Be 3
                Should -Invoke Wait-AvmRetryDelay -Exactly 2
            }
        }

        It 'stops at the configured limit and rethrows the original error' {
            InModuleScope 'Avm.Authoring' {
                $state = @{ Calls = 0 }
                $thrown = $null
                try {
                    Invoke-AvmRetry -RetryActivity 'probe' -RetryAction {
                        $state.Calls++
                        throw [System.Net.Http.HttpRequestException]::new('Connection refused')
                    }
                }
                catch { $thrown = $_.Exception }

                $thrown | Should -BeOfType ([System.Net.Http.HttpRequestException])
                $state.Calls | Should -Be (Get-AvmNetworkRetryPolicy).MaxAttempts
                Should -Invoke Write-Warning -Exactly 1 -ParameterFilter { $Message -match 'failed after 4 attempts' }
            }
        }

        It 'does not retry <Name>' -TestCases @(
            @{ Name = 'a permanent error'; Factory = "[System.ArgumentException]::new('bad input')" }
            @{ Name = 'an authentication failure'; Factory = "[System.Security.Authentication.AuthenticationException]::new('timed out validating credentials')" }
            @{ Name = 'cancellation'; Factory = '[System.OperationCanceledException]::new()' }
            @{ Name = 'a killed process timeout'; Factory = "`$e = [System.TimeoutException]::new('process timed out'); `$e.Data['AvmTransient'] = `$false; `$e" }
            @{ Name = 'a GitHub permission error'; Factory = "[AvmGitHubException]::new('GitHub API GET x failed with HTTP 403', 403)" }
        ) {
            # Module exception types do not exist during discovery, so build them in module scope.
            InModuleScope 'Avm.Authoring' -Parameters @{ Factory = $Factory } {
                param($Factory)
                $Failure = & ([scriptblock]::Create($Factory))
                $state = @{ Calls = 0 }
                { Invoke-AvmRetry -RetryActivity 'probe' -RetryAction { $state.Calls++; throw $Failure } } |
                    Should -Throw
                $state.Calls | Should -Be 1
                Should -Invoke Wait-AvmRetryDelay -Exactly 0
            }
        }

        It 'waits at least the server Retry-After delay' {
            InModuleScope 'Avm.Authoring' {
                $state = @{ Calls = 0 }
                Invoke-AvmRetry -RetryActivity 'probe' -RetryAction {
                    $state.Calls++
                    if ($state.Calls -eq 1) {
                        $e = [System.Exception]::new('throttled'); $e.Data['AvmTransient'] = $true; $e.Data['AvmRetryAfterSeconds'] = 25
                        throw $e
                    }
                } | Out-Null

                Should -Invoke Wait-AvmRetryDelay -Exactly 1 -ParameterFilter { $Seconds -ge 25 }
            }
        }

        It 'gives up instead of waiting for a Retry-After above the cap' {
            InModuleScope 'Avm.Authoring' {
                $state = @{ Calls = 0 }
                {
                    Invoke-AvmRetry -RetryActivity 'probe' -RetryAction {
                        $state.Calls++
                        $e = [System.Exception]::new('throttled'); $e.Data['AvmTransient'] = $true; $e.Data['AvmRetryAfterSeconds'] = 3600
                        throw $e
                    }
                } | Should -Throw 'throttled'
                $state.Calls | Should -Be 1
                Should -Invoke Wait-AvmRetryDelay -Exactly 0
            }
        }

        It 'caps exponential backoff at the configured maximum delay' {
            InModuleScope 'Avm.Authoring' {
                $env:AVM_NETWORK_RETRY_MAX_ATTEMPTS = '10'
                { Invoke-AvmRetry -RetryActivity 'probe' -RetryAction { throw [System.TimeoutException]::new('slow') } } |
                    Should -Throw
                $policy = Get-AvmNetworkRetryPolicy
                Should -Invoke Wait-AvmRetryDelay -Exactly 9
                Should -Invoke Wait-AvmRetryDelay -Exactly 0 -ParameterFilter { $Seconds -gt $policy.MaxDelaySeconds }
            }
        }

        It 'returns the last response carried by an exhausted failure' {
            InModuleScope 'Avm.Authoring' {
                $result = Invoke-AvmRetry -RetryActivity 'probe' -RetryMaxAttempts 2 -RetryAction {
                    $e = [System.Exception]::new('503'); $e.Data['AvmTransient'] = $true; $e.Data['AvmResult'] = 'last response'
                    throw $e
                }
                $result | Should -Be 'last response'
            }
        }

        It 'honours AVM_NETWORK_RETRY_MAX_ATTEMPTS and rejects invalid values' {
            InModuleScope 'Avm.Authoring' {
                $env:AVM_NETWORK_RETRY_MAX_ATTEMPTS = '1'
                $state = @{ Calls = 0 }
                { Invoke-AvmRetry -RetryActivity 'probe' -RetryAction { $state.Calls++; throw [System.TimeoutException]::new('slow') } } |
                    Should -Throw
                $state.Calls | Should -Be 1
                (Get-AvmNetworkRetryPolicy).AdvisoryMaxAttempts | Should -Be 1

                $env:AVM_NETWORK_RETRY_MAX_ATTEMPTS = '11'
                { Get-AvmNetworkRetryPolicy } | Should -Throw '*from 1 to 10*'
            }
        }
    }

    Context 'Get-AvmNetworkFailureKind' {
        It 'classifies <Name> as <Kind>' -TestCases @(
            @{ Name = 'an HTTP 401 response'; Kind = 'Permanent'; Factory = "[System.Net.Http.HttpRequestException]::new('Unauthorized', `$null, [System.Net.HttpStatusCode]::Unauthorized)" }
            @{ Name = 'an HTTP 429 response'; Kind = 'Transient'; Factory = "[System.Net.Http.HttpRequestException]::new('Too many', `$null, [System.Net.HttpStatusCode]::TooManyRequests)" }
            @{ Name = 'a TLS authentication failure'; Kind = 'Permanent'; Factory = "[System.Net.Http.HttpRequestException]::new('SSL failed', [System.Security.Authentication.AuthenticationException]::new('bad certificate'))" }
            @{ Name = 'a DNS failure'; Kind = 'Transient'; Factory = '[System.Net.Sockets.SocketException]::new(11001)' }
            @{ Name = 'git transport stderr'; Kind = 'Transient'; Factory = "[AvmProcessException]::new(`"git exited with code 128.``nfatal: unable to access 'https://github.com/x/': Could not resolve host: github.com`")" }
            @{ Name = 'a git authentication error'; Kind = 'Permanent'; Factory = "[AvmProcessException]::new('fatal: Authentication failed for https://github.com/x/')" }
            @{ Name = 'wrapped Terraform provider output'; Kind = 'Transient'; Factory = "[System.Exception]::new(`"`$([char]0x1B)[31m`$([char]0x2502) Error: Failed to install provider``n`$([char]0x2502) context deadline``n`$([char]0x2502) exceeded (Client.Timeout exceeded while awaiting``n`$([char]0x2502) headers)`")" }
            @{ Name = 'a configuration error'; Kind = 'Permanent'; Factory = "[AvmConfigurationException]::new('connection reset in config text')" }
        ) {
            InModuleScope 'Avm.Authoring' -Parameters @{ Factory = $Factory; Expected = $Kind } {
                param($Factory, $Expected)
                $Failure = & ([scriptblock]::Create($Factory))
                Get-AvmNetworkFailureKind -ErrorRecord $Failure | Should -Be $Expected
            }
        }
    }

    Context 'Invoke-AvmWebRequest' {
        It 'retries a transient status and returns the successful response' {
            InModuleScope 'Avm.Authoring' {
                $state = @{ Calls = 0 }
                Mock Invoke-WebRequest {
                    $state.Calls++
                    $code = if ($state.Calls -eq 1) { 503 } else { 200 }
                    [pscustomobject]@{ StatusCode = $code; Headers = @{ 'Retry-After' = @('3') }; Content = "body$code" }
                }

                $response = Invoke-AvmWebRequest -Uri 'https://example.invalid/x' -Label 'probe' -SkipHttpErrorCheck

                $response.StatusCode | Should -Be 200
                Should -Invoke Invoke-WebRequest -Exactly 2
                Should -Invoke Wait-AvmRetryDelay -Exactly 1 -ParameterFilter { $Seconds -ge 3 }
            }
        }

        It 'returns a non-transient status after one request' {
            InModuleScope 'Avm.Authoring' {
                Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 404; Headers = @{}; Content = '' } }

                (Invoke-AvmWebRequest -Uri 'https://example.invalid/x' -Label 'probe' -SkipHttpErrorCheck).StatusCode |
                    Should -Be 404
                Should -Invoke Invoke-WebRequest -Exactly 1
            }
        }

        It 'returns the last transient response once attempts run out' {
            InModuleScope 'Avm.Authoring' {
                Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 502; Headers = @{}; Content = '' } }

                (Invoke-AvmWebRequest -Uri 'https://example.invalid/x' -Label 'probe' -SkipHttpErrorCheck).StatusCode |
                    Should -Be 502
                Should -Invoke Invoke-WebRequest -Exactly (Get-AvmNetworkRetryPolicy).MaxAttempts
            }
        }
    }

    Context 'Invoke-AvmHttp thrown Retry-After responses' {
        BeforeEach {
            $script:httpEnvironment = @{}
            foreach ($name in @('AVM_OFFLINE', 'AVM_MIRROR')) {
                $script:httpEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
                [Environment]::SetEnvironmentVariable($name, [NullString]::Value, 'Process')
            }
        }

        AfterEach {
            foreach ($name in $script:httpEnvironment.Keys) {
                $value = if ($null -eq $script:httpEnvironment[$name]) { [NullString]::Value } else { $script:httpEnvironment[$name] }
                [Environment]::SetEnvironmentVariable($name, $value, 'Process')
            }
        }

        It 'retries a thrown 429 with a populated <HeaderKind> header and verifies the download' -ForEach @(
            @{ HeaderKind = 'Delta' }
            @{ HeaderKind = 'Date' }
        ) {
            InModuleScope 'Avm.Authoring' -Parameters @{ HeaderKind = $HeaderKind; Destination = (Join-Path $TestDrive "$HeaderKind.bin") } {
                param($HeaderKind, $Destination)
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::TooManyRequests)
                $response.Headers.RetryAfter = if ($HeaderKind -eq 'Delta') {
                    [System.Net.Http.Headers.RetryConditionHeaderValue]::new([timespan]::FromSeconds(45))
                }
                else {
                    [System.Net.Http.Headers.RetryConditionHeaderValue]::new([DateTimeOffset]::UtcNow.AddSeconds(45))
                }
                $failure = [Microsoft.PowerShell.Commands.HttpResponseException]::new('rate limited', $response)
                $state = @{ Calls = 0 }
                Mock Invoke-WebRequest {
                    param($OutFile)
                    $state.Calls++
                    if ($state.Calls -eq 1) { throw $failure }
                    [System.IO.File]::WriteAllText($OutFile, 'downloaded', [System.Text.UTF8Encoding]::new($false))
                }
                $sha = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData(
                        [System.Text.Encoding]::UTF8.GetBytes('downloaded'))).ToLowerInvariant()
                try {
                    Invoke-AvmHttp -Url 'https://example.invalid/tool' -Destination $Destination -ExpectedSha256 $sha |
                        Should -Be $Destination
                    Get-Content -LiteralPath $Destination -Raw | Should -Be 'downloaded'
                    Should -Invoke Invoke-WebRequest -Exactly 2
                    Should -Invoke Wait-AvmRetryDelay -Exactly 1 -ParameterFilter { $Seconds -ge 35 -and $Seconds -le 46 }
                }
                finally { $response.Dispose() }
            }
        }

        It 'preserves the thrown HTTP error for <HeaderKind> <Scenario>' -ForEach @(
            @{ HeaderKind = 'Delta'; Scenario = 'above the cap'; Seconds = 3600; Attempts = 1 }
            @{ HeaderKind = 'Date'; Scenario = 'above the cap'; Seconds = 3600; Attempts = 1 }
            @{ HeaderKind = 'Delta'; Scenario = 'after exhaustion'; Seconds = 1; Attempts = 2 }
            @{ HeaderKind = 'Date'; Scenario = 'after exhaustion'; Seconds = 1; Attempts = 2 }
        ) {
            InModuleScope 'Avm.Authoring' -Parameters @{
                HeaderKind = $HeaderKind; Seconds = $Seconds; Attempts = $Attempts
                Destination = (Join-Path $TestDrive 'failed-download.bin')
            } {
                param($HeaderKind, $Seconds, $Attempts, $Destination)
                $env:AVM_NETWORK_RETRY_MAX_ATTEMPTS = '2'
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::TooManyRequests)
                $response.Headers.RetryAfter = if ($HeaderKind -eq 'Delta') {
                    [System.Net.Http.Headers.RetryConditionHeaderValue]::new([timespan]::FromSeconds($Seconds))
                }
                else {
                    [System.Net.Http.Headers.RetryConditionHeaderValue]::new([DateTimeOffset]::UtcNow.AddSeconds($Seconds))
                }
                $failure = [Microsoft.PowerShell.Commands.HttpResponseException]::new('original rate limit', $response)
                Mock Invoke-WebRequest { throw $failure }
                $caught = $null
                try {
                    try { Invoke-AvmHttp -Url 'https://example.invalid/tool' -Destination $Destination -ExpectedSha256 ('a' * 64) }
                    catch { $caught = $_.Exception }
                    $caught | Should -Be $failure
                    Should -Invoke Invoke-WebRequest -Exactly $Attempts
                    Should -Invoke Wait-AvmRetryDelay -Exactly ($Attempts - 1)
                    $Destination | Should -Not -Exist
                }
                finally { $response.Dispose() }
            }
        }
    }

    Context 'Opted-in callers' {
        It 'retries GitHub GET requests but never mutations' {
            InModuleScope 'Avm.Authoring' {
                Mock Get-AvmApplicationPath { '/fake/gh' }
                Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = '{}'; StdErr = '' } }

                Invoke-AvmGitHubApi -Endpoint 'repos/o/r' | Out-Null
                Invoke-AvmGitHubApi -Endpoint 'repos/o/r/issues' -Method POST -Body @{ title = 't' } | Out-Null

                Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $RetryNetworkFailure -and $ArgumentList -contains 'GET' }
                Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { -not $RetryNetworkFailure -and $ArgumentList -contains 'POST' }
            }
        }

        It 'uses the smaller advisory budget for the Gallery version check' {
            InModuleScope 'Avm.Authoring' {
                $script:AvmModuleVersionCheckCompleted = $false
                Mock Find-PSResource { throw [System.Net.Http.HttpRequestException]::new('No route to host') }

                { Get-AvmLatestModuleVersion -Refresh } | Should -Throw '*No route to host*'
                Should -Invoke Find-PSResource -Exactly (Get-AvmNetworkRetryPolicy).AdvisoryMaxAttempts
            }
        }
    }

    Context 'Invoke-AvmProcess -RetryNetworkFailure' {
        BeforeAll {
            $script:pwsh = (Get-Process -Id $PID).Path
        }

        It 'reruns a process whose output reports a transient network failure' {
            $marker = Join-Path $TestDrive 'attempted'
            $script = "if (Test-Path '$marker') { 'done'; exit 0 }; New-Item '$marker' | Out-Null; [Console]::Error.WriteLine('fatal: Connection reset by peer'); exit 128"
            InModuleScope 'Avm.Authoring' -Parameters @{ Pwsh = $script:pwsh; Script = $script } {
                param($Pwsh, $Script)
                $result = Invoke-AvmProcess -FilePath $Pwsh -ArgumentList @('-NoProfile', '-Command', $Script) -RetryNetworkFailure
                $result.StdOut.Trim() | Should -Be 'done'
                Should -Invoke Wait-AvmRetryDelay -Exactly 1
            }
        }

        It 'returns a permanent failure after one run when exit codes are ignored' {
            InModuleScope 'Avm.Authoring' -Parameters @{ Pwsh = $script:pwsh } {
                param($Pwsh)
                $result = Invoke-AvmProcess -FilePath $Pwsh -ArgumentList @('-NoProfile', '-Command', "[Console]::Error.WriteLine('fatal: repository not found'); exit 2") -IgnoreExitCode -RetryNetworkFailure
                $result.ExitCode | Should -Be 2
                Should -Invoke Wait-AvmRetryDelay -Exactly 0
            }
        }
    }
}