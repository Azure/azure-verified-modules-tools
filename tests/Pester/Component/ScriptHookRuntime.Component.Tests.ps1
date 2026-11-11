#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    $script:sourceModule = Join-Path $script:repoRoot 'src' 'Avm.Authoring'

    function New-HookTerraformExecutable {
        param(
            [Parameter(Mandatory)]
            [string] $Path
        )

        $directory = Split-Path -Parent $Path
        $null = New-Item -ItemType Directory -Path $directory -Force
        if ($IsWindows) {
            Copy-Item `
                -LiteralPath (Join-Path $env:SystemRoot 'System32' 'WindowsPowerShell' 'v1.0' 'powershell.exe') `
                -Destination $Path
            return
        }

        $content = @'
#!/usr/bin/env pwsh
if (($args -join ',') -cne 'version,-json') {
    [Console]::Error.WriteLine('expected only: version -json')
    exit 64
}
$record = @(
    $env:AVM_HOOK_PHASE
    $PSCommandPath
    ($args -join ',')
    (Get-Location).Path
    $env:TF_DATA_DIR
) -join '|'
[System.IO.File]::AppendAllText($env:AVM_HOOK_TRACE, $record + [Environment]::NewLine)
'{"terraform_version":"9.9.9-test"}'
'@
        [System.IO.File]::WriteAllText($Path, $content, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::SetUnixFileMode(
            $Path,
            [System.IO.UnixFileMode]::UserRead `
                -bor [System.IO.UnixFileMode]::UserWrite `
                -bor [System.IO.UnixFileMode]::UserExecute `
                -bor [System.IO.UnixFileMode]::GroupRead `
                -bor [System.IO.UnixFileMode]::GroupExecute `
                -bor [System.IO.UnixFileMode]::OtherRead `
                -bor [System.IO.UnixFileMode]::OtherExecute)
    }

    function New-HookVersionCommand {
        param(
            [Parameter(Mandatory)]
            [string] $Directory
        )

        if (-not $IsWindows) {
            return
        }

        $null = New-Item -ItemType Directory -Path $Directory -Force
        $content = @'
param([switch] $json)
if (-not $json -or $args.Count -ne 0) {
    [Console]::Error.WriteLine('expected only: version -json')
    exit 64
}
$record = @(
    $env:AVM_HOOK_PHASE
    (Get-Process -Id $PID).Path
    'version,-json'
    (Get-Location).Path
    $env:TF_DATA_DIR
) -join '|'
[System.IO.File]::AppendAllText($env:AVM_HOOK_TRACE, $record + [Environment]::NewLine)
'{"terraform_version":"9.9.9-test"}'
'@
        [System.IO.File]::WriteAllText(
            (Join-Path $Directory 'version.ps1'),
            $content,
            [System.Text.UTF8Encoding]::new($false))
    }

    function New-ConflictingTerraformExecutable {
        param(
            [Parameter(Mandatory)]
            [string] $Directory
        )

        $null = New-Item -ItemType Directory -Path $Directory -Force
        if ($IsWindows) {
            [System.IO.File]::WriteAllText(
                (Join-Path $Directory 'terraform.cmd'),
                "@echo off`r`necho conflict>>`"%AVM_CONFLICT_TRACE%`"`r`nexit /b 99`r`n",
                [System.Text.Encoding]::ASCII)
            return
        }

        $path = Join-Path $Directory 'terraform'
        $content = @'
#!/usr/bin/env pwsh
[System.IO.File]::AppendAllText($env:AVM_CONFLICT_TRACE, "conflict`n")
exit 99
'@
        [System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::SetUnixFileMode(
            $path,
            [System.IO.UnixFileMode]::UserRead `
                -bor [System.IO.UnixFileMode]::UserWrite `
                -bor [System.IO.UnixFileMode]::UserExecute `
                -bor [System.IO.UnixFileMode]::GroupRead `
                -bor [System.IO.UnixFileMode]::GroupExecute `
                -bor [System.IO.UnixFileMode]::OtherRead `
                -bor [System.IO.UnixFileMode]::OtherExecute)
    }

    function New-ScriptHookFixture {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $runtimeRoot = Join-Path $root 'selected runtime outside discovery'
        $runtimeModule = Join-Path $runtimeRoot 'selected Avm.Authoring'
        Copy-Item -LiteralPath $script:sourceModule -Destination $runtimeModule -Recurse
        $manifest = Join-Path $runtimeModule 'Avm.Authoring.psd1'
        $module = Import-Module -Name $manifest -Force -PassThru

        $repository = Join-Path $root 'repository with spaces'
        $hooks = Join-Path $repository 'examples' 'default'
        $null = New-Item -ItemType Directory -Path (Join-Path $repository '.avm') -Force
        $null = New-Item -ItemType Directory -Path $hooks -Force
        [System.IO.File]::WriteAllText((Join-Path $repository 'main.tf'), "terraform {}`n")
        [System.IO.File]::WriteAllText(
            (Join-Path $repository '.avm' 'tool-version-overrides.json'),
            '{"terraform":"9.9.9-test"}')

        $avmHome = Join-Path $root 'private avm home'
        $toolDirectory = Join-Path $avmHome 'tools' 'terraform' '.overrides' '9.9.9-test'
        $toolPath = Join-Path $toolDirectory $(if ($IsWindows) { 'terraform.exe' } else { 'terraform' })
        New-HookTerraformExecutable -Path $toolPath
        [System.IO.File]::WriteAllText((Join-Path $toolDirectory '.unverified'), '')
        $pins = Get-Content -LiteralPath (Join-Path $runtimeModule 'Resources' 'avm.pins.jsonc') -Raw |
            ConvertFrom-Json -AsHashtable
        $terraformPin = @($pins.tools | Where-Object name -CEQ 'terraform')[0]
        [System.IO.File]::WriteAllText(
            (Join-Path $toolDirectory '.meta.json'),
            (@{
                    name = 'terraform'
                    version = '9.9.9-test'
                    urlTemplate = $terraformPin.urlTemplate
                    sha256 = $null
                    checksumVerified = $false
                } | ConvertTo-Json -Compress))

        $pathDirectory = Join-Path $root 'conflicting path'
        New-ConflictingTerraformExecutable -Directory $pathDirectory
        $versionCommandDirectory = Join-Path $root 'version command'
        New-HookVersionCommand -Directory $versionCommandDirectory

        $fakeModule = Join-Path $root 'conflicting modules' 'Avm.Authoring'
        $null = New-Item -ItemType Directory -Path $fakeModule -Force
        $fakeMarker = Join-Path $root 'conflicting-module-imported'
        [System.IO.File]::WriteAllText(
            (Join-Path $fakeModule 'Avm.Authoring.psd1'),
            "@{ RootModule = 'Avm.Authoring.psm1'; ModuleVersion = '99.0.0'; FunctionsToExport = @('Get-AvmTool') }")
        $escapedMarker = $fakeMarker.Replace("'", "''")
        $fakeModuleContent = @"
Set-Content -LiteralPath '$escapedMarker' -Value imported
function Get-AvmTool { throw 'conflicting runtime won' }
"@
        [System.IO.File]::WriteAllText(
            (Join-Path $fakeModule 'Avm.Authoring.psm1'),
            $fakeModuleContent)

        $expectedModuleBase = (Resolve-Path -LiteralPath $runtimeModule).Path
        $hookContent = @'
$env:PSModulePath = ''
$module = Get-Module -Name Avm.Authoring
if ($null -eq $module -or $module.ModuleBase -cne $env:AVM_EXPECTED_MODULE_BASE) {
    throw 'The selected Avm.Authoring runtime was not loaded.'
}
$tool = Get-AvmTool -Name terraform -Path $env:AVM_HOOK_REPOSITORY
if ($tool.Version -cne '9.9.9-test' -or $tool.Source -cne 'cache' -or $tool.Path -cne $env:AVM_EXPECTED_TERRAFORM) {
    throw 'Get-AvmTool did not select the repository override from the managed cache.'
}
if ([string]::IsNullOrWhiteSpace($tool.Path)) {
    throw "Selected terraform is unavailable: $($tool.Status)"
}
& $tool.Path version -json
if ($LASTEXITCODE -ne 0) {
    throw "Selected terraform failed with exit code $LASTEXITCODE."
}
'@
        foreach ($name in @('pre.ps1', 'post.ps1')) {
            [System.IO.File]::WriteAllText(
                (Join-Path $hooks $name),
                $hookContent,
                [System.Text.UTF8Encoding]::new($false))
        }

        $testRunId = [guid]::NewGuid().ToString()
        [pscustomobject]@{
            Module = $module
            Manifest = $manifest
            ModuleBase = $expectedModuleBase
            Repository = $repository
            Hooks = $hooks
            AvmHome = $avmHome
            ToolPath = $toolPath
            PathDirectory = $pathDirectory
            VersionCommandDirectory = $versionCommandDirectory
            FakeModuleRoot = Split-Path -Parent $fakeModule
            FakeMarker = $fakeMarker
            Trace = Join-Path $root 'terraform.trace'
            ConflictTrace = Join-Path $root 'conflicting-terraform.trace'
            DataDirectory = Join-Path $root 'terraform data'
            TestRunId = $testRunId
        }
    }

    function Invoke-FixtureHook {
        param(
            [Parameter(Mandatory)]
            $Fixture,

            [Parameter(Mandatory)]
            [string] $Name
        )

        $environment = @{
            AVM_HOME = $Fixture.AvmHome
            AVM_NO_AUTO_INSTALL = '1'
            AVM_TEST_RUN_ID = $Fixture.TestRunId
            AVM_TEST_SKIP_MODULE_VERSION_CHECK = $Fixture.TestRunId
            AVM_EXPECTED_MODULE_BASE = $Fixture.ModuleBase
            AVM_EXPECTED_TERRAFORM = $Fixture.ToolPath
            AVM_HOOK_REPOSITORY = $Fixture.Repository
            AVM_HOOK_TRACE = $Fixture.Trace
            AVM_HOOK_PHASE = [System.IO.Path]::GetFileNameWithoutExtension($Name)
            AVM_CONFLICT_TRACE = $Fixture.ConflictTrace
            PSModulePath = $Fixture.FakeModuleRoot
            PATH = @(
                $Fixture.PathDirectory
                $Fixture.VersionCommandDirectory
                $env:PATH
            ) -join [System.IO.Path]::PathSeparator
            TF_DATA_DIR = $Fixture.DataDirectory
        }
        & $Fixture.Module {
            param($Path, $WorkingDirectory, $Environment)
            Invoke-AvmScriptHook `
                -HookPath $Path `
                -WorkingDirectory $WorkingDirectory `
                -EnvVars $Environment `
                -Label ([System.IO.Path]::GetFileName($Path))
        } (Join-Path $Fixture.Hooks $Name) $Fixture.Hooks $environment
    }
}

Describe 'Invoke-AvmScriptHook runtime propagation' -Tag Component {
    AfterEach {
        Get-Module -Name Avm.Authoring |
            Where-Object { $_.ModuleBase -like (Join-Path $TestDrive '*') } |
            Remove-Module -Force
    }

    It 'runs pre and post hooks with the exact selected runtime and managed terraform override' {
        $fixture = New-ScriptHookFixture

        Invoke-FixtureHook -Fixture $fixture -Name 'pre.ps1'
        Invoke-FixtureHook -Fixture $fixture -Name 'post.ps1'

        $records = @(Get-Content -LiteralPath $fixture.Trace)
        $records.Count | Should -Be 2
        $records[0] | Should -BeExactly ('pre|{0}|version,-json|{1}|{2}' -f
            $fixture.ToolPath, $fixture.Hooks, $fixture.DataDirectory)
        $records[1] | Should -BeExactly ('post|{0}|version,-json|{1}|{2}' -f
            $fixture.ToolPath, $fixture.Hooks, $fixture.DataDirectory)
        Test-Path -LiteralPath $fixture.FakeMarker | Should -BeFalse
        Test-Path -LiteralPath $fixture.ConflictTrace | Should -BeFalse
    }

    It 'fails when the selected runtime manifest is unavailable without loading another runtime' {
        $fixture = New-ScriptHookFixture
        Remove-Item -LiteralPath $fixture.Manifest -Force

        { Invoke-FixtureHook -Fixture $fixture -Name 'pre.ps1' } |
            Should -Throw '*Avm.Authoring.psd1*'
        Test-Path -LiteralPath $fixture.Trace | Should -BeFalse
        Test-Path -LiteralPath $fixture.FakeMarker | Should -BeFalse
        Test-Path -LiteralPath $fixture.ConflictTrace | Should -BeFalse
    }

    It 'fails when selected terraform is unavailable without installing or using PATH' {
        $fixture = New-ScriptHookFixture
        Remove-Item -LiteralPath $fixture.ToolPath -Force

        { Invoke-FixtureHook -Fixture $fixture -Name 'post.ps1' } |
            Should -Throw '*Get-AvmTool did not select the repository override from the managed cache*'
        Test-Path -LiteralPath $fixture.Trace | Should -BeFalse
        Test-Path -LiteralPath $fixture.ToolPath | Should -BeFalse
        Test-Path -LiteralPath $fixture.FakeMarker | Should -BeFalse
        Test-Path -LiteralPath $fixture.ConflictTrace | Should -BeFalse
    }
}
