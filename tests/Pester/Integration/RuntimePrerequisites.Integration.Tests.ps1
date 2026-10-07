#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Integration: isolated runtime prerequisites' -Tag Integration {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        $source = Join-Path $repoRoot 'out' 'Avm.Authoring'
        $script:package = Join-Path $TestDrive 'installed' 'Avm.Authoring'
        $null = New-Item -ItemType Directory -Path (Split-Path $script:package) -Force
        Copy-Item -LiteralPath $source -Destination $script:package -Recurse
        $script:manifest = Join-Path $script:package 'Avm.Authoring.psd1'
        Import-Module $script:manifest -Force
        $script:probe = Join-Path $repoRoot 'tests' 'fixtures' 'tools' 'Invoke-RuntimePrerequisites.ps1'
    }

    AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

    It 'runs packaged metadata, Bicep Pester, YAML and PSRule with no installed modules, then reuses the cache offline' -Skip:($env:AVM_OFFLINE -eq '1') {
        $root = Join-Path $TestDrive 'consumer'
        $cache = Join-Path $TestDrive 'avm-home'
        $null = New-Item -ItemType Directory -Path $root
        [System.IO.File]::WriteAllText((Join-Path $root 'main.tf'), 'locals { value = true }')
        [System.IO.File]::WriteAllText((Join-Path $root 'Runtime.Tests.ps1'), "Describe 'isolated runtime' { It 'executes the native suite' { 1 | Should -Be 1 } }")
        [System.IO.File]::WriteAllText((Join-Path $root 'workflow.yml'), "name: Runtime fixture`non: workflow_dispatch`n")
        $pins = Get-Content (Join-Path $script:package 'Resources' 'avm.pins.jsonc') -Raw | ConvertFrom-Json -AsHashtable

        foreach ($offline in @($false, $true)) {
            $resultPath = Join-Path $root "result-$offline.json"
            $environment = @{
                AVM_HOME = $cache; AVM_OFFLINE = if ($offline) { '1' } else { $null }
                AVM_NO_AUTO_INSTALL = if ($offline) { '1' } else { $null }
                AVM_MIRROR = $null; AVM_NO_CONSOLE_CONFIG = '1'
                GITHUB_ACTIONS = $null; GITHUB_STEP_SUMMARY = $null; GH_TOKEN = $null; GITHUB_TOKEN = $null
                ARM_CLIENT_ID = $null; ARM_CLIENT_SECRET = $null; ARM_TENANT_ID = $null; ARM_SUBSCRIPTION_ID = $null
                AZURE_CLIENT_ID = $null; AZURE_CLIENT_SECRET = $null; AZURE_TENANT_ID = $null
                PSRULE_TELEMETRY_OPTOUT = 'true'; NO_COLOR = '1'
            }
            $result = InModuleScope Avm.Authoring -Parameters @{
                Manifest = $script:manifest; Probe = $script:probe; Root = $root
                ResultPath = $resultPath; Environment = $environment; Pwsh = [Environment]::ProcessPath
            } {
                param($Manifest, $Probe, $Root, $ResultPath, $Environment, $Pwsh)
                Invoke-AvmProcess -FilePath $Pwsh -ArgumentList @(
                    '-NoProfile', '-NonInteractive', '-File', $Probe, '-ManifestPath', $Manifest,
                    '-Root', $Root, '-ResultPath', $ResultPath
                ) -EnvVars $Environment -WorkingDirectory $Root -TimeoutSec 300 -IgnoreExitCode
            }
            $result.ExitCode | Should -Be 0 -Because "$($result.StdOut)`n$($result.StdErr)"
            $report = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
            $report.Pester.Version | Should -Be $pins.powerShellModules.Pester.version
            $report.PolicyRules | Should -BeGreaterThan 0
            foreach ($path in $report.Paths.PSObject.Properties.Value) {
                $path | Should -Be (Join-Path $PSHOME 'Modules')
            }
            $report.Modules | Should -HaveCount 4
            foreach ($tool in $report.Modules) {
                $tool.Version | Should -Be $pins.powerShellModules[$tool.Name].version
                $tool.Path | Should -BeLike (Join-Path $cache '*')
                $tool.Source | Should -Be 'cache'
                $verification = Get-Content (Join-Path (Split-Path $tool.Path) '.meta.json') -Raw | ConvertFrom-Json
                $verification.sha256 | Should -Be $pins.powerShellModules[$tool.Name].sha256
                $verification.checksumVerified | Should -BeTrue
            }
        }
    }
}
