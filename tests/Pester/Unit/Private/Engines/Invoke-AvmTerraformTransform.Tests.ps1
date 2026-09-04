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

    It 'runs root, module, and common profiles for the root then cleans backups' {
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'mapotf'; Version = '0.1.5'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/mapotf'
                }
            }
            Mock Resolve-AvmMapotfConfigDir { "/fake/$Profile" }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmTerraformTransform -Context $C
        }
        $result.Engine         | Should -Be 'terraform'
        $result.Tool           | Should -Be 'mapotf/0.1.5'
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
                ([array]::IndexOf($ArgumentList, '/fake/root')) -lt ([array]::IndexOf($ArgumentList, '/fake/module')) -and
                ([array]::IndexOf($ArgumentList, '/fake/module')) -lt ([array]::IndexOf($ArgumentList, '/fake/common')) -and
                $ArgumentList -contains '--tf-dir'
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $FilePath -eq '/fake/mapotf' -and
                $ArgumentList[0] -eq 'clean-backup' -and
                $ArgumentList -contains '--tf-dir'
            }
        }
    }

    It 'schedules independent targets with the requested throttle' {
        $ctx = $script:context
        InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = $Name; Version = 'test'; Platform = 'test'
                    Source = 'cache'; Path = "/fake/$Name"
                }
            }
            Mock Resolve-AvmMapotfConfigDir { "/fake/$Profile" }
            Mock Get-AvmTerraformTransformTarget {
                @(
                    [pscustomobject]@{ Path = $C.Root; Scope = 'root'; Profiles = @('root', 'module', 'common') }
                    [pscustomobject]@{ Path = '/fake/example'; Scope = 'example'; Profiles = @('common', 'example') }
                )
            }
            Mock Invoke-AvmParallel
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }

            Invoke-AvmTerraformTransform -Context $C -ThrottleLimit 4 | Out-Null

            Should -Invoke Invoke-AvmParallel -Exactly 1 -ParameterFilter {
                $FunctionName -eq 'Invoke-AvmMapotfTransformTarget' -and
                $InputObject.Count -eq 2 -and
                $ThrottleLimit -eq 4
            }
        }
    }

    It 'uses a serial target throttle when Terraform has a shared plugin cache' {
        $ctx = $script:context
        InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            $savedPluginCache = $env:TF_PLUGIN_CACHE_DIR
            try {
                $env:TF_PLUGIN_CACHE_DIR = '/fake/plugin-cache'
                Mock Resolve-AvmTool {
                    [pscustomobject]@{
                        Name = $Name; Version = 'test'; Platform = 'test'
                        Source = 'cache'; Path = "/fake/$Name"
                    }
                }
                Mock Resolve-AvmMapotfConfigDir { "/fake/$Profile" }
                Mock Get-AvmTerraformTransformTarget {
                    @(
                        [pscustomobject]@{ Path = $C.Root; Scope = 'root'; Profiles = @('root', 'module', 'common') }
                        [pscustomobject]@{ Path = '/fake/example'; Scope = 'example'; Profiles = @('common', 'example') }
                    )
                }
                Mock Invoke-AvmParallel
                Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }

                Invoke-AvmTerraformTransform -Context $C -ThrottleLimit 4 | Out-Null

                Should -Invoke Invoke-AvmParallel -Exactly 1 -ParameterFilter {
                    $ThrottleLimit -eq 1
                }
            }
            finally {
                $env:TF_PLUGIN_CACHE_DIR = $savedPluginCache
            }
        }
    }

    It 'removes competing terraform binaries from the child PATH without mutating the caller PATH' {
        $ctx = $script:context
        $entrypoint = if ([OperatingSystem]::IsWindows()) { 'terraform.exe' } else { 'terraform' }
        $pinnedDir = Join-Path $TestDrive 'pinned-terraform'
        $strayDir = Join-Path $TestDrive 'stray-terraform'
        $safeDir = Join-Path $TestDrive 'safe-bin'
        New-Item -ItemType Directory -Path $pinnedDir, $strayDir, $safeDir -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $pinnedDir $entrypoint), (Join-Path $strayDir $entrypoint) -Force | Out-Null
        $injectedPath = @($strayDir, $safeDir, $pinnedDir) -join [System.IO.Path]::PathSeparator

        $originalPath = $env:PATH
        try {
            $env:PATH = $injectedPath
            $observedPath = InModuleScope 'Avm.Authoring' -Parameters @{
                C = $ctx
                P = (Join-Path $pinnedDir $entrypoint)
            } {
                param($C, $P)
                Mock Resolve-AvmTool {
                    if ($Name -eq 'terraform') {
                        [pscustomobject]@{
                            Name = 'terraform'; Version = '1.15.8'; Platform = 'test'
                            Source = 'cache'; Path = $P
                        }
                    }
                    else {
                        [pscustomobject]@{
                            Name = 'mapotf'; Version = '0.1.5'; Platform = 'test'
                            Source = 'cache'; Path = (Join-Path $TestDrive 'mapotf')
                        }
                    }
                }
                Mock Resolve-AvmMapotfConfigDir { $TestDrive }
                Mock Invoke-AvmProcess {
                    $script:childPath = $EnvVars['PATH']
                    [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
                }
                Invoke-AvmTerraformTransform -Context $C | Out-Null
                return $script:childPath
            }

            $entries = @($observedPath -split [regex]::Escape([string][System.IO.Path]::PathSeparator))
            $entries[0] | Should -Be $pinnedDir
            $entries | Should -Contain $safeDir
            $entries | Should -Not -Contain $strayDir
            @($entries | Where-Object {
                    Test-Path -LiteralPath (Join-Path $_ $entrypoint) -PathType Leaf
                }).Count | Should -Be 1
            $env:PATH | Should -Be $injectedPath
        }
        finally {
            $env:PATH = $originalPath
        }
    }

    It 'reports the files mapotf changed in the Changed array' {
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'mapotf'; Version = '0.1.5'; Platform = 'linux-amd64'
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
                    Name = 'mapotf'; Version = '0.1.5'; Platform = 'linux-amd64'
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
                    Name = 'mapotf'; Version = '0.1.5'; Platform = 'linux-amd64'
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

    It 'leaves modified .tf files byte-identical after a drift-mode run' {
        $ctx = $script:context
        $variables = Join-Path $script:moduleDir 'variables.tf'
        $originalBytes = [System.IO.File]::ReadAllBytes($variables)

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'mapotf'; Version = '0.1.5'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/mapotf'
                }
            }
            Mock Resolve-AvmMapotfConfigDir { '/fake/configs' }
            Mock Invoke-AvmProcess {
                if ($ArgumentList -contains 'transform') {
                    $i = [array]::IndexOf([object[]]$ArgumentList, '--tf-dir')
                    $tfDir = $ArgumentList[$i + 1]
                    Add-Content -LiteralPath (Join-Path $tfDir 'variables.tf') -Value 'variable "z" {}'
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmTerraformTransform -Context $C -CheckDrift
        }

        $result.Status | Should -Be 'fail'
        [System.IO.File]::ReadAllBytes($variables) | Should -Be $originalBytes
    }

    It 'removes a .tf file that mapotf created during a drift-mode run' {
        $ctx = $script:context
        $created = Join-Path $script:moduleDir 'generated.tf'

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'mapotf'; Version = '0.1.5'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/mapotf'
                }
            }
            Mock Resolve-AvmMapotfConfigDir { '/fake/configs' }
            Mock Invoke-AvmProcess {
                if ($ArgumentList -contains 'transform') {
                    $i = [array]::IndexOf([object[]]$ArgumentList, '--tf-dir')
                    $tfDir = $ArgumentList[$i + 1]
                    Set-Content -LiteralPath (Join-Path $tfDir 'generated.tf') -Value 'output "g" {}' -Encoding utf8
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmTerraformTransform -Context $C -CheckDrift
        }

        $result.Status | Should -Be 'fail'
        Test-Path -LiteralPath $created | Should -BeFalse
    }

    It 'recreates a .tf file that mapotf deleted during a drift-mode run' {
        $ctx = $script:context
        $variables = Join-Path $script:moduleDir 'variables.tf'
        $originalBytes = [System.IO.File]::ReadAllBytes($variables)

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'mapotf'; Version = '0.1.5'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/mapotf'
                }
            }
            Mock Resolve-AvmMapotfConfigDir { '/fake/configs' }
            Mock Invoke-AvmProcess {
                if ($ArgumentList -contains 'transform') {
                    $i = [array]::IndexOf([object[]]$ArgumentList, '--tf-dir')
                    $tfDir = $ArgumentList[$i + 1]
                    Remove-Item -LiteralPath (Join-Path $tfDir 'variables.tf') -Force -ErrorAction SilentlyContinue
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmTerraformTransform -Context $C -CheckDrift
        }

        $result.Status | Should -Be 'fail'
        Test-Path -LiteralPath $variables | Should -BeTrue
        [System.IO.File]::ReadAllBytes($variables) | Should -Be $originalBytes
    }

    It 'still rewrites .tf files when drift mode is off' {
        $ctx = $script:context
        $variables = Join-Path $script:moduleDir 'variables.tf'
        $originalBytes = [System.IO.File]::ReadAllBytes($variables)

        $null = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'mapotf'; Version = '0.1.5'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/mapotf'
                }
            }
            Mock Resolve-AvmMapotfConfigDir { '/fake/configs' }
            Mock Invoke-AvmProcess {
                if ($ArgumentList -contains 'transform') {
                    $i = [array]::IndexOf([object[]]$ArgumentList, '--tf-dir')
                    $tfDir = $ArgumentList[$i + 1]
                    Add-Content -LiteralPath (Join-Path $tfDir 'variables.tf') -Value 'variable "z" {}'
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmTerraformTransform -Context $C
        }

        [System.IO.File]::ReadAllBytes($variables) | Should -Not -Be $originalBytes
    }

    It 'retries a transient provider timeout and then succeeds' {
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            $script:transformAttempts = 0
            Mock Resolve-AvmTool {
                [pscustomobject]@{
                    Name = 'mapotf'; Version = '0.1.5'; Platform = 'linux-amd64'
                    Source = 'cache'; Path = '/fake/mapotf'
                }
            }
            Mock Resolve-AvmMapotfConfigDir { '/fake/configs' }
            Mock Start-Sleep
            Mock Invoke-AvmProcess {
                if ($ArgumentList[0] -eq 'transform') {
                    $script:transformAttempts++
                    if ($script:transformAttempts -eq 1) {
                        return [pscustomobject]@{
                            ExitCode = 1
                            StdOut   = ''
                            StdErr   = 'context deadline exceeded: Client.Timeout exceeded while awaiting headers'
                        }
                    }
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmTerraformTransform -Context $C
        }

        $result.Status | Should -Be 'pass'
        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 2 -ParameterFilter {
                $ArgumentList[0] -eq 'transform'
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'clean-backup'
            }
            Should -Invoke Start-Sleep -Exactly 1 -ParameterFilter {
                $Seconds -eq 5
            }
        }
    }

    It 'throws after exhausting transient provider download retries' {
        $ctx = $script:context
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool {
                    [pscustomobject]@{
                        Name = 'mapotf'; Version = '0.1.5'; Platform = 'linux-amd64'
                        Source = 'cache'; Path = '/fake/mapotf'
                    }
                }
                Mock Resolve-AvmMapotfConfigDir { '/fake/configs' }
                Mock Start-Sleep
                Mock Invoke-AvmProcess {
                    [pscustomobject]@{
                        ExitCode = 1
                        StdOut   = ''
                        StdErr   = 'failed to retrieve cryptographic signature for provider'
                    }
                }
                Invoke-AvmTerraformTransform -Context $C
            }
        }
        catch {
            $err = $_.Exception
        }

        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmProcessException'
        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 3 -ParameterFilter {
                $ArgumentList[0] -eq 'transform'
            }
            Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter {
                $ArgumentList[0] -eq 'clean-backup'
            }
            Should -Invoke Start-Sleep -Exactly 2
        }
    }

    It 'throws AvmProcessException when mapotf transform exits non-zero' {
        $ctx = $script:context
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool {
                    [pscustomobject]@{
                        Name = 'mapotf'; Version = '0.1.5'; Platform = 'linux-amd64'
                        Source = 'cache'; Path = '/fake/mapotf'
                    }
                }
                Mock Resolve-AvmMapotfConfigDir { '/fake/configs' }
                Mock Start-Sleep
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
        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'transform'
            }
            Should -Invoke Start-Sleep -Exactly 0
        }
    }

    It 'throws AvmProcessException when a scoped target transform exits non-zero' {
        $ctx = $script:context
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool {
                    [pscustomobject]@{
                        Name = 'mapotf'; Version = '0.1.5'; Platform = 'linux-amd64'
                        Source = 'cache'; Path = '/fake/mapotf'
                    }
                }
                Mock Resolve-AvmMapotfConfigDir { "/fake/$Profile" }
                Mock Get-AvmTerraformTransformTarget {
                    @(
                        [pscustomobject]@{ Path = $C.Root; Scope = 'root'; Profiles = @('root', 'module', 'common') }
                        [pscustomobject]@{ Path = '/fake/module'; Scope = 'module'; Profiles = @('module', 'common') }
                    )
                }
                Mock Invoke-AvmProcess {
                    $tfDirIndex = [array]::IndexOf([object[]]$ArgumentList, '--tf-dir')
                    if ($ArgumentList[0] -eq 'transform' -and $ArgumentList[$tfDirIndex + 1] -eq '/fake/module') {
                        return [pscustomobject]@{ ExitCode = 4; StdOut = ''; StdErr = 'module transform failed' }
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
        $err.Message        | Should -Match 'module target'
        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $tfDirIndex = [array]::IndexOf([object[]]$ArgumentList, '--tf-dir')
                $ArgumentList[0] -eq 'transform' -and $ArgumentList[$tfDirIndex + 1] -eq '/fake/module'
            }
            Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter {
                $ArgumentList[0] -eq 'clean-backup'
            }
        }
    }

    It 'throws AvmProcessException when mapotf clean-backup exits non-zero' {
        $ctx = $script:context
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool {
                    [pscustomobject]@{
                        Name = 'mapotf'; Version = '0.1.5'; Platform = 'linux-amd64'
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
                        Name = 'mapotf'; Version = '0.1.5'; Platform = 'linux-amd64'
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
                    Name = 'mapotf'; Version = '0.1.5'; Platform = 'linux-amd64'
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

Describe 'Get-AvmTerraformTransformTarget' {
    It 'returns scoped root, nested module, and direct example targets' {
        $root = Join-Path $TestDrive 'repo'
        $direct = Join-Path $root 'modules' 'direct'
        $nested = Join-Path $root 'modules' 'group' 'nested'
        $notModule = Join-Path $root 'modules' 'group' 'examples' 'default'
        $example = Join-Path $root 'examples' 'default'
        New-Item -ItemType Directory -Path $direct, $nested, $notModule, $example -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $direct 'terraform.tf') -Value 'terraform {}' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $nested 'terraform.tf') -Value 'terraform {}' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $notModule 'main.tf') -Value 'locals {}' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $example 'main.tf') -Value 'locals {}' -Encoding utf8NoBOM

        $targets = InModuleScope 'Avm.Authoring' -Parameters @{ R = $root } {
            param($R)
            @(Get-AvmTerraformTransformTarget -Root $R)
        }

        $targets | Should -HaveCount 4
        ($targets | Where-Object Path -eq $root).Profiles | Should -Be @('root', 'module', 'common')
        ($targets | Where-Object Path -eq $direct).Profiles | Should -Be @('module', 'common')
        ($targets | Where-Object Path -eq $nested).Profiles | Should -Be @('module', 'common')
        ($targets | Where-Object Path -eq $example).Profiles | Should -Be @('common', 'example')
        @($targets.Path) | Should -Not -Contain $notModule
    }
}

Describe 'Resolve-AvmMapotfConfigDir' {
    BeforeAll {
        function script:New-AvmCfgBundle {
            param(
                [string] $Path,
                [string] $Profile = 'common',
                [string] $FileName = 'sample.mptf.hcl'
            )
            $profilePath = Join-Path $Path $Profile
            New-Item -ItemType Directory -Path $profilePath -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $profilePath $FileName) -Value 'transform {}' -Encoding utf8
            return $profilePath
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
        script:New-AvmCfgBundle -Path ([System.IO.Path]::Combine($root, 'config', 'mapotf')) -FileName 'consumer.mptf.hcl' | Out-Null
        $env:AVM_MPTF_CONFIG_DIR = Split-Path -Parent $override

        $resolved = InModuleScope 'Avm.Authoring' -Parameters @{ R = $root } {
            param($R)
            Resolve-AvmMapotfConfigDir -Root $R -Profile common
        }
        $resolved | Should -Be ((Resolve-Path -LiteralPath $override).ProviderPath)
    }

    It 'prefers the consumer config/mapotf profile over the packaged profile' {
        Remove-Item Env:\AVM_MPTF_CONFIG_DIR -ErrorAction SilentlyContinue
        $root = Join-Path $TestDrive ("repo-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $consumer = script:New-AvmCfgBundle -Path ([System.IO.Path]::Combine($root, 'config', 'mapotf')) -FileName 'consumer.mptf.hcl'

        $resolved = InModuleScope 'Avm.Authoring' -Parameters @{ R = $root } {
            param($R)
            Resolve-AvmMapotfConfigDir -Root $R -Profile common
        }
        $resolved | Should -Be ((Resolve-Path -LiteralPath $consumer).ProviderPath)
    }

    It 'skips an empty AVM_MPTF_CONFIG_DIR profile and uses the consumer profile' {
        $emptyOverride = Join-Path $TestDrive ("empty-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $emptyOverride -Force | Out-Null
        $root = Join-Path $TestDrive ("repo-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $consumer = script:New-AvmCfgBundle -Path ([System.IO.Path]::Combine($root, 'config', 'mapotf')) -FileName 'consumer.mptf.hcl'
        $env:AVM_MPTF_CONFIG_DIR = $emptyOverride

        $resolved = InModuleScope 'Avm.Authoring' -Parameters @{ R = $root } {
            param($R)
            Resolve-AvmMapotfConfigDir -Root $R -Profile common
        }
        $resolved | Should -Be ((Resolve-Path -LiteralPath $consumer).ProviderPath)
    }

    It 'falls back to the packaged profile when no override or consumer profile exists' {
        Remove-Item Env:\AVM_MPTF_CONFIG_DIR -ErrorAction SilentlyContinue
        $root = Join-Path $TestDrive ("bare-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $root -Force | Out-Null

        $resolved = InModuleScope 'Avm.Authoring' -Parameters @{ R = $root } {
            param($R)
            Resolve-AvmMapotfConfigDir -Root $R -Profile common
        }
        $resolved | Should -Not -BeNullOrEmpty
        (Split-Path -Leaf $resolved) | Should -Be 'common'
        $resolved | Should -Match ([regex]::Escape([System.IO.Path]::Combine('Resources', 'mapotf', 'common')))
        @(Get-ChildItem -LiteralPath $resolved -Filter '*.mptf.hcl' -File).Count | Should -BeGreaterThan 0
    }

    It 'returns null for an absent optional example profile' {
        Remove-Item Env:\AVM_MPTF_CONFIG_DIR -ErrorAction SilentlyContinue
        $root = Join-Path $TestDrive ("bare-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $root -Force | Out-Null

        $resolved = InModuleScope 'Avm.Authoring' -Parameters @{ R = $root } {
            param($R)
            Resolve-AvmMapotfConfigDir -Root $R -Profile example -Optional
        }
        $resolved | Should -BeNullOrEmpty
    }
}
