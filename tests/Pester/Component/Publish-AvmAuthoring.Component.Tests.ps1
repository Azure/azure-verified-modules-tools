#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    $script:scriptPath = Join-Path $script:repoRoot 'scripts' 'Publish-AvmAuthoring.ps1'

    function New-SignedReleaseFixture {
        param(
            [Parameter(Mandatory = $true)]
            [string] $Root,

            [Parameter()]
            [string] $Version = '1.2.3',

            [Parameter()]
            [switch] $Unsigned
        )

        $modulePath = Join-Path $Root 'module' 'Avm.Authoring'
        $artifactPath = Join-Path $Root 'release'
        New-Item -ItemType Directory -Path $modulePath -Force | Out-Null
        New-Item -ItemType Directory -Path $artifactPath -Force | Out-Null

        $signature = if ($Unsigned) {
            ''
        } else {
            "`n# SIG # Begin signature block`n# test-signature`n# SIG # End signature block`n"
        }

        $manifest = @"
@{
    RootModule = 'Avm.Authoring.psm1'
    ModuleVersion = '$Version'
    GUID = 'e6ca4483-2f06-4102-93e9-2cc557754c18'
    Author = 'Microsoft Corporation'
    FunctionsToExport = @()
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
$signature
"@
        [System.IO.File]::WriteAllText(
            (Join-Path $modulePath 'Avm.Authoring.psd1'),
            $manifest,
            [System.Text.UTF8Encoding]::new($false)
        )
        [System.IO.File]::WriteAllText(
            (Join-Path $modulePath 'Avm.Authoring.psm1'),
            "Set-StrictMode -Version 3.0$signature",
            [System.Text.UTF8Encoding]::new($false)
        )

        $archiveName = "Avm.Authoring-$Version.zip"
        $archivePath = Join-Path $artifactPath $archiveName
        Compress-Archive -Path $modulePath -DestinationPath $archivePath
        $hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        [System.IO.File]::WriteAllText(
            (Join-Path $artifactPath 'SHA256SUMS'),
            "$hash *$archiveName`n",
            [System.Text.UTF8Encoding]::new($false)
        )

        return $artifactPath
    }
}

Describe 'Component: signed release artifact validation' -Tag 'Component' {
    BeforeEach {
        $script:apiKey = ConvertTo-SecureString -String 'test-key' -AsPlainText -Force
    }

    It 'accepts a signed archive whose checksum and manifest match the release tag' {
        $artifactPath = New-SignedReleaseFixture -Root (Join-Path $TestDrive 'valid')

        {
            & $script:scriptPath `
                -ReleaseTag v1.2.3 `
                -ArtifactPath $artifactPath `
                -ApiKey $script:apiKey `
                -WhatIf
        } | Should -Not -Throw
    }

    It 'rejects a checksum mismatch before publication' {
        $artifactPath = New-SignedReleaseFixture -Root (Join-Path $TestDrive 'bad-hash')
        [System.IO.File]::WriteAllText(
            (Join-Path $artifactPath 'SHA256SUMS'),
            "$('0' * 64) *Avm.Authoring-1.2.3.zip`n",
            [System.Text.UTF8Encoding]::new($false)
        )

        {
            & $script:scriptPath `
                -ReleaseTag v1.2.3 `
                -ArtifactPath $artifactPath `
                -ApiKey $script:apiKey `
                -WhatIf
        } | Should -Throw '*Checksum mismatch*'
    }

    It 'rejects a module version that differs from the release tag' {
        $artifactPath = New-SignedReleaseFixture `
            -Root (Join-Path $TestDrive 'bad-version') `
            -Version '1.2.4'
        Rename-Item `
            -LiteralPath (Join-Path $artifactPath 'Avm.Authoring-1.2.4.zip') `
            -NewName 'Avm.Authoring-1.2.3.zip'
        $archivePath = Join-Path $artifactPath 'Avm.Authoring-1.2.3.zip'
        $hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        [System.IO.File]::WriteAllText(
            (Join-Path $artifactPath 'SHA256SUMS'),
            "$hash *Avm.Authoring-1.2.3.zip`n",
            [System.Text.UTF8Encoding]::new($false)
        )

        {
            & $script:scriptPath `
                -ReleaseTag v1.2.3 `
                -ArtifactPath $artifactPath `
                -ApiKey $script:apiKey `
                -WhatIf
        } | Should -Throw "*Manifest version '1.2.4' does not match release version '1.2.3'*"
    }

    It 'rejects an unsigned PowerShell file' {
        $artifactPath = New-SignedReleaseFixture `
            -Root (Join-Path $TestDrive 'unsigned') `
            -Unsigned

        {
            & $script:scriptPath `
                -ReleaseTag v1.2.3 `
                -ArtifactPath $artifactPath `
                -ApiKey $script:apiKey `
                -WhatIf
        } | Should -Throw '*contains unsigned PowerShell files*'
    }
}
