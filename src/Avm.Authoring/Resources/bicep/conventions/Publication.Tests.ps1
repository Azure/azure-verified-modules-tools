#Requires -Version 7.4
param(
    [Parameter(Mandatory)]
    [System.Collections.IDictionary] $Convention
)

$Convention.NativePublicationExpected = 0
$cases = @($Convention.PublicationConventionInput.Entries)
if ($cases.Count -gt 0) {
    Describe 'Bicep publication <Entry.Scope.ModuleRelativePath>' -ForEach $cases {
        $Convention.NativePublicationExpected++
        It 'has an inspectable regular changelog' -Tag 'avm.bicep.publication-changelog' {
            $FileInput | Should -Not -BeNullOrEmpty
            @($FileInput.ChangelogFiles) | Should -HaveCount 1
            $FileInput.ChangelogFiles[0].Name | Should -BeExactly 'CHANGELOG.md'
            $FileInput.ChangelogFiles[0].PSIsContainer | Should -BeFalse
            ($FileInput.ChangelogFiles[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint) | Should -Be 0
        }
        if ($null -ne $FileInput -and $FileInput.ChangelogFiles.Count -eq 1 -and
            $FileInput.ChangelogFiles[0].Name -ceq 'CHANGELOG.md' -and -not $FileInput.ChangelogFiles[0].PSIsContainer -and
            -not ($FileInput.ChangelogFiles[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            $Convention.NativePublicationExpected++
            It 'is readable for publication checks' -Tag 'avm.bicep.publication-changelog' {
                $FileInput.ChangelogError | Should -BeNullOrEmpty
            }
            if (-not $FileInput.ChangelogError) {
                $releases = @(foreach ($heading in $FileInput.Headings) {
                        $match = [regex]::Match($heading.Text, '^## (?<version>[0-9]+\.[0-9]+\.[0-9]+)\s*\z')
                        if ($match.Success) { @{ Release = $match.Groups['version'].Value; IssueLine = $heading.IssueLine } }
                    })
                if ($releases.Count -gt 0) {
                    $Convention.NativePublicationExpected += $releases.Count
                    It 'documents a published or next-target release <Release>' -ForEach $releases -Tag 'avm.bicep.changelog-unpublished-version' {
                        ($Release -ceq $Entry.Target.TargetVersion -or $Entry.Published.Tags.Contains($Release)) |
                            Should -BeTrue -Because "release '$Release' must be published in MCR or match next target '$($Entry.Target.TargetVersion)'"
                    }
                }
                if ($Entry.Target.ShouldPublish) {
                    $Convention.NativePublicationExpected++
                    It 'documents the next target for a publishable change' -ForEach @(@{ Releases = $releases }) `
                        -Tag 'avm.bicep.changelog-target-version' {
                        @($Releases | Where-Object { $_.Release -ceq $Entry.Target.TargetVersion }) |
                            Should -Not -BeNullOrEmpty -Because "a publishable change requires '## $($Entry.Target.TargetVersion)'"
                    }
                }
            }
        }
    }
}
$ancestors = @($Convention.PublicationConventionInput.Ancestors | Where-Object {
        $_.ChildTarget.VersionChanged -and $null -ne $_.ChildTarget.PreviousVersion -and
        $_.ChildTarget.TargetVersion -cne '0.1.0' -and $_.ChildTarget.TargetVersion.EndsWith('.0', [System.StringComparison]::Ordinal)
    })
if ($ancestors.Count -gt 0) {
    Describe 'Versioned ancestor <ParentName> of <ChildName>' -ForEach $ancestors {
        $Convention.NativePublicationExpected++
        It 'has inspectable target-version history' -Tag 'avm.bicep.parent-version-uninspectable' {
            $ParentTarget | Should -Not -BeNullOrEmpty
        }
        if ($null -ne $ParentTarget) {
            $Convention.NativePublicationExpected++
            It 'increments its major/minor and resets the patch for the changed child' -Tag 'avm.bicep.parent-version-not-increased' {
                $ParentTarget.VersionChanged | Should -BeTrue
                $ParentTarget.TargetVersion.EndsWith('.0', [System.StringComparison]::Ordinal) | Should -BeTrue
                if ($null -ne $ParentTarget.PreviousVersion) {
                    [version]::Parse($ParentTarget.TargetVersion) | Should -BeGreaterThan ([version]::Parse("$($ParentTarget.PreviousVersion).0"))
                }
            }
        }
    }
}
