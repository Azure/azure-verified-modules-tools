#Requires -Version 7.4
param(
    [Parameter(Mandatory)]
    [System.Collections.IDictionary] $Convention
)

$cases = @(@{ Case = $Convention.CodeownerInput; IssuePath = $Convention.CodeownerInput.IssuePath; IssueRoot = $Convention.RepositoryRoot })
$Convention.NativeOwnershipExpected = 0

Describe 'Bicep repository ownership' -ForEach $cases {
    $Convention.NativeOwnershipExpected++
    It 'has a regular exact-case .github/CODEOWNERS file' -Tag 'avm.bicep.codeowners-file' {
        @($Case.Directories) | Should -HaveCount 1
        $Case.Directories[0].PSIsContainer | Should -BeTrue
        $Case.Directories[0].Name | Should -BeExactly '.github'
        ($Case.Directories[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint) | Should -Be 0
        @($Case.Files) | Should -HaveCount 1
        $Case.Files[0].PSIsContainer | Should -BeFalse
        $Case.Files[0].Name | Should -BeExactly 'CODEOWNERS'
        ($Case.Files[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint) | Should -Be 0
    }
    if ($Case.ReadAttempted) {
        $Convention.NativeOwnershipExpected++
        It 'is readable as strict UTF-8' -Tag 'avm.bicep.codeowners-read' {
            $Case.ReadError | Should -BeNullOrEmpty
        }
        if (-not $Case.ReadError) {
            $Convention.NativeOwnershipExpected += 5 + (2 * $Case.Rules.Count)
            $overrides = @(
                '*avm.core.team.tests.ps1 @Azure/azure-verified-modules-tooling-contributors'
                '*.e2eignore @Azure/azure-verified-modules-tooling-contributors'
                'metadata.json @Azure/azure-verified-modules-engineering-owners @Azure/azure-verified-modules-module-owners'
            )
            $overrideCases = @(for ($index = 0; $index -lt 3; $index++) {
                    @{ Position = $index + 1; Index = $Case.Rules.Count - 3 + $index; Text = $overrides[$index] }
                })
            It 'assigns the repository default to tooling contributors' -Tag 'avm.bicep.codeowners-default' {
                $Case.Rules.Count | Should -BeGreaterOrEqual 1
                $Case.Rules[0].Text | Should -BeExactly '* @Azure/azure-verified-modules-tooling-contributors'
            }
            It 'leaves the module tree ownerless in the second rule' -Tag 'avm.bicep.codeowners-module' {
                $Case.Rules.Count | Should -BeGreaterOrEqual 2
                $Case.Rules[1].Text | Should -BeExactly '/avm/'
            }
            It 'sets final override <Position> to <Text>' -ForEach $overrideCases -Tag 'avm.bicep.codeowners-override' {
                $Index | Should -BeGreaterOrEqual 0
                $Case.Rules[$Index].Text | Should -BeExactly $Text
            }
            if ($Case.Rules.Count -gt 0) {
                $ruleCases = @(for ($index = 0; $index -lt $Case.Rules.Count; $index++) {
                        @{ Rule = $Case.Rules[$index]; Index = $index; IssueLine = $Case.Rules[$index].Line }
                    })
                Context 'Line <IssueLine>: <Rule.Pattern>' -ForEach $ruleCases {
                    $ownershipCode = if ($Index -ne 1 -and $Rule.Pattern -imatch '^/?avm(?:/|$)') {
                        'avm.bicep.codeowners-per-module'
                    }
                    else { 'avm.bicep.codeowners-module-override' }
                    It 'preserves the ownerless module tree' -Tag $ownershipCode {
                        if ($Index -ne 1) { $Rule.Pattern | Should -Not -Match '^/?avm(?:/|$)' }
                        if ($Index -gt 1 -and $Index -lt $Case.Rules.Count - 3) {
                            $Rule.Pattern | Should -MatchExactly '^/(?<root>[A-Za-z0-9._-]+)(?:/|$)'
                            $rootName = [regex]::Match($Rule.Pattern, '^/(?<root>[A-Za-z0-9._-]+)(?:/|$)').Groups['root'].Value
                            $rootName | Should -Not -BeIn @('avm', '.', '..')
                        }
                    }
                    It 'does not repeat an earlier ownership pattern' -Tag 'avm.bicep.codeowners-duplicate' {
                        $earlier = @(for ($candidate = 0; $candidate -lt $Index; $candidate++) { $Case.Rules[$candidate].Pattern })
                        $Rule.Pattern | Should -Not -BeIn $earlier
                    }
                }
            }
        }
    }
}
