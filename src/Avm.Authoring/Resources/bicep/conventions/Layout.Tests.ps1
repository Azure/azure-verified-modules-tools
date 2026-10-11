#Requires -Version 7.4
param(
    [Parameter(Mandatory)]
    [System.Collections.IDictionary] $Convention
)

$Convention.NativeLayoutExpected = 0
$cases = @($Convention.LayoutInputs | Where-Object {
        $_.Scope.IsTopLevel -or $_.Source.Count -gt 0 -or $_.Metadata.Count -ne 1 -or $_.Compiled.Count -gt 0
    } | ForEach-Object { @{ Case = $_; IssuePath = $_.IssuePath } })
if ($cases.Count -gt 0) {
    Describe 'Bicep module layout <Case.Scope.ModuleRelativePath>' -ForEach $cases {
        $Convention.NativeLayoutExpected++
        It 'has a regular exact-case main.bicep' -Tag 'avm.bicep.required-source' {
            @($Case.Source) | Should -HaveCount 1
            $Case.Source[0].PSIsContainer | Should -BeFalse
            $Case.Source[0].Name | Should -BeExactly 'main.bicep'
        }
        if ($Case.Source.Count -eq 1 -and -not $Case.Source[0].PSIsContainer -and $Case.Source[0].Name -ceq 'main.bicep') {
            $required = @(
                @{ Name = 'main.json'; Files = $Case.Compiled; IssuePath = Join-Path $Case.Scope.Path 'main.json' }
                @{ Name = 'README.md'; Files = $Case.Readme; IssuePath = Join-Path $Case.Scope.Path 'README.md' }
            )
            $Convention.NativeLayoutExpected += 2
            It 'has a regular exact-case <Name>' -ForEach $required -Tag 'avm.bicep.required-file' {
                @($Files) | Should -HaveCount 1
                $Files[0].PSIsContainer | Should -BeFalse
                $Files[0].Name | Should -BeExactly $Name
                if ($Name -ceq 'main.json') { ($Files[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint) | Should -Be 0 }
            }
            if ($Case.Scope.ModuleType -ceq 'res') {
                $Convention.NativeLayoutExpected++
                It 'uses lowercase letters, digits and hyphens in the resource folder' -Tag 'avm.bicep.resource-folder-name' {
                    (Split-Path $Case.Scope.Path -Leaf) | Should -MatchExactly '^[a-z0-9]+(?:-+[a-z0-9]+)*$'
                }
            }
            if ($Case.Version.Count -gt 0) {
                $Convention.NativeLayoutExpected++
                It 'has a regular exact-case version.json' -ForEach @(@{ IssuePath = Join-Path $Case.Scope.Path 'version.json' }) `
                    -Tag 'avm.bicep.version-file' {
                    @($Case.Version) | Should -HaveCount 1
                    $Case.Version[0].PSIsContainer | Should -BeFalse
                    $Case.Version[0].Name | Should -BeExactly 'version.json'
                }
            }
            if ($Case.Scope.IsTopLevel) {
                $Convention.NativeLayoutExpected++
                if ($Case.Scope.ScopeDirectories.Count -gt 0) {
                    It 'leaves versioning to the scope modules' -ForEach @(@{ IssuePath = Join-Path $Case.Scope.Path 'version.json' }) `
                        -Tag 'avm.bicep.multiscope-version' {
                        @($Case.Version) | Should -HaveCount 0
                    }
                }
                else {
                    It 'versions the single-scope root' -ForEach @(@{ IssuePath = Join-Path $Case.Scope.Path 'version.json' }) `
                        -Tag 'avm.bicep.version-missing' {
                        @($Case.Version) | Should -Not -BeNullOrEmpty
                    }
                }
                $Convention.NativeLayoutExpected++
                It 'has a regular exact-case tests directory' -ForEach @(@{ IssuePath = $Case.TestsPath }) -Tag 'avm.bicep.tests-missing' {
                    @($Case.Tests) | Should -HaveCount 1
                    $Case.Tests[0].PSIsContainer | Should -BeTrue
                    $Case.Tests[0].Name | Should -BeExactly 'tests'
                    ($Case.Tests[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint) | Should -Be 0
                }
                if ($Case.Tests.Count -eq 1 -and $Case.Tests[0].PSIsContainer -and $Case.Tests[0].Name -ceq 'tests' -and
                    -not ($Case.Tests[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                    $Convention.NativeLayoutExpected++
                    It 'has a regular exact-case e2e directory' -ForEach @(@{ IssuePath = $Case.E2ePath }) -Tag 'avm.bicep.e2e-missing' {
                        @($Case.E2e) | Should -HaveCount 1
                        $Case.E2e[0].PSIsContainer | Should -BeTrue
                        $Case.E2e[0].Name | Should -BeExactly 'e2e'
                        ($Case.E2e[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint) | Should -Be 0
                    }
                    if ($Case.E2e.Count -eq 1 -and $Case.E2e[0].PSIsContainer -and $Case.E2e[0].Name -ceq 'e2e' -and
                        -not ($Case.E2e[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                        if ($Case.Scope.ModuleType -ceq 'res') {
                            if ($Case.Scope.ScopeDirectories.Count -eq 0) {
                                $Convention.NativeLayoutExpected++
                                It 'has a waf-aligned test folder' -ForEach @(@{ IssuePath = $Case.E2ePath }) -Tag 'avm.bicep.waf-test-missing' {
                                    @($Case.Folders | Where-Object { $_.Folder.Name -clike '*waf-aligned' }) | Should -Not -BeNullOrEmpty
                                }
                            }
                            else {
                                $scopeCases = @(foreach ($scopeName in $Case.Scope.ScopeDirectories) {
                                        foreach ($kind in @('waf-aligned', 'defaults')) {
                                            if ($kind -ceq 'defaults' -and
                                                $Case.Scope.ModuleRelativePath -cin $Convention.LayoutExemptions['defaultsTestOptionalModules']) { continue }
                                            @{ ScopeName = $scopeName; Kind = $kind; IssuePath = $Case.E2ePath }
                                        }
                                    })
                                $Convention.NativeLayoutExpected += $scopeCases.Count
                                It 'has a <Kind> test for <ScopeName>' -ForEach $scopeCases -Tag 'avm.bicep.scope-test-missing' {
                                    @($Case.Folders | Where-Object { $_.Folder.Name -clike "$ScopeName*.$Kind" }) | Should -Not -BeNullOrEmpty
                                }
                            }
                        }
                        if ($Case.Folders.Count -gt 0) {
                            Context 'Test folder <Folder.Name>' -ForEach $Case.Folders {
                                $Convention.NativeLayoutExpected++
                                It 'is not linked' -Tag 'avm.bicep.test-directory' {
                                    ($Folder.Attributes -band [System.IO.FileAttributes]::ReparsePoint) | Should -Be 0
                                }
                                if (-not ($Folder.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                                    $Convention.NativeLayoutExpected++
                                    It 'has a regular exact-case main.test.bicep' -ForEach @(@{ IssuePath = Join-Path $Folder.FullName 'main.test.bicep' }) `
                                        -Tag 'avm.bicep.test-file-missing' {
                                        @($Main) | Should -HaveCount 1
                                        $Main[0].PSIsContainer | Should -BeFalse
                                        $Main[0].Name | Should -BeExactly 'main.test.bicep'
                                    }
                                    if ($Ignore.Count -gt 0) {
                                        Context 'Deployment exclusion' -ForEach @(@{ IssuePath = Join-Path $Folder.FullName '.e2eignore' }) {
                                            $Convention.NativeLayoutExpected++
                                            It 'uses a regular exact-case .e2eignore' -Tag 'avm.bicep.e2eignore-file' {
                                                @($Ignore) | Should -HaveCount 1
                                                $Ignore[0].PSIsContainer | Should -BeFalse
                                                $Ignore[0].Name | Should -BeExactly '.e2eignore'
                                                ($Ignore[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint) | Should -Be 0
                                            }
                                            if ($Ignore.Count -eq 1 -and -not $Ignore[0].PSIsContainer -and $Ignore[0].Name -ceq '.e2eignore' -and
                                                -not ($Ignore[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                                                if ($Case.Scope.ModuleType -ceq 'res' -and $Folder.Name -cmatch '(defaults|waf-aligned)$' -and
                                                    $Case.Scope.ModuleRelativePath -cnotin $Convention.LayoutExemptions['e2eIgnoreAllowedModules']) {
                                                    $Convention.NativeLayoutExpected++
                                                    It 'does not exclude a required resource test' -Tag 'avm.bicep.e2eignore-required-test' {
                                                        @($Ignore) | Should -HaveCount 0 -Because 'defaults and waf-aligned resource tests must deploy'
                                                    }
                                                }
                                                $Convention.NativeLayoutExpected++
                                                It 'is readable as UTF-8' -Tag 'avm.bicep.e2eignore-read' {
                                                    $IgnoreError | Should -BeNullOrEmpty
                                                }
                                                if (-not $IgnoreError) {
                                                    $Convention.NativeLayoutExpected++
                                                    It 'explains why deployment is skipped' -Tag 'avm.bicep.e2eignore-reason' {
                                                        [string]::IsNullOrWhiteSpace($IgnoreText) | Should -BeFalse
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
