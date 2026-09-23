#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Save-AvmAuthoringReleaseAssets.ps1' {
    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
        $script:scriptPath = Join-Path $script:repoRoot 'scripts' 'Save-AvmAuthoringReleaseAssets.ps1'

        function gh {
            $global:AvmReleaseAssetsTestState.GhCalls += , @($args)
            $global:LASTEXITCODE = $global:AvmReleaseAssetsTestState.GhExitCode
            $global:AvmReleaseAssetsTestState.ApiResponse
        }

        function Invoke-WebRequest {
            param($Uri, $Headers, $OutFile)

            $global:AvmReleaseAssetsTestState.WebCalls += [pscustomobject]@{
                Uri = $Uri
                Headers = $Headers
                OutFile = $OutFile
            }
            if ($global:AvmReleaseAssetsTestState.DownloadFailure) {
                throw 'Asset download failed.'
            }

            $bytes = if ($global:AvmReleaseAssetsTestState.ShortDownload) {
                [byte[]] @(0)
            }
            elseif ($OutFile -like '*SHA256SUMS') {
                [byte[]] @(4, 5)
            }
            else {
                [byte[]] @(1, 2, 3)
            }
            [System.IO.File]::WriteAllBytes($OutFile, $bytes)
        }
    }

    BeforeEach {
        $script:previousToken = $env:GH_TOKEN
        $env:GH_TOKEN = 'test-token'
        $global:AvmReleaseAssetsTestState = @{
            GhCalls = @()
            WebCalls = @()
            GhExitCode = 0
            DownloadFailure = $false
            ShortDownload = $false
            Assets = @(
                @{ id = 11; name = 'Avm.Authoring-0.17.1.zip'; state = 'uploaded'; size = 3 }
                @{ id = 12; name = 'SHA256SUMS'; state = 'uploaded'; size = 2 }
            )
        }
        $global:AvmReleaseAssetsTestState.ApiResponse = '[' + (ConvertTo-Json -InputObject $global:AvmReleaseAssetsTestState.Assets -Compress) + ']'
        $script:outputPath = Join-Path $TestDrive 'release'
    }

    AfterEach {
        if ($null -eq $script:previousToken) {
            Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
        }
        else {
            $env:GH_TOKEN = $script:previousToken
        }
        $global:LASTEXITCODE = 0
        Remove-Variable -Name AvmReleaseAssetsTestState -Scope Global
    }

    It 'finds both signed assets through the release ID and downloads their binary content' {
        & $script:scriptPath `
            -ReleaseTag 'v0.17.1' `
            -Repository 'Azure/azure-verified-modules-tools' `
            -ReleaseId 394441403 `
            -OutputPath $script:outputPath

        $global:AvmReleaseAssetsTestState.GhCalls.Count | Should -Be 1
        ($global:AvmReleaseAssetsTestState.GhCalls[0] -join ' ') | Should -Be (
            'api --paginate --slurp ' +
            'repos/Azure/azure-verified-modules-tools/releases/394441403/assets?per_page=100'
        )
        $global:AvmReleaseAssetsTestState.WebCalls.Count | Should -Be 2
        $global:AvmReleaseAssetsTestState.WebCalls[0].Uri | Should -Be 'https://api.github.com/repos/Azure/azure-verified-modules-tools/releases/assets/11'
        $global:AvmReleaseAssetsTestState.WebCalls[0].Headers.Authorization | Should -Be 'Bearer test-token'
        $global:AvmReleaseAssetsTestState.WebCalls[0].Headers.Accept | Should -Be 'application/octet-stream'
        $global:AvmReleaseAssetsTestState.WebCalls[1].Uri | Should -Be 'https://api.github.com/repos/Azure/azure-verified-modules-tools/releases/assets/12'
        (Get-Item -LiteralPath (Join-Path $script:outputPath 'Avm.Authoring-0.17.1.zip')).Length | Should -Be 3
        (Get-Item -LiteralPath (Join-Path $script:outputPath 'SHA256SUMS')).Length | Should -Be 2
    }

    It 'rejects a missing checksum before downloading anything' {
        $global:AvmReleaseAssetsTestState.Assets = @($global:AvmReleaseAssetsTestState.Assets[0])
        $global:AvmReleaseAssetsTestState.ApiResponse = '[' + (ConvertTo-Json -InputObject $global:AvmReleaseAssetsTestState.Assets -Compress) + ']'

        { & $script:scriptPath -ReleaseTag 'v0.17.1' -Repository 'Azure/azure-verified-modules-tools' -ReleaseId 1 -OutputPath $script:outputPath } |
            Should -Throw "*exactly one release asset 'SHA256SUMS'*found 0*"
        $global:AvmReleaseAssetsTestState.WebCalls.Count | Should -Be 0
    }

    It 'rejects duplicate archive names' {
        $global:AvmReleaseAssetsTestState.Assets += @{ id = 13; name = 'Avm.Authoring-0.17.1.zip'; state = 'uploaded'; size = 3 }
        $global:AvmReleaseAssetsTestState.ApiResponse = '[' + (ConvertTo-Json -InputObject $global:AvmReleaseAssetsTestState.Assets -Compress) + ']'

        { & $script:scriptPath -ReleaseTag 'v0.17.1' -Repository 'Azure/azure-verified-modules-tools' -ReleaseId 1 -OutputPath $script:outputPath } |
            Should -Throw '*expected exactly one release asset*found 2*'
        $global:AvmReleaseAssetsTestState.WebCalls.Count | Should -Be 0
    }

    It 'rejects an unfinished upload' {
        $global:AvmReleaseAssetsTestState.Assets[1].state = 'open'
        $global:AvmReleaseAssetsTestState.ApiResponse = '[' + (ConvertTo-Json -InputObject $global:AvmReleaseAssetsTestState.Assets -Compress) + ']'

        { & $script:scriptPath -ReleaseTag 'v0.17.1' -Repository 'Azure/azure-verified-modules-tools' -ReleaseId 1 -OutputPath $script:outputPath } |
            Should -Throw "*release asset 'SHA256SUMS' is not a complete upload*"
        $global:AvmReleaseAssetsTestState.WebCalls.Count | Should -Be 0
    }

    It 'fails explicitly when asset listing fails' {
        $global:AvmReleaseAssetsTestState.GhExitCode = 1

        { & $script:scriptPath -ReleaseTag 'v0.17.1' -Repository 'Azure/azure-verified-modules-tools' -ReleaseId 1 -OutputPath $script:outputPath } |
            Should -Throw "*Unable to list release assets for 'v0.17.1'*"
        $global:AvmReleaseAssetsTestState.WebCalls.Count | Should -Be 0
    }

    It 'rejects a truncated asset download' {
        $global:AvmReleaseAssetsTestState.ShortDownload = $true

        { & $script:scriptPath -ReleaseTag 'v0.17.1' -Repository 'Azure/azure-verified-modules-tools' -ReleaseId 1 -OutputPath $script:outputPath } |
            Should -Throw "*Release asset 'Avm.Authoring-0.17.1.zip' has size 1; expected 3*"
    }

    It 'propagates download failures without reporting success' {
        $global:AvmReleaseAssetsTestState.DownloadFailure = $true

        { & $script:scriptPath -ReleaseTag 'v0.17.1' -Repository 'Azure/azure-verified-modules-tools' -ReleaseId 1 -OutputPath $script:outputPath } |
            Should -Throw '*Asset download failed*'
    }

    It 'requires an authentication token before making an API request' {
        Remove-Item Env:GH_TOKEN

        { & $script:scriptPath -ReleaseTag 'v0.17.1' -Repository 'Azure/azure-verified-modules-tools' -ReleaseId 1 -OutputPath $script:outputPath } |
            Should -Throw '*GH_TOKEN is required*'
        $global:AvmReleaseAssetsTestState.GhCalls.Count | Should -Be 0
    }
}
