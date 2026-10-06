#Requires -Version 7.4
param(
    [Parameter(Mandatory)]
    [System.Collections.IDictionary] $Convention
)

$Convention.NativeTestSourceExpected = 0
$cases = @($Convention.TestSourceInputs | ForEach-Object { @{ Case = $_; IssuePath = $_.IssuePath } })
if ($cases.Count -gt 0) {
    Describe 'Bicep test source <IssuePath>' -ForEach $cases {
        $Convention.NativeTestSourceExpected++
        It 'is readable as UTF-8' -Tag 'avm.bicep.test-source-read' {
            $Case.ReadError | Should -BeNullOrEmpty
        }
        if (-not $Case.ReadError) {
            $Convention.NativeTestSourceExpected += 2
            Context 'Literal metadata <MetadataName>' -ForEach @(@{ MetadataName = 'name' }, @{ MetadataName = 'description' }) {
                It 'has a nonempty literal value' -Tag "avm.bicep.test-metadata-$MetadataName" {
                    $pattern = "(?m)^[ \t]*metadata[ \t]+$MetadataName[ \t]*=[ \t]*'(?<value>(?:\\.|[^'\\\r\n])*)'[ \t]*\r?$"
                    $declaration = [regex]::Match($Case.Source, $pattern)
                    $declaration.Success | Should -BeTrue
                    $declaration.Groups['value'].Value.Trim() | Should -Not -BeNullOrEmpty
                }
            }
            $declarations = @(@{
                    Short      = [regex]::Match($Case.Source, "(?m)^[ \t]*param[ \t]+serviceShort[ \t]+string[ \t]*=[ \t]*'(?<value>[^'\r\n]*)'")
                    Deployment = [regex]::Match($Case.Source,
                        "(?m)^[ \t]*module[ \t]+testDeployment[ \t]+'(?<target>(?:\.\./)+[^'\r\n]*main\.bicep)'[ \t]*=[ \t]*(?:if[ \t]*\([^\r\n]*\)[ \t]*)?(?:\[|\{)[ \t]*\r?$")
                })
            Context 'Test declarations' -ForEach $declarations {
                if ($Case.HasResources) {
                    $Convention.NativeTestSourceExpected += 4
                    It 'declares a literal serviceShort string' -Tag 'avm.bicep.test-service-short' {
                        $Short.Success | Should -BeTrue
                    }
                    It 'declares the exact namePrefix placeholder' -Tag 'avm.bicep.test-name-prefix' {
                        $Case.Source | Should -MatchExactly "(?m)^[ \t]*param[ \t]+namePrefix[ \t]+string[ \t]*=[ \t]*'#_namePrefix_#'[ \t]*\r?$"
                    }
                    It 'directly declares a relative testDeployment module' -Tag 'avm.bicep.test-deployment' {
                        $Deployment.Success | Should -BeTrue
                    }
                    It 'includes -test- in the deployment name' -Tag 'avm.bicep.test-deployment-name' {
                        $Case.Source | Should -MatchExactly '(?m)^[ \t]*name:[^\r\n]*-test-[^\r\n]+\r?$'
                    }
                }
                if ($Short.Success) {
                    $suffix = switch -Regex -CaseSensitive ($Case.FolderName) {
                        '(?:^|\.)defaults$' { 'min'; break }
                        '(?:^|\.)max$' { 'max'; break }
                        '(?:^|\.)waf-aligned$' { 'waf'; break }
                        default { $null }
                    }
                    if ($suffix) {
                        $Convention.NativeTestSourceExpected++
                        It 'ends serviceShort with <Suffix> for this test folder' -ForEach @(@{ Suffix = $suffix }) `
                            -Tag 'avm.bicep.test-service-short-suffix' {
                            $Short.Groups['value'].Value.EndsWith($Suffix, [System.StringComparison]::Ordinal) | Should -BeTrue
                        }
                    }
                    $Convention.NativeTestSourceExpected++
                    It 'uses a repository-unique serviceShort' -Tag 'avm.bicep.test-service-short-duplicate' {
                        $shortValue = $Short.Groups['value'].Value
                        $others = @(if ($Convention.ServiceShortIndex.ContainsKey($shortValue)) {
                                $Convention.ServiceShortIndex[$shortValue] | Where-Object { $_ -cne $Case.IssuePath }
                            })
                        $relative = @($others | ForEach-Object { [System.IO.Path]::GetRelativePath($Case.Scope.RepositoryRoot, $_).Replace('\', '/') })
                        $others | Should -BeNullOrEmpty -Because "serviceShort '$shortValue' must not also be used by $($relative -join ', ')"
                    }
                }
                if ($Case.Scope.IsTopLevel -and $Case.Scope.ModuleType -ceq 'res' -and $Case.Scope.ScopeDirectories.Count -gt 0) {
                    $Convention.NativeTestSourceExpected++
                    It 'directly references its matching scope module' -Tag 'avm.bicep.test-scope-reference' {
                        $relative = [System.IO.Path]::GetRelativePath((Join-Path $Case.Scope.Path 'tests'), $Case.IssuePath).Replace('\', '/')
                        $testScope = [regex]::Match($relative, '(?:^|/)(?<scope>(?:rg|sub|mg)-scope)[^/]*/main\.test\.bicep$')
                        $testScope.Success | Should -BeTrue
                        $Deployment.Success | Should -BeTrue
                        $Deployment.Groups['target'].Value | Should -MatchExactly "(?:^|/)$($testScope.Groups['scope'].Value)/[^']*main\.bicep$"
                    }
                }
            }
        }
    }
}
