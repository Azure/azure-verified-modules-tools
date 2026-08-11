BeforeAll {
    $repoRoot = (Resolve-Path (
        Join-Path $PSScriptRoot ".." ".." ".." ".."
    )).Path
    . (Join-Path $repoRoot "repository-management/managed-files/scripts/Test-VsCodeExtensions.ps1")
}

Describe "Test-AvmVsCodeExtensions" {
    BeforeEach {
        $script:extensionFile = Join-Path $TestDrive "extensions.json"
        @{ recommendations = @("microsoft.test-extension") } |
            ConvertTo-Json |
            Set-Content -LiteralPath $script:extensionFile
        $script:marketplaceResult = @(
            [pscustomobject]@{
                publisher = [pscustomobject]@{
                    publisherName = "microsoft"
                    domain = "https://microsoft.com"
                    isDomainVerified = $true
                }
                extensionName = "test-extension"
            }
        )

        Mock Invoke-RestMethod {
            [pscustomobject]@{
                results = @(
                    [pscustomobject]@{
                        extensions = $script:marketplaceResult
                    }
                )
            }
        }
    }

    It "accepts an existing matching extension from a verified Microsoft publisher" {
        { Test-AvmVsCodeExtensions -Path $script:extensionFile } |
            Should -Not -Throw

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

    It "discovers extension files when no path is provided" {
        $vscodeDirectory = New-Item -ItemType Directory -Path (
            Join-Path $TestDrive ".vscode"
        )
        Copy-Item -LiteralPath $script:extensionFile -Destination (
            Join-Path $vscodeDirectory.FullName "extensions.json"
        )

        Push-Location $TestDrive
        try {
            { Test-AvmVsCodeExtensions } | Should -Not -Throw
        } finally {
            Pop-Location
        }

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

    It "rejects an extension that does not exist" {
        $script:marketplaceResult = @()

        { Test-AvmVsCodeExtensions -Path $script:extensionFile } |
            Should -Throw "*was not found on the VS Code Marketplace*"
    }

    It "rejects a mismatched returned extension ID" {
        $script:marketplaceResult[0].extensionName = "different-extension"

        { Test-AvmVsCodeExtensions -Path $script:extensionFile } |
            Should -Throw "*returned the mismatched ID*"
    }

    It "rejects an unverified microsoft.com publisher" {
        $script:marketplaceResult[0].publisher.isDomainVerified = $false

        { Test-AvmVsCodeExtensions -Path $script:extensionFile } |
            Should -Throw "*without a verified publisher domain*"
    }
}
