#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module -Name (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module -Name Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Telemetry prefix generation' {
    It 'generates a seven-character hexadecimal suffix for <Ecosystem> <Kind>' -TestCases @(
        foreach ($ecosystem in @('bicep', 'terraform')) {
            foreach ($kind in @('res', 'ptn', 'utl')) {
                @{ Ecosystem = $ecosystem; Kind = $kind }
            }
        }
    ) {
        param($Ecosystem, $Kind)
        $marker = if ($Ecosystem -eq 'bicep') { '46d3xbcp' } else { '46d3xtrf' }
        New-AvmTelemetryIdPrefix -Ecosystem $Ecosystem -Kind $Kind -SkipModuleVersionCheck |
            Should -MatchExactly "^$marker\.$Kind\.[0-9a-f]{7}$"
    }

    It 'does not reuse a known current or historical prefix' {
        $taken = @(1..64 | ForEach-Object { New-AvmTelemetryIdPrefix -Ecosystem bicep -Kind ptn -SkipModuleVersionCheck })
        New-AvmTelemetryIdPrefix -Ecosystem bicep -Kind ptn -KnownPrefix $taken -SkipModuleVersionCheck |
            Should -Not -BeIn $taken
    }

    It 'produces distinct prefixes across repeated Terraform calls' {
        $generated = @(1..50 | ForEach-Object { New-AvmTelemetryIdPrefix -Ecosystem terraform -Kind res -SkipModuleVersionCheck })
        @($generated | Select-Object -Unique).Count | Should -Be $generated.Count
    }

    It 'rejects unsupported ecosystems and module kinds' {
        { New-AvmTelemetryIdPrefix -Ecosystem other -Kind res -SkipModuleVersionCheck } | Should -Throw '*does not belong to the set*'
        { New-AvmTelemetryIdPrefix -Ecosystem bicep -Kind other -SkipModuleVersionCheck } | Should -Throw '*does not belong to the set*'
    }
}
