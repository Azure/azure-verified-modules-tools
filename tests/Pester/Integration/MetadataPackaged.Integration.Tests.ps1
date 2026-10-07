#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Integration: packaged native metadata' -Tag Integration {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        $manifest = Join-Path $repoRoot 'out' 'Avm.Authoring' 'Avm.Authoring.psd1'
        if (-not (Test-Path -LiteralPath $manifest)) {
            throw 'Run .\build.ps1 build before this installed-package acceptance test.'
        }
        $script:package = Join-Path $TestDrive 'installed' 'Avm.Authoring'
        $null = New-Item -ItemType Directory -Path (Split-Path $script:package) -Force
        Copy-Item -LiteralPath (Split-Path $manifest) -Destination $script:package -Recurse
        Import-Module (Join-Path $script:package 'Avm.Authoring.psd1') -Force
        $script:fixture = Join-Path $repoRoot 'tests' 'fixtures' 'modules' 'bicep-storage'
    }

    AfterAll {
        Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $script:consumer = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $script:fixture -Destination $script:consumer -Recurse
        $script:modulePath = Join-Path $script:consumer 'avm' 'res' 'storage' 'storage-account'
    }

    It 'runs shared JSON and separate source requirements from the copied package' {
        Test-Path -LiteralPath (Join-Path $script:consumer 'utilities') | Should -BeFalse
        (Get-Module Avm.Authoring).ModuleBase | Should -BeExactly $script:package
        InModuleScope Avm.Authoring -Parameters @{ Path = $script:modulePath; Package = $script:package } {
            param($Path, $Package)
            $inputData = Get-AvmMetadataValidationInput -Json (Read-AvmMetadataJson -Path (Join-Path $Path 'metadata.json')) `
                -Path $Path -Ecosystem bicep -ModuleType resource -CheckSource
            $inputData.SourceParser | Should -BeLike "$Package*"
            $result = Invoke-AvmMetadataValidation -Validations @($inputData)
            $result.Tests | Should -HaveCount 10
            @($result.Tests | Where-Object Result -NE 'Passed') | Should -HaveCount 0
            $result.Issues | Should -HaveCount 0
            $result.Tests.Name | Should -Contain "Module metadata: $Path.declares a literal source metadata description"
        }
    }

    It 'rejects <Case> with an actionable metadata diagnostic' -TestCases @(
        @{ Case = 'missing metadata'; Code = 'AVM_METADATA_MISSING' }
        @{ Case = 'invalid metadata'; Code = 'AVM_METADATA_SCHEMA' }
        @{ Case = 'missing telemetry'; Code = 'AVM_METADATA_SCHEMA' }
        @{ Case = 'missing source declaration'; Code = 'AVM_METADATA_SOURCE' }
    ) {
        param($Case, $Code)
        $metadataPath = Join-Path $script:modulePath 'metadata.json'
        switch ($Case) {
            'missing metadata' { Remove-Item -LiteralPath $metadataPath }
            'invalid metadata' { [System.IO.File]::WriteAllText($metadataPath, '{}') }
            'missing telemetry' {
                $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json -AsHashtable
                $metadata.Remove('telemetryIdPrefix')
                [System.IO.File]::WriteAllText($metadataPath, (ConvertTo-Json -InputObject $metadata -Depth 30))
            }
            'missing source declaration' {
                $sourcePath = Join-Path $script:modulePath 'main.bicep'
                $source = [System.IO.File]::ReadAllText($sourcePath)
                $source = [regex]::Replace($source, "(?m)^metadata description = '[^\r\n]*'\r?\n", '')
                [System.IO.File]::WriteAllText($sourcePath, $source)
            }
        }
        $result = Test-AvmModuleMetadata -Path $script:modulePath -Ecosystem bicep `
            -ModuleType resource -CheckSource -SkipModuleVersionCheck
        $result.Status | Should -Be 'fail'
        $result.Issues.Code | Should -Contain $Code
        $result.Issues[0].File | Should -BeIn @('metadata.json', 'main.bicep')
        $result.Issues[0].Message | Should -Not -BeNullOrEmpty
    }
}
