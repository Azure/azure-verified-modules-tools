#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Bicep e2e case-local post hook paths' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ('post-hook-' + [guid]::NewGuid().ToString('N'))
        $script:caseDirectory = Join-Path $script:root 'tests' 'e2e' 'defaults'
        $null = New-Item -ItemType Directory -Path $script:caseDirectory -Force
        $script:casePath = Join-Path $script:caseDirectory 'main.test.bicep'
        Set-Content -LiteralPath $script:casePath -Value 'test case' -Encoding utf8NoBOM
    }

    It 'reports no hook when only another case has post.ps1' {
        $other = Join-Path $script:root 'tests' 'e2e' 'second'
        $null = New-Item -ItemType Directory -Path $other -Force
        Set-Content -LiteralPath (Join-Path $other 'post.ps1') `
            -Value 'other case' -Encoding utf8NoBOM
        InModuleScope 'Avm.Authoring' -Parameters @{
            R = $script:root; C = $script:casePath
        } {
            param($R, $C)
            Get-AvmBicepE2ePostHook -CasePath $C -ModuleRoot $R |
                Should -BeNullOrEmpty
        }
    }

    It 'accepts only the literal file beside the selected case' {
        $postPath = Join-Path $script:caseDirectory 'post.ps1'
        Set-Content -LiteralPath $postPath -Value 'local case' -Encoding utf8NoBOM
        InModuleScope 'Avm.Authoring' -Parameters @{
            R = $script:root; C = $script:casePath; P = $postPath
        } {
            param($R, $C, $P)
            Get-AvmBicepE2ePostHook -CasePath $C -ModuleRoot $R |
                Should -BeExactly $P
        }
    }

    It 'rejects wrong casing and a directory named post.ps1' -ForEach @(
        @{ Kind = 'case' }
        @{ Kind = 'directory' }
    ) {
        if ($Kind -eq 'case') {
            Set-Content -LiteralPath (Join-Path $script:caseDirectory 'Post.ps1') `
                -Value 'wrong casing' -Encoding utf8NoBOM
        }
        else {
            $null = New-Item -ItemType Directory `
                -Path (Join-Path $script:caseDirectory 'post.ps1')
        }
        InModuleScope 'Avm.Authoring' -Parameters @{
            R = $script:root; C = $script:casePath
        } {
            param($R, $C)
            { Get-AvmBicepE2ePostHook -CasePath $C -ModuleRoot $R } |
                Should -Throw -ExpectedMessage '*unlinked post.ps1 file with exact casing*'
        }
    }

    It 'refuses a case outside the module root' {
        $outside = Join-Path $TestDrive 'outside' 'main.test.bicep'
        InModuleScope 'Avm.Authoring' -Parameters @{
            R = $script:root; C = $outside
        } {
            param($R, $C)
            { Get-AvmBicepE2ePostHook -CasePath $C -ModuleRoot $R } |
                Should -Throw -ExpectedMessage '*outside the module root*'
        }
    }

    It 'refuses a linked post.ps1 that points outside the case' {
        $outside = Join-Path $TestDrive 'outside-post.ps1'
        Set-Content -LiteralPath $outside -Value 'external' -Encoding utf8NoBOM
        try {
            $null = New-Item -ItemType SymbolicLink `
                -Path (Join-Path $script:caseDirectory 'post.ps1') `
                -Target $outside -ErrorAction Stop
        }
        catch [System.UnauthorizedAccessException] {
            Set-ItResult -Skipped -Because 'Symbolic links require elevated or developer-mode permission on this host.'
            return
        }
        InModuleScope 'Avm.Authoring' -Parameters @{
            R = $script:root; C = $script:casePath
        } {
            param($R, $C)
            { Get-AvmBicepE2ePostHook -CasePath $C -ModuleRoot $R } |
                Should -Throw -ExpectedMessage '*unlinked post.ps1 file*'
        }
    }

    It 'refuses a linked case directory that appears inside the module root' {
        $outside = Join-Path $TestDrive 'external-case'
        $null = New-Item -ItemType Directory -Path $outside
        $link = Join-Path $script:root 'tests' 'e2e' 'linked'
        try {
            $null = New-Item -ItemType SymbolicLink -Path $link `
                -Target $outside -ErrorAction Stop
        }
        catch [System.UnauthorizedAccessException] {
            Set-ItResult -Skipped -Because 'Symbolic links require elevated or developer-mode permission on this host.'
            return
        }
        $linkedCase = Join-Path $link 'main.test.bicep'
        InModuleScope 'Avm.Authoring' -Parameters @{
            R = $script:root; C = $linkedCase
        } {
            param($R, $C)
            { Get-AvmBicepE2ePostHook -CasePath $C -ModuleRoot $R } |
                Should -Throw -ExpectedMessage '*linked directories*'
        }
    }
}

Describe 'Bicep e2e post hook subprocess' {
    It 'executes a case path containing spaces with only the supplied safe context' {
        $root = Join-Path $TestDrive ('post-process-' + [guid]::NewGuid().ToString('N'))
        $caseDirectory = Join-Path $root 'tests' 'e2e' 'case with spaces'
        $null = New-Item -ItemType Directory -Path $caseDirectory -Force
        $casePath = Join-Path $caseDirectory 'main.test.bicep'
        Set-Content -LiteralPath $casePath -Value 'test case' -Encoding utf8NoBOM
        $hook = Join-Path $caseDirectory 'post.ps1'
        Set-Content -LiteralPath $hook -Encoding utf8NoBOM -Value `
            '[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot ''context.txt''), "$($env:AVM_E2E_CASE)|$($env:AVM_E2E_SCOPE)|$($env:AVM_E2E_RUN_ID)")'
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $root; C = $casePath } {
            param($R, $C)
            $item = [pscustomobject]@{
                Case = [pscustomobject]@{
                    Path = $C
                    RelativePath = 'tests/e2e/case with spaces/main.test.bicep'
                    RelativeDirectory = 'tests/e2e/case with spaces'
                }
                Scope = 'group'
            }
            $issues = [System.Collections.Generic.List[object]]::new()
            $result = Invoke-AvmBicepE2ePostHook -Item $item -ModuleRoot $R `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -DeploymentName 'avm-e2e-cafebabe' -RunId 'cafebabe' `
                -Issues $issues
            $result.Status | Should -Be 'pass'
            $result.ExitCode | Should -Be 0
            $issues.Count | Should -Be 0
        }
        (Get-Content -LiteralPath (Join-Path $caseDirectory 'context.txt') -Raw) |
            Should -BeExactly 'tests/e2e/case with spaces|group|cafebabe'
    }

    It 'honors the scoped case ShouldProcess refusal without attempting a hook' {
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $TestDrive } {
            param($R)
            Mock Invoke-AvmBicepE2ePostHook {
                throw 'ShouldProcess refusal must not invoke post.ps1'
            }
            Mock Invoke-AvmProcess { throw 'ShouldProcess refusal must not run Azure' }
            $item = [pscustomobject]@{
                Scope = 'sub'
                DeploymentName = 'avm-e2e-cafebabe'
                Case = [pscustomobject]@{ RelativePath = 'tests/e2e/example/main.test.bicep' }
            }
            $result = Invoke-AvmBicepScopedTestE2eCase -Item $item -AzPath 'fake-az' `
                -SubscriptionId '00000000-0000-0000-0000-000000000001' `
                -TenantId '00000000-0000-0000-0000-000000000002' `
                -Location 'westus' -RepositoryRoot $R -WorkingDirectory $R -WhatIf
            $result.Attempted | Should -Be 0
            $result.PostResults.Count | Should -Be 0
            Should -Invoke Invoke-AvmBicepE2ePostHook -Exactly 0
            Should -Invoke Invoke-AvmProcess -Exactly 0
        }
    }
}
