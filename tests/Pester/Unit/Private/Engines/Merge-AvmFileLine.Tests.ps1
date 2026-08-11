#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Merge-AvmFileLine' {
    It 'appends missing required lines at the end in declaration order' {
        $result = InModuleScope 'Avm.Authoring' {
            Merge-AvmFileLine -ExistingLine @('*.tfstate', 'keep') -Required @('*.tfstate', 'first', 'second')
        }
        $result.Lines | Should -Be @('*.tfstate', 'keep', 'first', 'second')
        $result.Added | Should -Be @('first', 'second')
        $result.Removed | Should -BeNullOrEmpty
        $result.Changed | Should -BeTrue
    }

    It 'leaves already-present required lines untouched and reports no change' {
        $result = InModuleScope 'Avm.Authoring' {
            Merge-AvmFileLine -ExistingLine @('a', 'b', 'c') -Required @('b', 'a')
        }
        $result.Lines | Should -Be @('a', 'b', 'c')
        $result.Changed | Should -BeFalse
    }

    It 'removes every occurrence of a removed line' {
        $result = InModuleScope 'Avm.Authoring' {
            Merge-AvmFileLine -ExistingLine @('drop', 'keep', 'drop') -Removed @('drop')
        }
        $result.Lines | Should -Be @('keep')
        $result.Removed | Should -Be @('drop', 'drop')
        $result.Changed | Should -BeTrue
    }

    It 'never removes blank lines' {
        $result = InModuleScope 'Avm.Authoring' {
            Merge-AvmFileLine -ExistingLine @('a', '', 'b', '') -Removed @('')
        }
        $result.Lines | Should -Be @('a', '', 'b', '')
        $result.Changed | Should -BeFalse
    }

    It 'is idempotent over its own output' {
        $result = InModuleScope 'Avm.Authoring' {
            $first = Merge-AvmFileLine -ExistingLine @('old') -Required @('new') -Removed @('old')
            Merge-AvmFileLine -ExistingLine $first.Lines -Required @('new') -Removed @('old')
        }
        $result.Lines | Should -Be @('new')
        $result.Changed | Should -BeFalse
    }

    It 'matches on the trimmed line so surrounding whitespace does not duplicate' {
        $result = InModuleScope 'Avm.Authoring' {
            Merge-AvmFileLine -ExistingLine @('  value  ') -Required @('value')
        }
        $result.Changed | Should -BeFalse
    }

    It 'treats lines as case-sensitive' {
        $result = InModuleScope 'Avm.Authoring' {
            Merge-AvmFileLine -ExistingLine @('Value') -Required @('value')
        }
        $result.Lines | Should -Be @('Value', 'value')
        $result.Changed | Should -BeTrue
    }

    It 'throws when a line is both required and removed' {
        {
            InModuleScope 'Avm.Authoring' {
                Merge-AvmFileLine -Required @('x') -Removed @('x')
            }
        } | Should -Throw -ExceptionType ([System.ArgumentException])
    }
}

Describe 'Get-AvmManagedLineSpec' {
    BeforeEach {
        $unique = [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $script:base = Join-Path $TestDrive ("gov-" + $unique)
        $script:rootDir = Join-Path $script:base 'root'
        $script:laterGroupDir = Join-Path $script:base 'canary'
        New-Item -ItemType Directory -Path $script:rootDir -Force | Out-Null
        New-Item -ItemType Directory -Path $script:laterGroupDir -Force | Out-Null
    }

    It 'reads the root spec and normalises paths' {
        $json = '{ ".gitignore": { "required": ["abc", "def"], "removed": ["old"] } }'
        Set-Content -LiteralPath (Join-Path $script:rootDir '.avm-managed-lines.json') -Value $json -NoNewline

        $spec = InModuleScope 'Avm.Authoring' -Parameters @{ B = $script:base } {
            param($B)
            Get-AvmManagedLineSpec -BaseDir $B -FileGroups @('root')
        }
        $spec.Contains('.gitignore') | Should -BeTrue
        $spec['.gitignore'].Required | Should -Be @('abc', 'def')
        $spec['.gitignore'].Removed | Should -Be @('old')
    }

    It 'lets a later file group requirement cancel an earlier removal' {
        Set-Content -LiteralPath (Join-Path $script:rootDir '.avm-managed-lines.json') `
            -Value '{ ".gitignore": { "removed": ["abc"] } }' -NoNewline
        Set-Content -LiteralPath (Join-Path $script:laterGroupDir '.avm-managed-lines.json') `
            -Value '{ ".gitignore": { "required": ["abc"] } }' -NoNewline

        $spec = InModuleScope 'Avm.Authoring' -Parameters @{ B = $script:base } {
            param($B)
            Get-AvmManagedLineSpec -BaseDir $B -FileGroups @('root', 'canary')
        }
        $spec['.gitignore'].Required | Should -Be @('abc')
        $spec['.gitignore'].Removed | Should -BeNullOrEmpty
    }

    It 'lets a later file group removal cancel an earlier requirement' {
        Set-Content -LiteralPath (Join-Path $script:rootDir '.avm-managed-lines.json') `
            -Value '{ ".gitignore": { "required": ["abc"] } }' -NoNewline
        Set-Content -LiteralPath (Join-Path $script:laterGroupDir '.avm-managed-lines.json') `
            -Value '{ ".gitignore": { "removed": ["abc"] } }' -NoNewline

        $spec = InModuleScope 'Avm.Authoring' -Parameters @{ B = $script:base } {
            param($B)
            Get-AvmManagedLineSpec -BaseDir $B -FileGroups @('root', 'canary')
        }
        $spec['.gitignore'].Removed | Should -Be @('abc')
        $spec['.gitignore'].Required | Should -BeNullOrEmpty
    }

    It 'throws when one spec file lists a line as both required and removed' {
        Set-Content -LiteralPath (Join-Path $script:rootDir '.avm-managed-lines.json') `
            -Value '{ ".gitignore": { "required": ["x"], "removed": ["x"] } }' -NoNewline

        {
            InModuleScope 'Avm.Authoring' -Parameters @{ B = $script:base } {
                param($B)
                Get-AvmManagedLineSpec -BaseDir $B -FileGroups @('root')
            }
        } | Should -Throw -ExceptionType ([System.InvalidOperationException])
    }

    It 'throws on invalid JSON' {
        Set-Content -LiteralPath (Join-Path $script:rootDir '.avm-managed-lines.json') -Value '{ not json' -NoNewline

        {
            InModuleScope 'Avm.Authoring' -Parameters @{ B = $script:base } {
                param($B)
                Get-AvmManagedLineSpec -BaseDir $B -FileGroups @('root')
            }
        } | Should -Throw -ExceptionType ([System.InvalidOperationException])
    }

    It 'returns empty when no spec files exist' {
        $spec = InModuleScope 'Avm.Authoring' -Parameters @{ B = $script:base } {
            param($B)
            Get-AvmManagedLineSpec -BaseDir $B -FileGroups @('root', 'canary')
        }
        $spec.Keys.Count | Should -Be 0
    }
}

Describe 'Get-AvmManagedLinePlan' {
    BeforeEach {
        $unique = [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $script:workRoot = Join-Path $TestDrive ("repo-" + $unique)
        New-Item -ItemType Directory -Path $script:workRoot -Force | Out-Null
    }

    It 'creates a plan for a missing file with LF endings' {
        $plans = InModuleScope 'Avm.Authoring' -Parameters @{ R = $script:workRoot } {
            param($R)
            $spec = [ordered]@{ '.gitignore' = [pscustomobject]@{ Required = @('abc', 'def'); Removed = @() } }
            Get-AvmManagedLinePlan -Root $R -Spec $spec
        }
        $plans | Should -HaveCount 1
        $plans[0].Existed | Should -BeFalse
        $plans[0].Changed | Should -BeTrue
        $plans[0].NewText | Should -Be "abc`ndef`n"
    }

    It 'preserves CRLF line endings in an existing file' {
        $target = Join-Path $script:workRoot '.gitignore'
        [System.IO.File]::WriteAllText($target, "keep`r`n", [System.Text.UTF8Encoding]::new($false))

        $plans = InModuleScope 'Avm.Authoring' -Parameters @{ R = $script:workRoot } {
            param($R)
            $spec = [ordered]@{ '.gitignore' = [pscustomobject]@{ Required = @('added'); Removed = @() } }
            Get-AvmManagedLinePlan -Root $R -Spec $spec
        }
        $plans[0].Existed | Should -BeTrue
        $plans[0].Changed | Should -BeTrue
        $plans[0].NewText | Should -Be "keep`r`nadded`r`n"
    }

    It 'reports no change when the file already satisfies the spec' {
        $target = Join-Path $script:workRoot '.gitignore'
        [System.IO.File]::WriteAllText($target, "abc`ndef`n", [System.Text.UTF8Encoding]::new($false))

        $plans = InModuleScope 'Avm.Authoring' -Parameters @{ R = $script:workRoot } {
            param($R)
            $spec = [ordered]@{ '.gitignore' = [pscustomobject]@{ Required = @('abc', 'def'); Removed = @() } }
            Get-AvmManagedLinePlan -Root $R -Spec $spec
        }
        $plans[0].Changed | Should -BeFalse
    }
}
