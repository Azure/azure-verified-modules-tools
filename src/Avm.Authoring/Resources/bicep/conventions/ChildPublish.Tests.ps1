#Requires -Version 7.4
param(
    [Parameter(Mandatory)]
    [System.Collections.IDictionary] $Convention
)

$Convention.NativeChildPublishExpected = 0
$childInput = $Convention.ChildPublishInput
$cases = @(@{ Case = $childInput; IssueRoot = $Convention.RepositoryRoot })

Describe 'Bicep child publishing' -ForEach $cases {
    if ($Case.Children.Count -gt 0) {
        $Convention.NativeChildPublishExpected += $Case.Children.Count + 1
        It 'has a regular exact-case version.json for <Scope.ModuleRelativePath>' -ForEach $Case.Children `
            -Tag 'avm.bicep.child-publish-version-file' {
            @($Entries) | Should -HaveCount 1
            $Entries[0].Name | Should -BeExactly 'version.json'
            $Entries[0].PSIsContainer | Should -BeFalse
            ($Entries[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint) | Should -Be 0
        }
        It 'has readable canonical repository approval configuration' -ForEach @(@{ IssuePath = $Case.IssuePath }) `
            -Tag 'avm.bicep.child-publish-allowlist' {
            $Case.ReadError | Should -BeNullOrEmpty -Because 'versioned children cannot be approved without it'
            $Case.Allowlist | Should -Not -BeNullOrEmpty
        }
        if ($null -ne $Case.Allowlist) {
            $Convention.NativeChildPublishExpected += $Case.Children.Count
            It 'explicitly approves <Scope.ModuleRelativePath> for publication' -ForEach $Case.Children `
                -Tag 'avm.bicep.child-publish-not-allowed' {
                $Case.Allowlist.Allowed.Contains($Scope.ModuleRelativePath) | Should -BeTrue `
                    -Because "published child '$($Scope.ModuleRelativePath)' needs explicit repository approval"
            }
        }
    }
}
