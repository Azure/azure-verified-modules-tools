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
        $script:baseDir = Join-Path $TestDrive ("gov-" + $unique)
        New-Item -ItemType Directory -Path $script:baseDir -Force | Out-Null

        function script:New-TestGroupConfig {
            param(
                [Parameter(Mandatory)] [string] $Group,
                [Parameter(Mandatory)] [AllowEmptyString()] [string] $Json
            )
            $dir = Join-Path $script:baseDir $Group
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir '_config.json') -Value $Json -NoNewline
        }
    }

    It 'reads the root group spec and normalises path separators' {
        New-TestGroupConfig -Group 'root' -Json (
            '{ "managedLines": { ".github\\x.txt": ' +
            '{ "required": ["abc", "def"], "removed": ["old"] } } }')

        $spec = InModuleScope 'Avm.Authoring' -Parameters @{ B = $script:baseDir } {
            param($B)
            Get-AvmManagedLineSpec -BaseDir $B -FileGroups @('root')
        }
        $spec.Contains('.github/x.txt') | Should -BeTrue
        $spec['.github/x.txt'].Required | Should -Be @('abc', 'def')
        $spec['.github/x.txt'].Removed | Should -Be @('old')
    }

    It 'lets a later file group requirement cancel an earlier removal' {
        New-TestGroupConfig -Group 'root' -Json '{ "managedLines": { ".gitignore": { "removed": ["abc"] } } }'
        New-TestGroupConfig -Group 'canary' -Json '{ "managedLines": { ".gitignore": { "required": ["abc"] } } }'

        $spec = InModuleScope 'Avm.Authoring' -Parameters @{ B = $script:baseDir } {
            param($B)
            Get-AvmManagedLineSpec -BaseDir $B -FileGroups @('root', 'canary')
        }
        $spec['.gitignore'].Required | Should -Be @('abc')
        $spec['.gitignore'].Removed | Should -BeNullOrEmpty
    }

    It 'lets a later file group removal cancel an earlier requirement' {
        New-TestGroupConfig -Group 'root' -Json '{ "managedLines": { ".gitignore": { "required": ["abc"] } } }'
        New-TestGroupConfig -Group 'canary' -Json '{ "managedLines": { ".gitignore": { "removed": ["abc"] } } }'

        $spec = InModuleScope 'Avm.Authoring' -Parameters @{ B = $script:baseDir } {
            param($B)
            Get-AvmManagedLineSpec -BaseDir $B -FileGroups @('root', 'canary')
        }
        $spec['.gitignore'].Removed | Should -Be @('abc')
        $spec['.gitignore'].Required | Should -BeNullOrEmpty
    }

    It 'stacks strictly in the requested file-group order' {
        New-TestGroupConfig -Group 'root' -Json '{ "managedLines": { ".gitignore": { "removed": ["abc"] } } }'
        New-TestGroupConfig -Group 'canary' -Json '{ "managedLines": { ".gitignore": { "required": ["abc"] } } }'

        $reversed = InModuleScope 'Avm.Authoring' -Parameters @{ B = $script:baseDir } {
            param($B)
            Get-AvmManagedLineSpec -BaseDir $B -FileGroups @('canary', 'root')
        }
        $reversed['.gitignore'].Removed | Should -Be @('abc')
        $reversed['.gitignore'].Required | Should -BeNullOrEmpty
    }

    It 'ignores file groups the repository does not use' {
        New-TestGroupConfig -Group 'root' -Json '{ "managedLines": { ".gitignore": { "required": ["abc"] } } }'
        New-TestGroupConfig -Group 'alz' -Json '{ "managedLines": { ".gitignore": { "required": ["alz-only"] } } }'

        $spec = InModuleScope 'Avm.Authoring' -Parameters @{ B = $script:baseDir } {
            param($B)
            Get-AvmManagedLineSpec -BaseDir $B -FileGroups @('root')
        }
        $spec['.gitignore'].Required | Should -Be @('abc')
    }

    It 'throws when one file group lists a line as both required and removed' {
        New-TestGroupConfig -Group 'root' -Json (
            '{ "managedLines": { ".gitignore": { "required": ["x"], "removed": ["x"] } } }')

        {
            InModuleScope 'Avm.Authoring' -Parameters @{ B = $script:baseDir } {
                param($B)
                Get-AvmManagedLineSpec -BaseDir $B -FileGroups @('root')
            }
        } | Should -Throw -ExceptionType ([System.InvalidOperationException])
    }

    It 'throws on invalid JSON' {
        New-TestGroupConfig -Group 'root' -Json '{ not json'

        {
            InModuleScope 'Avm.Authoring' -Parameters @{ B = $script:baseDir } {
                param($B)
                Get-AvmManagedLineSpec -BaseDir $B -FileGroups @('root')
            }
        } | Should -Throw -ExceptionType ([System.InvalidOperationException])
    }

    It 'returns empty when no file group declares managed lines' {
        New-TestGroupConfig -Group 'root' -Json '{ "deletedFiles": ["old.txt"] }'

        $spec = InModuleScope 'Avm.Authoring' -Parameters @{ B = $script:baseDir } {
            param($B)
            Get-AvmManagedLineSpec -BaseDir $B -FileGroups @('root', 'canary')
        }
        $spec.Keys.Count | Should -Be 0
    }

    It 'returns empty when a group declares no config file' {
        New-Item -ItemType Directory -Path (Join-Path $script:baseDir 'root') -Force | Out-Null

        $spec = InModuleScope 'Avm.Authoring' -Parameters @{ B = $script:baseDir } {
            param($B)
            Get-AvmManagedLineSpec -BaseDir $B -FileGroups @('root')
        }
        $spec.Keys.Count | Should -Be 0
    }

    It 'returns empty when the group folder does not exist' {
        $spec = InModuleScope 'Avm.Authoring' -Parameters @{ B = $script:baseDir } {
            param($B)
            Get-AvmManagedLineSpec -BaseDir $B -FileGroups @('does-not-exist')
        }
        $spec.Keys.Count | Should -Be 0
    }

    It 'returns empty when no base directory is supplied' {
        $spec = InModuleScope 'Avm.Authoring' {
            Get-AvmManagedLineSpec -BaseDir '' -FileGroups @('root')
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
