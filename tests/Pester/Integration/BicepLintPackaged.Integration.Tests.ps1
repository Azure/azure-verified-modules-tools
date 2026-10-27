#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Integration: packaged Bicep lint' -Tag Integration {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        $manifest = Join-Path $repoRoot 'out' 'Avm.Authoring' 'Avm.Authoring.psd1'
        if (-not (Test-Path -LiteralPath $manifest)) {
            throw 'Run .\build.ps1 build before this installed-package acceptance test.'
        }
        $script:package = Join-Path $TestDrive 'installed' 'Avm.Authoring'
        $null = New-Item -ItemType Directory -Path (Split-Path $script:package) -Force
        Copy-Item -LiteralPath (Split-Path $manifest) -Destination $script:package -Recurse
        $script:packageManifest = Join-Path $script:package 'Avm.Authoring.psd1'
        Import-Module $script:packageManifest -Force
        $script:previousEnvironment = @{}
        foreach ($name in @('AVM_OFFLINE', 'AVM_NO_AUTO_INSTALL', 'AVM_LINT_FIXTURE', 'AVM_LINT_PACKAGE')) {
            $script:previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        }
        $script:tool = InModuleScope Avm.Authoring { Resolve-AvmTool -Name bicep }
        $script:tool.Version | Should -BeExactly '0.48.1'
        $env:AVM_OFFLINE = '1'
        $env:AVM_NO_AUTO_INSTALL = '1'
        $env:AVM_LINT_PACKAGE = $script:packageManifest
    }

    AfterAll {
        foreach ($name in $script:previousEnvironment.Keys) {
            $value = $script:previousEnvironment[$name]
            if ($null -eq $value) { $value = [NullString]::Value }
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
        Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
    }

    It 'runs the real pinned compiler for <Case> without changing the source' -TestCases @(
        @{ Case = 'clean'; Source = "output result string = 'ok'`n"; Status = 'pass'; ExitCode = 0 }
        @{ Case = 'warning'; Source = "param unused string`n"; Status = 'pass'; ExitCode = 0;
            Severity = 'warning'; Code = 'no-unused-params'; Line = 1; Column = 7;
            Message = 'Parameter "unused" is declared but never used. [https://aka.ms/bicep/linter-diagnostics#no-unused-params]' }
        @{ Case = 'error'; Source = "output result string = missing`n"; Status = 'fail'; ExitCode = 1;
            Severity = 'error'; Code = 'BCP057'; Line = 1; Column = 24;
            Message = 'The name "missing" does not exist in the current context. [https://aka.ms/bicep/core-diagnostics#BCP057]' }
    ) {
        param($Case, $Source, $Status, $ExitCode, $Severity, $Code, $Line, $Column, $Message)
        $fixture = Join-Path $TestDrive ("lint-" + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $fixture -Force
        $fixture | Should -Not -Match '[\\/]\.[^\\/]+[\\/]'
        $sourcePath = Join-Path $fixture 'main.bicep'
        [System.IO.File]::WriteAllText($sourcePath, $Source, [System.Text.UTF8Encoding]::new($false))
        $hash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash

        (Get-Module Avm.Authoring).ModuleBase | Should -BeExactly $script:package
        $result = Invoke-AvmLint -Path $fixture -Ecosystem bicep -SkipModuleVersionCheck
        $result.FilesProcessed | Should -Be 1
        $result.Tool | Should -BeExactly 'bicep/0.48.1'
        $result.ToolSource | Should -BeExactly 'cache'
        $result.ToolPath | Should -BeExactly $script:tool.Path
        $result.Status | Should -BeExactly $Status
        if ($Case -eq 'clean') {
            $result.Issues | Should -HaveCount 0
        }
        else {
            $result.Issues | Should -HaveCount 1
            $result.Issues[0].File | Should -BeExactly $sourcePath
            $result.Issues[0].Line | Should -Be $Line
            $result.Issues[0].Column | Should -Be $Column
            $result.Issues[0].Severity | Should -BeExactly $Severity
            $result.Issues[0].Code | Should -BeExactly $Code
            $result.Issues[0].Message | Should -BeExactly $Message
        }

        $env:AVM_LINT_FIXTURE = $fixture
        $command = 'Import-Module -Name $env:AVM_LINT_PACKAGE -Force; avm -SkipModuleVersionCheck lint --path $env:AVM_LINT_FIXTURE --ecosystem bicep'
        $cli = InModuleScope Avm.Authoring -Parameters @{ Command = $command } {
            param($Command)
            Invoke-AvmProcess -FilePath ([System.Environment]::ProcessPath) `
                -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $Command) -IgnoreExitCode
        }
        $cli.ExitCode | Should -Be $ExitCode -Because "$($cli.StdOut) $($cli.StdErr)"
        (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash | Should -BeExactly $hash
    }
}
