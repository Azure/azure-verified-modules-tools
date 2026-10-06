#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Integration: packaged Bicep compliance' -Tag Integration {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        $manifest = Join-Path $repoRoot 'out' 'Avm.Authoring' 'Avm.Authoring.psd1'
        if (-not (Test-Path -LiteralPath $manifest)) {
            throw 'Run .\build.ps1 build before this installed-package acceptance test.'
        }
        $script:package = Join-Path $TestDrive 'installed-compliance' 'Avm.Authoring'
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
        $template = Join-Path $script:consumer '.avm' 'avm-readme-v1.scriban'
        $null = New-Item -ItemType Directory -Path (Split-Path $template) -Force
        Copy-Item -LiteralPath (Join-Path $script:package 'Resources' 'bicep' 'avm-readme-v1.scriban') -Destination $template
        @{
            documentation = @{ template = @{ file = '.avm/avm-readme-v1.scriban' } }
            analyzers = @{ core = @{ enabled = $true } }
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $script:consumer 'bicepconfig.json')
        InModuleScope Avm.Authoring -Parameters @{ Path = $script:modulePath } {
            param($Path)
            $tool = Resolve-AvmTool -Name bicep
            $compiled = Get-AvmBicepCompiledJson -SourcePath (Join-Path $Path 'main.bicep') -ToolPath $tool.Path
            [System.IO.File]::WriteAllText((Join-Path $Path 'main.json'), $compiled, [System.Text.UTF8Encoding]::new($false))
            $script:realPublicationProcess = (Get-Command Invoke-AvmProcess).ScriptBlock
            Mock Invoke-AvmProcess { & $script:realPublicationProcess @PesterBoundParameters }
            Mock Invoke-AvmProcess {
                [pscustomobject]@{ ExitCode = 0; StdOut = "$('a' * 40)`trefs/heads/main"; StdErr = '' }
            } -ParameterFilter {
                $ArgumentList[0] -eq 'ls-remote' -and $ArgumentList[1] -eq '--heads' -and
                $ArgumentList[2] -eq 'https://github.com/Azure/bicep-registry-modules.git'
            }
            Mock Invoke-AvmWebRequest {
                throw "Unexpected publication endpoint: $Uri"
            }
            Mock Invoke-AvmWebRequest {
                [pscustomobject]@{
                    StatusCode = 404
                    Content = '404: Not Found'
                    BaseResponse = [pscustomobject]@{
                        RequestMessage = [pscustomobject]@{ RequestUri = [uri]$Uri }
                    }
                }
            } -ParameterFilter {
                $Uri -like "https://raw.githubusercontent.com/Azure/bicep-registry-modules/$('a' * 40)/avm/res/storage/storage-account/*.json"
            }
            Mock Get-AvmBicepMcrTagList {
                [pscustomobject]@{ Tags = [System.Collections.Generic.HashSet[string]]::new([string[]]@('0.1.0')) }
            }
            Mock Get-AvmBicepApiSpecList {
                @{
                    'Microsoft.Resources' = @{ deployments = @('2025-04-01') }
                    'Microsoft.Storage' = @{
                        storageAccounts = @('2025-06-01')
                        'storageAccounts/blobServices' = @('2025-06-01')
                    }
                }
            }
        }
        $generated = Invoke-AvmDocs -Path $script:modulePath -SkipModuleVersionCheck
        $generated.Status | Should -Be 'pass' -Because (@($generated.Issues | ForEach-Object Message) -join '; ')
    }

    It 'runs native compliance and an authored unit test without any registry utilities' {
        Test-Path -LiteralPath (Join-Path $script:consumer 'utilities') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:consumer '.git') | Should -BeFalse
        (Get-Module Avm.Authoring).ModuleBase | Should -BeExactly $script:package
        (Get-Module Avm.Authoring).PrivateData.AvmCapabilities.BicepPackagedCompliance | Should -Be 1
        $result = Invoke-AvmTestUnit -Path $script:modulePath -Recurse -IncludeCompliance
        $result.Status | Should -Be 'pass' -Because (@($result.Issues | ForEach-Object Message) -join '; ')
        $result.ComplianceFile | Should -BeExactly (Join-Path $script:package 'Resources' 'bicep' 'Compliance.Tests.ps1')
        $result.UnitFiles | Should -Be 1
        $result.FilesProcessed | Should -Be 2
        $result.RunsTotal | Should -Be 187
        $result.RunsPassed | Should -Be $result.RunsTotal -Because (@($result.Issues | ForEach-Object Message) -join '; ')
        $result.RunsFailed | Should -Be 0
        $result.Issues | Should -HaveCount 0
        InModuleScope Avm.Authoring {
            Should -Invoke Invoke-AvmWebRequest -Exactly 2
            Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter {
                $ArgumentList[0] -in @('clone', 'fetch', 'checkout', 'show', 'ls-tree', 'diff')
            }
        }
    }

    It 'reports useful packaged diagnostics for <Violation>' -ForEach @(
        @{ Violation = 'missing metadata'; Code = 'AVM_METADATA_MISSING' }
        @{ Violation = 'invalid metadata'; Code = 'AVM_METADATA_SCHEMA' }
        @{ Violation = 'telemetry'; Code = 'avm.bicep.telemetry-parameter' }
        @{ Violation = 'README'; Code = 'avm.bicep.docs-stale' }
    ) {
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        switch ($Violation) {
            'missing metadata' {
                Remove-Item -LiteralPath (Join-Path $script:modulePath 'metadata.json')
            }
            'invalid metadata' {
                $path = Join-Path $script:modulePath 'metadata.json'
                $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
                $data.owners = 'invalid'
                [System.IO.File]::WriteAllText($path, ($data | ConvertTo-Json -Depth 10), $utf8)
            }
            'telemetry' {
                $path = Join-Path $script:modulePath 'main.bicep'
                $source = [System.IO.File]::ReadAllText($path).Replace(
                    'param enableTelemetry bool = true', 'param enableTelemetry bool = false')
                [System.IO.File]::WriteAllText($path, $source, $utf8)
            }
            'README' {
                [System.IO.File]::AppendAllText((Join-Path $script:modulePath 'README.md'), "`nStale content.`n", $utf8)
            }
        }
        $result = Invoke-AvmTestUnit -Path $script:modulePath -Recurse -IncludeCompliance
        $result.Status | Should -Be 'fail'
        $diagnostics = @($result.Issues | Where-Object { $_.Code -eq $Code })
        $diagnostics.Count | Should -BeGreaterThan 0 -Because (@($result.Issues | ForEach-Object Message) -join '; ')
        $diagnostics[0].File | Should -Not -BeNullOrEmpty
        $diagnostics[0].Message | Should -Not -BeNullOrEmpty
        $diagnostics[0].Severity | Should -Be 'error'
        $result.UnitFiles | Should -Be 1
    }
}
