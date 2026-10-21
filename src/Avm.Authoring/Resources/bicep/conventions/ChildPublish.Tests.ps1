#Requires -Version 7.4
param(
    [Parameter(Mandatory)]
    [System.Collections.IDictionary] $Convention
)

$Convention.NativeChildPublishExpected = 0
$children = @(foreach ($scope in @($Convention.Scopes)) {
        if ($scope.IsTopLevel) { continue }
        $entries = @(Get-ChildItem -LiteralPath $scope.Path -Force -ErrorAction Stop |
                Where-Object { $_.Name -ieq 'version.json' })
        if ($entries.Count -eq 0) { continue }
        @{ Scope = $scope; Entries = $entries; IssuePath = Join-Path $scope.Path 'version.json' }
    })

Describe 'Bicep child version files' {
    if ($children.Count -gt 0) {
        $Convention.NativeChildPublishExpected += $children.Count
        It 'has a regular exact-case version.json for <Scope.ModuleRelativePath>' -ForEach $children `
            -Tag 'avm.bicep.child-publish-version-file' {
            @($Entries) | Should -HaveCount 1
            $Entries[0].Name | Should -BeExactly 'version.json'
            $Entries[0].PSIsContainer | Should -BeFalse
            ($Entries[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint) | Should -Be 0
        }
    }
}
