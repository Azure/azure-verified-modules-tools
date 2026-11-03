#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Test-AvmReleaseFormatEquivalence' {
    It 'returns <Expected> without running terraform for <Case>' -TestCases @(
        @{ Case = 'identical content'; Path = 'main.tf'; Base = "a = 1`n"; Head = "a = 1`n"; Expected = $true }
        @{ Case = 'content that differs only in line endings'; Path = 'main.tf'; Base = "a = 1`r`n"; Head = "a = 1`n"; Expected = $true }
        @{ Case = 'a missing base version'; Path = 'main.tf'; Base = $null; Head = "a = 1`n"; Expected = $false }
        @{ Case = 'a missing head version'; Path = 'main.tf'; Base = "a = 1`n"; Head = $null; Expected = $false }
        @{ Case = 'an empty file on both sides'; Path = 'main.tf'; Base = ''; Head = ''; Expected = $true }
        @{ Case = 'a changed file terraform fmt does not format'; Path = 'main.tf.json'; Base = '{"a":1}'; Head = '{ "a": 1 }'; Expected = $false }
    ) {
        param($Case, $Path, $Base, $Head, $Expected)
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ Path = $Path; Base = $Base; Head = $Head } {
            param([string] $Path, [object] $Base, [object] $Head)
            Mock Resolve-AvmTool -MockWith { throw [System.InvalidOperationException]::new('terraform must not be resolved.') }
            Mock Invoke-AvmProcess -MockWith { throw [System.InvalidOperationException]::new('terraform must not run.') }
            Test-AvmReleaseFormatEquivalence -Path $Path -BaseContent $Base -HeadContent $Head
        }

        $result | Should -Be $Expected
    }

    Context 'with terraform fmt' {
        It 'returns <Expected> for <Case>' -TestCases @(
            @{ Case = 'a whitespace-only change'; Path = 'modules/child/main.tf'; Base = "locals {`n  a=1`n}`n"; Head = "locals {`n  a   =   1`n}`n"; Expected = $true }
            @{ Case = 'a tfvars whitespace-only change'; Path = 'terraform.tfvars'; Base = "a=1`n"; Head = "a = 1`n"; Expected = $true }
            @{ Case = 'a value change'; Path = 'main.tf'; Base = "locals {`n  a=1`n}`n"; Head = "locals {`n  a = 2`n}`n"; Expected = $false }
            @{ Case = 'a change terraform fmt cannot parse'; Path = 'main.tf'; Base = "a = 1`n"; Head = "syntax error`n"; Expected = $false }
        ) {
            param($Case, $Path, $Base, $Head, $Expected)
            $probe = InModuleScope 'Avm.Authoring' -Parameters @{ Path = $Path; Base = $Base; Head = $Head } {
                param([string] $Path, [string] $Base, [string] $Head)
                $script:releaseMetadataFolders = [System.Collections.Generic.List[string]]::new()
                Mock Resolve-AvmTool -MockWith { [pscustomobject]@{ Name = 'terraform'; Path = 'terraform' } }
                Mock Invoke-AvmProcess -MockWith {
                    $folder = $ArgumentList[-1]
                    $script:releaseMetadataFolders.Add($folder)
                    $file = @(Get-ChildItem -LiteralPath $folder -File)[0]
                    $text = [System.IO.File]::ReadAllText($file.FullName)
                    if ($text -match 'syntax error') {
                        return [pscustomobject]@{ ExitCode = 2; StdOut = ''; StdErr = 'Error: Invalid expression' }
                    }
                    [System.IO.File]::WriteAllText($file.FullName, ($text -replace '[ \t]*=[ \t]*', ' = '))
                    return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
                }
                $value = Test-AvmReleaseFormatEquivalence -Path $Path -BaseContent $Base -HeadContent $Head
                Should -Invoke Invoke-AvmProcess -ParameterFilter { $FilePath -eq 'terraform' -and $ArgumentList[0] -eq 'fmt' -and $ArgumentList -contains '-write=true' -and $IgnoreExitCode }
                [pscustomobject]@{ Value = $value; Folders = $script:releaseMetadataFolders.ToArray() }
            }

            $probe.Value | Should -Be $Expected
            $probe.Folders.Count | Should -BeGreaterThan 0
            foreach ($folder in $probe.Folders) {
                Split-Path -Leaf $folder | Should -BeIn @('base', 'head')
                Test-Path -LiteralPath (Split-Path -Parent $folder) | Should -BeFalse -Because 'the temporary folder is removed'
            }
        }
    }
}

Describe 'Format-AvmReleaseMetadataSummary' {
    It 'lists each failure with its fix' {
        $summary = InModuleScope 'Avm.Authoring' {
            $result = Test-AvmReleaseMetadata -Author 'alice' -Title 'fix: a | b' -Body 'No template.' -Labels @('patch', 'minor') -SkipModuleVersionCheck
            Format-AvmReleaseMetadataSummary -Result $result -PullRequest 42
        }

        $summary | Should -BeLike "## Release metadata for #42: failed`n*"
        $summary | Should -Match '(?m)^\| Pull request kind \| Human \|$'
        $summary | Should -Match '(?m)^\| Version label \| `patch`, `minor` \|$'
        $summary | Should -Match '(?m)^### How to fix$'
        $summary | Should -Match '(?m)^- \*\*conflicting-labels\*\*: .+exactly one.*$'
        $summary | Should -Match '(?m)^- \*\*breaking-checkbox-missing\*\*: '
        $summary | Should -Match 'You do not need to push a new commit\.\n$'
    }

    It 'omits the fix section and shows notes when the check passes' {
        $summary = InModuleScope 'Avm.Authoring' {
            $result = Test-AvmReleaseMetadata -Author 'azure-verified-modules[bot]' -Title 'chore: run avm pre-commit' -ChangedFiles @(@{ Path = 'main.tf'; Status = 'modified'; FormatEquivalent = $true }) -SkipModuleVersionCheck
            Format-AvmReleaseMetadataSummary -Result $result
        }

        $summary | Should -BeLike "## Release metadata: passed`n*"
        $summary | Should -Not -Match '### How to fix'
        $summary | Should -Match '(?m)^\| Module code changed \| Formatting only \|$'
        $summary | Should -Match '(?m)^\| Triggers a release \| No \|$'
        $summary | Should -Match '(?m)^### Notes$'
        $summary | Should -Match '(?m)^- This is a repo-sync pull request\.'
    }

    It 'shows warnings for ignored labels' {
        $summary = InModuleScope 'Avm.Authoring' {
            $result = Test-AvmReleaseMetadata -Author 'dependabot[bot]' -Title 'chore(deps): bump' -Labels @(@{ Name = 'patch'; AddedBy = 'github-actions[bot]' }) -ChangedFiles @(@{ Path = 'examples/default/main.tf'; Status = 'modified'; FormatEquivalent = $false }) -SkipModuleVersionCheck
            Format-AvmReleaseMetadataSummary -Result $result -PullRequest 3
        }

        $summary | Should -BeLike '## Release metadata for #3: passed*'
        $summary | Should -Match '(?m)^### Warnings$'
        $summary | Should -Match "(?m)^- Ignored the 'patch' label"
    }
}
