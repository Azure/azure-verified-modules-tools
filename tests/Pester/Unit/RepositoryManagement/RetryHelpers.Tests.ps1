BeforeAll {
    # The build harness runs under strict mode; match it so a standalone run of
    # this file cannot pass while the gate fails.
    Set-StrictMode -Version Latest

    $script:repoRoot = (Resolve-Path (
        Join-Path $PSScriptRoot ".." ".." ".." ".."
    )).Path
    . (Join-Path $script:repoRoot (
            "repository-management/repository-sync/scripts/lib/RetryHelpers.ps1"
        ))

    $script:esc = [char]27

    # Reproduced from a scheduled repository sync that failed without retrying.
    # Terraform colourises stderr even when it is redirected to a file, which
    # splits the `Error: ` prefix from the summary, and it hard-wraps the detail
    # behind a box-drawing gutter.
    function New-ProviderInstallFailure {
        $e = $script:esc
        @(
            "$e[31m╷$e[0m"
            "$e[31m│$e[0m $e[0m$e[1m$e[31mError: $e[0m$e[0m$e[1mFailed to install provider$e[0m"
            "$e[31m│$e[0m $e[0m"
            "$e[31m│$e[0m $e[0mError while installing integrations/github v6.13.0: could not query"
            "$e[31m│$e[0m provider registry for registry.terraform.io/integrations/github: failed to"
            "$e[31m│$e[0m retrieve cryptographic signature for provider: the request failed after 2"
            "$e[31m│$e[0m attempts, please try again later: 502 Bad Gateway returned from github.com"
            "$e[31m╵$e[0m"
        )
    }

    function New-ConfigurationFailure {
        $e = $script:esc
        @(
            "$e[31m╷$e[0m"
            "$e[31m│$e[0m $e[0m$e[1m$e[31mError: $e[0m$e[0m$e[1mUnsupported argument$e[0m"
            "$e[31m│$e[0m $e[0mAn argument named `"nope`" is not expected here."
            "$e[31m╵$e[0m"
        )
    }

    function global:Start-Process {
        param(
            [string]$FilePath,
            [string[]]$ArgumentList,
            [string]$RedirectStandardOutput,
            [string]$RedirectStandardError,
            [switch]$PassThru,
            [switch]$NoNewWindow,
            [switch]$Wait
        )

        $global:retryHelpersAttempts++
        $index = [Math]::Min(
            $global:retryHelpersAttempts - 1,
            $global:retryHelpersResponses.Count - 1
        )
        $response = $global:retryHelpersResponses[$index]

        Set-Content -Path $RedirectStandardOutput -Value $response.Output
        Set-Content -Path $RedirectStandardError -Value $response.Error

        [pscustomobject]@{ ExitCode = $response.ExitCode }
    }

    function Invoke-TerraformUnderTest {
        param(
            [Parameter(Mandatory)]
            [array]$Responses
        )

        $global:retryHelpersAttempts = 0
        $global:retryHelpersResponses = @($Responses)

        Invoke-TerraformWithRetry `
            -commands @(@{ Arguments = @("init") }) `
            -workingDirectory "./terraform" `
            -outputLog (Join-Path $TestDrive "output.log") `
            -errorLog (Join-Path $TestDrive "error.log") `
            -maxRetries 3 `
            -retryDelayIncremental 0 `
            -stateStorageAccountName "sa" `
            -stateContainerName "tfstate" `
            -stateBlobName "repo.tfstate"
    }
}

AfterAll {
    Remove-Item Function:\global:Start-Process -Force -ErrorAction SilentlyContinue
    Remove-Variable retryHelpersAttempts -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable retryHelpersResponses -Scope Global -ErrorAction SilentlyContinue
}

Describe "Remove-AnsiEscapeCode" {
    It "strips colour codes without touching the message" {
        $cleaned = @(Remove-AnsiEscapeCode -text @(
                "$($script:esc)[0m$($script:esc)[1m$($script:esc)[31mError: $($script:esc)[0mFailed$($script:esc)[0m"
            ))

        $cleaned[0] | Should -Be "Error: Failed"
    }

    It "returns an empty array for no input" {
        Remove-AnsiEscapeCode -text @() | Should -HaveCount 0
    }
}

Describe "ConvertTo-FlatErrorText" {
    It "rejoins detail that Terraform wrapped across gutter lines" {
        $flattened = ConvertTo-FlatErrorText -text @(
            "│ provider registry for registry.terraform.io: failed to"
            "│ retrieve cryptographic signature for provider: the request failed"
        )

        $flattened | Should -BeLike "*failed to retrieve cryptographic signature for provider*"
    }
}

Describe "Get-ErrorOutputMatch" {
    BeforeEach {
        $script:errorOutput = Remove-AnsiEscapeCode -text (New-ProviderInstallFailure)
        $script:flattened = ConvertTo-FlatErrorText -text $script:errorOutput
    }

    It "matches a pattern that colour codes split apart" {
        Get-ErrorOutputMatch `
            -errorOutput $script:errorOutput `
            -flattenedError $script:flattened `
            -pattern "Error: Failed to install provider" | Should -Not -BeNullOrEmpty
    }

    It "matches a pattern that spans a line wrap" {
        Get-ErrorOutputMatch `
            -errorOutput $script:errorOutput `
            -flattenedError $script:flattened `
            -pattern "failed to retrieve cryptographic signature for provider" |
            Should -Not -BeNullOrEmpty
    }

    It "returns the offending line when a single line matches" {
        Get-ErrorOutputMatch `
            -errorOutput $script:errorOutput `
            -flattenedError $script:flattened `
            -pattern "502 Bad Gateway" | Should -BeLike "*502 Bad Gateway returned from github.com"
    }

    It "returns null when the pattern is absent" {
        Get-ErrorOutputMatch `
            -errorOutput $script:errorOutput `
            -flattenedError $script:flattened `
            -pattern "Error acquiring the state lock" | Should -BeNullOrEmpty
    }
}

Describe "Invoke-TerraformWithRetry transient failures" {
    It "retries a colourised provider install failure and succeeds" {
        $result = Invoke-TerraformUnderTest -Responses @(
            @{ ExitCode = 1; Output = ""; Error = (New-ProviderInstallFailure) }
            @{ ExitCode = 0; Output = ""; Error = "" }
        )

        $result.success | Should -BeTrue
        $global:retryHelpersAttempts | Should -Be 2
    }

    It "does not retry a genuine configuration error" {
        $result = Invoke-TerraformUnderTest -Responses @(
            @{ ExitCode = 1; Output = ""; Error = (New-ConfigurationFailure) }
        )

        $result.success | Should -BeFalse
        $global:retryHelpersAttempts | Should -Be 1
    }
}

Describe "Invoke-GitHubCliWithRetry transient failures" {
    It "retries an intermittent x509 failure" {
        $global:retryHelpersAttempts = 0
        $global:retryHelpersResponses = @(
            @{
                ExitCode = 1
                Output   = ""
                Error    = "tls: failed to verify certificate: x509: certificate is not valid for any names"
            }
            @{ ExitCode = 0; Output = '{"ok":true}'; Error = "" }
        )

        $result = Invoke-GitHubCliWithRetry `
            -commands @(@{
                    Arguments = @("api", "repos/Azure/example")
                    OutputLog = (Join-Path $TestDrive "gh-output.log")
                }) `
            -errorLog (Join-Path $TestDrive "gh-error.log") `
            -maxRetries 1 `
            -retryDelayIncremental 0 `
            -returnOutputParsedFromJson

        $result.success | Should -BeTrue
        $result.output.ok | Should -BeTrue
        $global:retryHelpersAttempts | Should -Be 2
    }

    It "does not retry a deterministic GitHub CLI failure" {
        $global:retryHelpersAttempts = 0
        $global:retryHelpersResponses = @(
            @{ ExitCode = 1; Output = ""; Error = "HTTP 404: Not Found" }
        )

        $result = Invoke-GitHubCliWithRetry `
            -commands @(@{
                    Arguments = @("api", "repos/Azure/example")
                    OutputLog = (Join-Path $TestDrive "gh-output.log")
                }) `
            -errorLog (Join-Path $TestDrive "gh-error.log") `
            -maxRetries 1 `
            -retryDelayIncremental 0

        $result.success | Should -BeFalse
        $result.exitCode | Should -Be 1
        $result.error | Should -Match "HTTP 404"
        $global:retryHelpersAttempts | Should -Be 1
    }
}
