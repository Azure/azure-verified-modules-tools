#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:importHelper = Join-Path $PSScriptRoot '..' 'Import-AvmTestModule.ps1'
}

Describe 'Component: extracted package test imports' -Tag Component {
    BeforeEach {
        $script:savedImportEnvironment = @{}
        foreach ($name in @('PSModulePath', 'AVM_TEST_PACKAGE_ROOT')) {
            $script:savedImportEnvironment[$name] = [System.Environment]::GetEnvironmentVariable($name, 'Process')
        }
        $script:importRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:fakeModule = Join-Path $script:importRoot 'modules' 'Avm.Authoring' '99.0.0'
        $null = New-Item -ItemType Directory -Path $script:fakeModule -Force
        $script:fakeManifest = Join-Path $script:fakeModule 'Avm.Authoring.psd1'
        Set-Content -LiteralPath $script:fakeManifest -Encoding utf8NoBOM -Value @'
@{
    RootModule = 'Avm.Authoring.psm1'
    ModuleVersion = '99.0.0'
    FunctionsToExport = @('Get-AvmPackageFixture')
}
'@
        Set-Content -LiteralPath (Join-Path $script:fakeModule 'Avm.Authoring.psm1') `
            -Encoding utf8NoBOM -Value "function Get-AvmPackageFixture { 'fixture' }"
        $env:PSModulePath = (Join-Path $script:importRoot 'modules') +
        [System.IO.Path]::PathSeparator + (Join-Path $PSHOME 'Modules')
        $env:AVM_TEST_PACKAGE_ROOT = $script:fakeModule
    }

    AfterEach {
        Remove-Module -Name Avm.Authoring -Force -ErrorAction SilentlyContinue
        foreach ($name in $script:savedImportEnvironment.Keys) {
            $value = $script:savedImportEnvironment[$name]
            if ($null -eq $value) {
                $value = [NullString]::Value
            }
            [System.Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
    }

    It 'imports by name and checks definitions without using the source manifest' {
        . $script:importHelper -SourceManifest (Join-Path $script:importRoot 'missing-source.psd1')
        (Get-Module -Name Avm.Authoring).ModuleBase | Should -BeExactly $script:fakeModule
        Get-AvmPackageFixture | Should -BeExactly 'fixture'
    }

    It 'rejects a different module selected by name instead of silently using source' {
        $expected = Join-Path $script:importRoot 'expected-package'
        $null = New-Item -ItemType Directory -Path $expected
        Copy-Item -LiteralPath $script:fakeManifest -Destination $expected
        $env:AVM_TEST_PACKAGE_ROOT = $expected
        { . $script:importHelper -SourceManifest $script:fakeManifest } |
            Should -Throw -ExpectedMessage '*not the extracted package*'
    }

    It 'rejects command definitions outside the selected package' {
        $outside = Join-Path $script:importRoot 'outside.ps1'
        Set-Content -LiteralPath $outside -Encoding utf8NoBOM `
            -Value "function Get-AvmPackageFixture { 'outside' }"
        Set-Content -LiteralPath (Join-Path $script:fakeModule 'Avm.Authoring.psm1') `
            -Encoding utf8NoBOM -Value ". '$outside'"
        { . $script:importHelper -SourceManifest $script:fakeManifest } |
            Should -Throw -ExpectedMessage '*not defined inside the extracted package*'
    }

    It 'preserves the ordinary source-import path when no package was requested' {
        [System.Environment]::SetEnvironmentVariable('AVM_TEST_PACKAGE_ROOT', [NullString]::Value, 'Process')
        . $script:importHelper -SourceManifest $script:fakeManifest
        (Get-Module -Name Avm.Authoring).ModuleBase | Should -BeExactly $script:fakeModule
        Get-AvmPackageFixture | Should -BeExactly 'fixture'
    }
}
