#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmTerraformTransform' {
    BeforeEach {
        $script:moduleDir = Join-Path $TestDrive ("tf-mod-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:moduleDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'main.tf') -Value 'resource "null_resource" "x" {}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'variables.tf') -Value 'variable "y" {}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'README.md') -Value '# readme' -Encoding utf8

        $script:context = [pscustomobject][ordered]@{
            Kind      = 'terraform-module-repo'
            Root      = $script:moduleDir
            Ecosystem = 'terraform'
            Source    = 'path-heuristic'
        }
    }

    It 'rejects a non-terraform context' {
        $bicepCtx = [pscustomobject][ordered]@{
            Kind      = 'bicep-module'
            Root      = $TestDrive
            Ecosystem = 'bicep'
            Source    = 'path-heuristic'
        }
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $bicepCtx } {
                param($C)
                Invoke-AvmTerraformTransform -Context $C
            }
        } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'runs transform then clean-backup with the config and module dirs, reporting pass on a no-op' {
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'mapotf'; Version = '0.1.4'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/mapotf'
                }
            }
            Mock Resolve-AvmMapotfConfigDir { '/fake/configs' }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmTerraformTransform -Context $C
        }
        $result.Engine         | Should -Be 'terraform'
        $result.Tool           | Should -Be 'mapotf/0.1.4'
        $result.ToolPath       | Should -Be '/fake/mapotf'
        $result.ToolSource     | Should -Be 'cache'
        $result.Status         | Should -Be 'pass'
        $result.FilesProcessed | Should -Be 2
        @($result.Changed).Count | Should -Be 0
        @($result.Issues).Count  | Should -Be 0

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $FilePath -eq '/fake/mapotf' -and
                $ArgumentList[0] -eq 'transform' -and
                $ArgumentList -contains '--mptf-dir' -and
                $ArgumentList -contains '/fake/configs' -and
                $ArgumentList -contains '--tf-dir'
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $FilePath -eq '/fake/mapotf' -and
                $ArgumentList[0] -eq 'clean-backup' -and
                $ArgumentList -contains '--tf-dir'
            }
        }
    }

    It 'prepends the resolved terraform directory to PATH for the mapotf subprocess' {
        $ctx = $script:context
        InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                if ($Name -eq 'terraform') {
                    [pscustomobject]@{
                        Name = 'terraform'; Version = '1.15.3'; Platform = 'linux-amd64'
                        Source = 'cache'; Path = '/fake/tools/terraform/1.15.3/terraform'
                    }
                }
                else {
                    [pscustomobject]@{
                        Name = 'mapotf'; Version = '0.1.4'; Platform = 'linux-amd64'
                        Source = 'cache'; Path = '/fake/mapotf'
                    }
                }
            }
            Mock Resolve-AvmMapotfConfigDir { '/fake/configs' }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmTerraformTransform -Context $C

            Should -Invoke Resolve-AvmTool -Exactly 1 -ParameterFilter { $Name -eq 'terraform' }
            # Both mapotf calls (transform + clean-backup) carry the PATH override.
            # Derive the expected prefix with the same Split-Path the engine uses
            # so the assertion is OS-agnostic (Windows yields backslashes).
            Should -Invoke Invoke-AvmProcess -Exactly 2 -ParameterFilter {
                $expectedDir = Split-Path -Parent '/fake/tools/terraform/1.15.3/terraform'
                $null -ne $EnvVars -and
                $EnvVars.ContainsKey('PATH') -and
                $EnvVars['PATH'].StartsWith($expectedDir + [System.IO.Path]::PathSeparator)
            }
        }
    }

    It 'reports the files mapotf changed in the Changed array' {
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'mapotf'; Version = '0.1.4'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/mapotf'
                }
            }
            Mock Resolve-AvmMapotfConfigDir { '/fake/configs' }
            Mock Invoke-AvmProcess {
                if ($ArgumentList[0] -eq 'transform') {
                    $i = [array]::IndexOf([object[]]$ArgumentList, '--tf-dir')
                    $tfDir = $ArgumentList[$i + 1]
                    Add-Content -LiteralPath (Join-Path $tfDir 'main.tf') -Value '# rewritten by mapotf'
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmTerraformTransform -Context $C
        }
        $result.Status           | Should -Be 'pass'
        @($result.Changed).Count | Should -Be 1
        $result.Changed[0]       | Should -Be 'main.tf'
        @($result.Issues).Count  | Should -Be 0
    }

    It 'flags every changed file as a drift Issue under -CheckDrift' {
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'mapotf'; Version = '0.1.4'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/mapotf'
                }
            }
            Mock Resolve-AvmMapotfConfigDir { '/fake/configs' }
            Mock Invoke-AvmProcess {
                if ($ArgumentList[0] -eq 'transform') {
                    $i = [array]::IndexOf([object[]]$ArgumentList, '--tf-dir')
                    $tfDir = $ArgumentList[$i + 1]
                    Add-Content -LiteralPath (Join-Path $tfDir 'variables.tf') -Value 'variable "z" {}'
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmTerraformTransform -Context $C -CheckDrift
        }
        $result.Status             | Should -Be 'fail'
        @($result.Changed).Count   | Should -Be 1
        @($result.Issues).Count    | Should -Be 1
        $result.Issues[0].File     | Should -Be 'variables.tf'
        $result.Issues[0].Severity | Should -Be 'error'
        $result.Issues[0].Code     | Should -Be 'avm.tf.mapotf-drift'
    }

    It 'reports pass under -CheckDrift when mapotf changes nothing' {
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'mapotf'; Version = '0.1.4'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/mapotf'
                }
            }
            Mock Resolve-AvmMapotfConfigDir { '/fake/configs' }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmTerraformTransform -Context $C -CheckDrift
        }
        $result.Status          | Should -Be 'pass'
        @($result.Issues).Count | Should -Be 0
    }

    It 'throws AvmProcessException when mapotf transform exits non-zero' {
        $ctx = $script:context
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool {
                    [pscustomobject]@{
                        Name = 'mapotf'; Version = '0.1.4'; Platform = 'linux-amd64'
                        Source = 'cache'; Path = '/fake/mapotf'
                    }
                }
                Mock Resolve-AvmMapotfConfigDir { '/fake/configs' }
                Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 2; StdOut = ''; StdErr = 'boom' } }
                Invoke-AvmTerraformTransform -Context $C
            }
        }
        catch {
            $err = $_.Exception
        }
        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmProcessException'
        $err.Message        | Should -Match 'transform'
    }

    It 'throws AvmProcessException when mapotf clean-backup exits non-zero' {
        $ctx = $script:context
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool {
                    [pscustomobject]@{
                        Name = 'mapotf'; Version = '0.1.4'; Platform = 'linux-amd64'
                        Source = 'cache'; Path = '/fake/mapotf'
                    }
                }
                Mock Resolve-AvmMapotfConfigDir { '/fake/configs' }
                Mock Invoke-AvmProcess {
                    if ($ArgumentList[0] -eq 'clean-backup') {
                        return [pscustomobject]@{ ExitCode = 3; StdOut = ''; StdErr = 'cleanup failed' }
                    }
                    [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
                }
                Invoke-AvmTerraformTransform -Context $C
            }
        }
        catch {
            $err = $_.Exception
        }
        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmProcessException'
        $err.Message        | Should -Match 'clean-backup'
    }

    It 'propagates AvmToolException when the mapotf binary is unavailable' {
        $ctx = $script:context
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool { throw [AvmToolException]::new('mapotf not installed') }
                Invoke-AvmTerraformTransform -Context $C
            }
        }
        catch {
            $err = $_.Exception
        }
        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmToolException'
    }

    It 'propagates AvmConfigurationException when the config bundle cannot be resolved' {
        $ctx = $script:context
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool {
                    [pscustomobject]@{
                        Name = 'mapotf'; Version = '0.1.4'; Platform = 'linux-amd64'
                        Source = 'cache'; Path = '/fake/mapotf'
                    }
                }
                Mock Resolve-AvmMapotfConfigDir { throw [AvmConfigurationException]::new('no configs') }
                Invoke-AvmTerraformTransform -Context $C
            }
        }
        catch {
            $err = $_.Exception
        }
        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmConfigurationException'
    }

    It 'returns a skipped envelope and runs mapotf zero times under -WhatIf' {
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'mapotf'; Version = '0.1.4'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/mapotf'
                }
            }
            Mock Resolve-AvmMapotfConfigDir { '/fake/configs' }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmTerraformTransform -Context $C -WhatIf
        }
        $result.Status         | Should -Be 'skipped'
        $result.FilesProcessed | Should -Be 2

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 0
        }
    }
}

Describe 'Resolve-AvmMapotfConfigDir' {
    BeforeAll {
        function script:New-AvmCfgBundle {
            param([string] $Path, [string] $FileName = 'sample.mptf.hcl')
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Path $FileName) -Value 'transform {}' -Encoding utf8
            return $Path
        }
    }

    BeforeEach {
        $script:savedConfigDir = $env:AVM_MPTF_CONFIG_DIR
    }

    AfterEach {
        if ($null -eq $script:savedConfigDir) {
            Remove-Item Env:\AVM_MPTF_CONFIG_DIR -ErrorAction SilentlyContinue
        }
        else {
            $env:AVM_MPTF_CONFIG_DIR = $script:savedConfigDir
        }
    }

    It 'prefers the AVM_MPTF_CONFIG_DIR override over the consumer and packaged bundles' {
        $override = script:New-AvmCfgBundle -Path (Join-Path $TestDrive ("cfg-" + [Guid]::NewGuid().ToString('N').Substring(0, 8)))
        $root = Join-Path $TestDrive ("repo-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        script:New-AvmCfgBundle -Path ([System.IO.Path]::Combine($root, 'config', 'mapotf', 'pre-commit')) -FileName 'consumer.mptf.hcl' | Out-Null
        $env:AVM_MPTF_CONFIG_DIR = $override

        $resolved = InModuleScope 'Avm.Authoring' -Parameters @{ R = $root } { param($R) Resolve-AvmMapotfConfigDir -Root $R }
        $resolved | Should -Be ((Resolve-Path -LiteralPath $override).ProviderPath)
    }

    It 'prefers the consumer config/mapotf/pre-commit bundle over the packaged module bundle' {
        Remove-Item Env:\AVM_MPTF_CONFIG_DIR -ErrorAction SilentlyContinue
        $root = Join-Path $TestDrive ("repo-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $consumer = script:New-AvmCfgBundle -Path ([System.IO.Path]::Combine($root, 'config', 'mapotf', 'pre-commit')) -FileName 'consumer.mptf.hcl'

        $resolved = InModuleScope 'Avm.Authoring' -Parameters @{ R = $root } { param($R) Resolve-AvmMapotfConfigDir -Root $R }
        $resolved | Should -Be ((Resolve-Path -LiteralPath $consumer).ProviderPath)
    }

    It 'skips an empty AVM_MPTF_CONFIG_DIR override and uses the consumer bundle' {
        $emptyOverride = Join-Path $TestDrive ("empty-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $emptyOverride -Force | Out-Null
        $root = Join-Path $TestDrive ("repo-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $consumer = script:New-AvmCfgBundle -Path ([System.IO.Path]::Combine($root, 'config', 'mapotf', 'pre-commit')) -FileName 'consumer.mptf.hcl'
        $env:AVM_MPTF_CONFIG_DIR = $emptyOverride

        $resolved = InModuleScope 'Avm.Authoring' -Parameters @{ R = $root } { param($R) Resolve-AvmMapotfConfigDir -Root $R }
        $resolved | Should -Be ((Resolve-Path -LiteralPath $consumer).ProviderPath)
    }

    It 'falls back to the packaged module bundle when no override or consumer bundle exists' {
        Remove-Item Env:\AVM_MPTF_CONFIG_DIR -ErrorAction SilentlyContinue
        $root = Join-Path $TestDrive ("bare-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $root -Force | Out-Null

        $resolved = InModuleScope 'Avm.Authoring' -Parameters @{ R = $root } { param($R) Resolve-AvmMapotfConfigDir -Root $R }
        $resolved | Should -Not -BeNullOrEmpty
        (Split-Path -Leaf $resolved) | Should -Be 'pre-commit'
        $resolved | Should -Match ([regex]::Escape([System.IO.Path]::Combine('Resources', 'mapotf', 'pre-commit')))
        @(Get-ChildItem -LiteralPath $resolved -Filter '*.mptf.hcl' -File).Count | Should -BeGreaterThan 0
    }
}
