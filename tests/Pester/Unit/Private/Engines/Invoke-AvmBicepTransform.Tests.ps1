#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmBicepTransform' {
    BeforeEach {
        $script:moduleDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:moduleDir -Force | Out-Null
        $script:source = Join-Path $script:moduleDir 'main.bicep'
        [System.IO.File]::WriteAllText($script:source, "param name string`n", [System.Text.UTF8Encoding]::new($false))
        $script:context = [pscustomobject]@{
            Kind = 'bicep-module'; Root = $script:moduleDir; Ecosystem = 'bicep'
        }
        $script:compiled = '{"$schema":"https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#","contentVersion":"1.0.0.0","resources":[]}'
        InModuleScope 'Avm.Authoring' -Parameters @{ J = $script:compiled } {
            param($J)
            $script:armJson = $J
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = 'bicep'; Version = 'pinned'; Source = 'cache'; Path = 'bicep' }
            }
            Mock Invoke-AvmProcess {
                [pscustomobject]@{ ExitCode = 0; StdOut = $script:armJson; StdErr = '' }
            }
        }
    }

    It 'writes the compiler output exactly, leaves source untouched, and does not rewrite an unchanged artifact' {
        $ctx = $script:context
        $before = [System.IO.File]::ReadAllBytes($script:source)
        $first = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Invoke-AvmBicepTransform -Context $C -Confirm:$false
        }
        $output = Join-Path $script:moduleDir 'main.json'
        $first.Status | Should -Be 'pass'
        $first.Changed | Should -Be @($output)
        $first.FilesProcessed | Should -Be 1
        [System.IO.File]::ReadAllBytes($output) |
            Should -Be ([System.Text.UTF8Encoding]::new($false).GetBytes($script:compiled))
        [System.IO.File]::ReadAllBytes($script:source) | Should -Be $before

        $timestamp = [datetime]::UtcNow.AddDays(-2)
        [System.IO.File]::SetLastWriteTimeUtc($output, $timestamp)
        $second = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Invoke-AvmBicepTransform -Context $C -Confirm:$false
        }
        $second.Status | Should -Be 'pass'
        $second.Changed.Count | Should -Be 0
        [System.IO.File]::GetLastWriteTimeUtc($output) | Should -Be $timestamp
    }

    It 'only compiles root and child sources in a monorepo, excluding proposed modules and tests' {
        $mono = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $root = Join-Path -Path $mono -ChildPath 'avm' -AdditionalChildPath 'res', 'mock', 'widgets'
        $child = Join-Path $root 'child'
        $proposed = Join-Path -Path $mono -ChildPath 'avm' -AdditionalChildPath 'res', 'mock', 'proposal'
        $testPath = Join-Path -Path $root -ChildPath 'tests' -AdditionalChildPath 'e2e', 'defaults'
        foreach ($directory in @($child, $proposed, $testPath)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        Set-Content -LiteralPath (Join-Path $root 'main.bicep') -Value 'param root string' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $child 'main.bicep') -Value 'param child string' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $proposed 'metadata.json') -Value '{}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $testPath 'main.bicep') -Value 'param test string' -Encoding utf8
        $ctx = [pscustomobject]@{ Kind = 'bicep-monorepo'; Root = $mono; Ecosystem = 'bicep' }

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Invoke-AvmBicepTransform -Context $C -Confirm:$false
        }

        $result.Status | Should -Be 'pass'
        $result.FilesProcessed | Should -Be 2
        Test-Path -LiteralPath (Join-Path $root 'main.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $child 'main.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $proposed 'main.json') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $testPath 'main.json') | Should -BeFalse
        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 2
        }
    }

    It 'reports stale and missing compiled files without modifying either one in drift mode' {
        $child = Join-Path $script:moduleDir 'child'
        New-Item -ItemType Directory -Path $child | Out-Null
        Set-Content -LiteralPath (Join-Path $child 'main.bicep') -Value 'param child string' -Encoding utf8
        $output = Join-Path $script:moduleDir 'main.json'
        [System.IO.File]::WriteAllText($output, '{"stale":true}', [System.Text.UTF8Encoding]::new($false))
        $before = [System.IO.File]::ReadAllBytes($output)
        $ctx = $script:context

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Invoke-AvmBicepTransform -Context $C -CheckDrift
        }

        $result.Status | Should -Be 'fail'
        $result.Changed.Count | Should -Be 0
        $result.Issues.Count | Should -Be 2
        $result.Issues.Code | Should -Contain 'avm.bicep.json-stale'
        $result.Issues.Code | Should -Contain 'avm.bicep.json-missing'
        ($result.Issues.File -join ',') | Should -Match 'child/main\.json'
        ($result.Issues.Message -join ',') | Should -Match 'avm pre-commit'
        [System.IO.File]::ReadAllBytes($output) | Should -Be $before
        Test-Path -LiteralPath (Join-Path $child 'main.json') | Should -BeFalse
    }

    It 'validates and reports planned output without writing it under WhatIf' {
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Invoke-AvmBicepTransform -Context $C -WhatIf
        }
        $result.Status | Should -Be 'skipped'
        $result.FilesProcessed | Should -Be 1
        $result.Changed.Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:moduleDir 'main.json') | Should -BeFalse
    }

    It 'forwards public WhatIf and CheckDrift into the Bicep engine' {
        $dir = $script:moduleDir
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Invoke-AvmTransform -Path $D -Ecosystem bicep -WhatIf -SkipModuleVersionCheck
        }
        $result.Status | Should -Be 'skipped'
        Test-Path -LiteralPath (Join-Path $dir 'main.json') | Should -BeFalse

        $drift = InModuleScope 'Avm.Authoring' -Parameters @{ D = $dir } {
            param($D)
            Invoke-AvmTransform -Path $D -Ecosystem bicep -CheckDrift -SkipModuleVersionCheck
        }
        $drift.Status | Should -Be 'fail'
        $drift.Issues[0].Code | Should -Be 'avm.bicep.json-missing'
    }

    It 'does not write earlier files when a later child build fails' {
        $child = Join-Path $script:moduleDir 'child'
        New-Item -ItemType Directory -Path $child | Out-Null
        $childSource = Join-Path $child 'main.bicep'
        Set-Content -LiteralPath $childSource -Value 'param child string' -Encoding utf8
        $ctx = $script:context
        InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; Bad = $childSource } {
            param($C, $Bad)
            Mock Invoke-AvmProcess {
                if ($ArgumentList[2] -eq $Bad) {
                    return [pscustomobject]@{ ExitCode = 3; StdOut = ''; StdErr = 'Child compilation failed.' }
                }
                return [pscustomobject]@{ ExitCode = 0; StdOut = $script:armJson; StdErr = '' }
            }
            { Invoke-AvmBicepTransform -Context $C -Confirm:$false } |
                Should -Throw -ExpectedMessage '*Child compilation failed*'
        }
        Test-Path -LiteralPath (Join-Path $script:moduleDir 'main.json') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $child 'main.json') | Should -BeFalse
    }

    It 'accepts Bicep symbolic templates with languageVersion 2.0 resources objects' {
        $symbolic = '{"$schema":"https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#","contentVersion":"1.0.0.0","languageVersion":"2.0","resources":{}}'
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; Json = $symbolic } {
            param($C, $Json)
            Mock Invoke-AvmProcess {
                [pscustomobject]@{ ExitCode = 0; StdOut = $Json; StdErr = '' }
            }
            Invoke-AvmBicepTransform -Context $C -Confirm:$false
        }
        $result.Status | Should -Be 'pass'
        [System.IO.File]::ReadAllText((Join-Path $script:moduleDir 'main.json')) |
            Should -Be $symbolic
    }

    It 'rejects invalid compilation output: <Case>' -TestCases @(
        @{ Case = 'syntax'; Output = '{invalid'; ErrorText = 'invalid JSON' }
        @{ Case = 'empty'; Output = ''; ErrorText = 'no compiled JSON' }
        @{ Case = 'shape'; Output = '{}'; ErrorText = 'required ARM template fields' }
        @{ Case = 'resource map without v2'; Output = '{"$schema":"https://example.invalid","contentVersion":"1","resources":{}}'; ErrorText = 'required ARM template fields' }
    ) {
        param($Case, $Output, $ErrorText)
        $ctx = $script:context
        InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; Text = $Output; Expected = $ErrorText } {
            param($C, $Text, $Expected)
            Mock Invoke-AvmProcess {
                [pscustomobject]@{ ExitCode = 0; StdOut = $Text; StdErr = '' }
            }
            { Invoke-AvmBicepTransform -Context $C -Confirm:$false } |
                Should -Throw -ExpectedMessage "*$Expected*"
        }
        Test-Path -LiteralPath (Join-Path $script:moduleDir 'main.json') | Should -BeFalse
    }

    It 'does not silently create output from wrongly cased Bicep source or compiled file' {
        $ctx = $script:context
        $wrong = Join-Path $script:moduleDir 'Main.JSON'
        Set-Content -LiteralPath $wrong -Value '{}' -Encoding utf8
        InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            { Invoke-AvmBicepTransform -Context $C -Confirm:$false } |
                Should -Throw -ExpectedMessage '*exact casing*'
        }
        Test-Path -LiteralPath $wrong -PathType Leaf | Should -BeTrue
        Get-Content -LiteralPath $wrong -Raw | Should -Match '\{\}'
    }

    It 'rejects a wrongly cased source before calling the compiler' {
        Remove-Item -LiteralPath $script:source
        $wrong = Join-Path $script:moduleDir 'Main.Bicep'
        Set-Content -LiteralPath $wrong -Value 'param name string' -Encoding utf8
        $ctx = $script:context
        InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            { Invoke-AvmBicepTransform -Context $C -Confirm:$false } |
                Should -Throw -ExpectedMessage '*exact casing*'
            Should -Invoke Invoke-AvmProcess -Exactly 0
        }
        Test-Path -LiteralPath (Join-Path $script:moduleDir 'main.json') | Should -BeFalse
    }

    It 'rejects an orphan compiled artifact without source' {
        Remove-Item -LiteralPath $script:source
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'metadata.json') -Value '{}' -Encoding utf8
        $output = Join-Path $script:moduleDir 'main.json'
        Set-Content -LiteralPath $output -Value '{}' -Encoding utf8
        $ctx = $script:context
        InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            { Invoke-AvmBicepTransform -Context $C -CheckDrift } |
                Should -Throw -ExpectedMessage '*without main.bicep*'
        }
        Get-Content -LiteralPath $output -Raw | Should -Match '\{\}'
    }

    It 'replaces a BOM or newline-drifted artifact with exact compiler bytes' {
        $output = Join-Path $script:moduleDir 'main.json'
        [System.IO.File]::WriteAllText(
            $output, ($script:compiled -replace ',', ",`r`n"),
            [System.Text.UTF8Encoding]::new($true))
        $ctx = $script:context
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Invoke-AvmBicepTransform -Context $C -Confirm:$false
        }
        $result.Status | Should -Be 'pass'
        $result.Changed | Should -Be @($output)
        [System.IO.File]::ReadAllBytes($output) |
            Should -Be ([System.Text.UTF8Encoding]::new($false).GetBytes($script:compiled))
    }
}
