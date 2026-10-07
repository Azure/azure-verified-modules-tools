#Requires -Version 7.4
param(
    [Parameter(Mandatory)]
    [System.Collections.IDictionary] $Convention
)

$Convention.NativeVersionExpected = 0
$cases = @($Convention.VersionInputs | ForEach-Object { @{ Case = $_; IssuePath = $_.IssuePath } })

if ($cases.Count -gt 0) {
    Describe 'Bicep version and changelog: <Case.Scope.ModuleRelativePath>' -ForEach $cases {
        $Convention.NativeVersionExpected += 2
        It 'reads version.json as valid UTF-8 JSON' -Tag 'avm.bicep.version-invalid' {
            $Case.VersionError | Should -BeNullOrEmpty
        }
        if (-not $Case.VersionError) {
            $Convention.NativeVersionExpected++
            It 'declares a major.minor version string' -Tag 'avm.bicep.version-format' {
                $Case.Json.ValueKind | Should -Be ([System.Text.Json.JsonValueKind]::Object)
                $value = [System.Text.Json.JsonElement]::new()
                $Case.Json.TryGetProperty('version', [ref]$value) | Should -BeTrue
                $value.ValueKind | Should -Be ([System.Text.Json.JsonValueKind]::String)
                $value.GetString() | Should -MatchExactly '^[0-9]+\.[0-9]+$'
            }
            $versionValue = [System.Text.Json.JsonElement]::new()
            if ($Case.Json.ValueKind -eq [System.Text.Json.JsonValueKind]::Object -and
                $Case.Json.TryGetProperty('version', [ref]$versionValue) -and
                $versionValue.ValueKind -eq [System.Text.Json.JsonValueKind]::String -and
                $versionValue.GetString() -cmatch '^[0-9]+\.[0-9]+$' -and
                $Case.Scope.ModuleRelativePath -cnotin $Convention.MajorVersionAllowedModules) {
                $Convention.NativeVersionExpected++
                It 'keeps the major version at zero unless explicitly exempted' -Tag 'avm.bicep.version-major' {
                    $Case.Json.GetProperty('version').GetString().Split('.')[0].TrimStart('0') |
                        Should -BeNullOrEmpty
                }
            }
        }
        Context 'Changelog' -ForEach @(@{ IssuePath = $Case.ChangelogPath }) {
            It 'has a regular exact-case CHANGELOG.md' -Tag 'avm.bicep.changelog-missing' {
                @($Case.ChangelogFiles) | Should -HaveCount 1
                $Case.ChangelogFiles[0].Name | Should -BeExactly 'CHANGELOG.md'
                $Case.ChangelogFiles[0].PSIsContainer | Should -BeFalse
                ($Case.ChangelogFiles[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint) | Should -Be 0
            }
            if ($Case.ChangelogFiles.Count -eq 1 -and $Case.ChangelogFiles[0].Name -ceq 'CHANGELOG.md' -and
                -not $Case.ChangelogFiles[0].PSIsContainer -and
                -not ($Case.ChangelogFiles[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                $Convention.NativeVersionExpected++
                It 'is readable as UTF-8' -Tag 'avm.bicep.changelog-read' {
                    $Case.ChangelogError | Should -BeNullOrEmpty
                }
                if (-not $Case.ChangelogError) {
                    $Convention.NativeVersionExpected += 3
                    It 'is not empty' -Tag 'avm.bicep.changelog-empty' {
                        @($Case.Lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) |
                            Should -Not -BeNullOrEmpty
                    }
                    It 'uses the canonical heading and module link' -Tag 'avm.bicep.changelog-header' {
                        $Case.Lines.Count | Should -BeGreaterOrEqual 5
                        $Case.Lines[0] | Should -BeExactly '# Changelog'
                        $Case.Lines[1] | Should -BeExactly ''
                        $Case.Lines[2] | Should -BeExactly (
                            'The latest version of the changelog can be found [here](https://github.com/Azure/bicep-registry-modules/blob/main/{0}/CHANGELOG.md).' -f $Case.Scope.ModuleRelativePath)
                        $Case.Lines[3] | Should -BeExactly ''
                    }
                    It 'contains at least one semantic version section' -Tag 'avm.bicep.changelog-versions-missing' {
                        @($Case.Versions) | Should -Not -BeNullOrEmpty
                    }
                    if ($Case.Headings.Count -gt 0) {
                        $Convention.NativeVersionExpected += $Case.Headings.Count
                        It 'uses a semantic release heading at line <IssueLine>' -ForEach $Case.Headings -Tag 'avm.bicep.changelog-version' {
                            $Text | Should -MatchExactly '^## ([0-9]+\.[0-9]+\.[0-9]+)\s*$'
                            $Version | Should -Not -BeNullOrEmpty
                        }
                    }
                    if ($Case.Versions.Count -gt 0) {
                        Context 'Release <Version>' -ForEach $Case.Versions {
                            if ($null -ne $Previous) {
                                $Convention.NativeVersionExpected++
                                It 'is strictly older than the preceding release' -Tag 'avm.bicep.changelog-order' {
                                    $Version | Should -BeLessThan $Previous
                                }
                            }
                            $Convention.NativeVersionExpected += $Sections.Count
                            It 'contains exactly one <Name> section' -ForEach $Sections -Tag 'avm.bicep.changelog-section' {
                                @($Positions) | Should -HaveCount 1
                            }
                            $contentCases = @($Sections | Where-Object { $_.Positions.Count -eq 1 } |
                                    ForEach-Object { @{ Name = $_.Name; Content = $_.Content; IssueLine = $_.Positions[0] + 1 } })
                            if ($contentCases.Count -gt 0) {
                                $Convention.NativeVersionExpected += $contentCases.Count
                                It 'has content in the <Name> section' -ForEach $contentCases -Tag 'avm.bicep.changelog-section-empty' {
                                    @($Content | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) |
                                        Should -Not -BeNullOrEmpty
                                }
                            }
                            if ($Sections[0].Positions.Count -eq 1 -and $Sections[1].Positions.Count -eq 1) {
                                $Convention.NativeVersionExpected++
                                It 'lists Changes before Breaking Changes' -Tag 'avm.bicep.changelog-section-order' {
                                    $Sections[0].Positions[0] | Should -BeLessThan $Sections[1].Positions[0]
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
