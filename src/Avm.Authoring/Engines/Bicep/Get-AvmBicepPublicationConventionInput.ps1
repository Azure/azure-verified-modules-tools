function Get-AvmBicepPublicationConventionInput {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory)]
        $Publication,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $VersionInputs
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $versions = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($item in $VersionInputs) { $versions[$item.Scope.ModuleRelativePath] = $item }
    $cases = @(foreach ($entry in @($Publication.Entries)) {
            if ($null -eq $entry.Target -or $null -eq $entry.Published) { continue }
            $fileInput = $null
            if ($versions.ContainsKey($entry.Scope.ModuleRelativePath)) { $fileInput = $versions[$entry.Scope.ModuleRelativePath] }
            @{
                Entry     = $entry
                FileInput = $fileInput
                IssuePath = Join-Path $entry.Scope.Path 'CHANGELOG.md'
                IssueRoot = $RepositoryRoot
            }
        })
    $ancestors = @(foreach ($entry in @($Publication.Entries)) {
            $child = $entry.Scope
            if ($child.IsTopLevel -or -not $Publication.Targets.ContainsKey($child.ModuleRelativePath)) { continue }
            $ancestor = $child.ModuleRelativePath
            while ($ancestor.LastIndexOf('/') -gt 0) {
                $ancestor = $ancestor.Substring(0, $ancestor.LastIndexOf('/'))
                if ($ancestor -ceq "avm/$($child.ModuleType)") { break }
                $versionPath = Join-Path -Path $RepositoryRoot -ChildPath $ancestor -AdditionalChildPath 'version.json'
                if (-not (Test-Path -LiteralPath $versionPath)) { continue }
                $parentTarget = $null
                if ($Publication.Targets.ContainsKey($ancestor)) { $parentTarget = $Publication.Targets[$ancestor] }
                @{
                    ChildName    = $child.ModuleRelativePath
                    ChildTarget  = $Publication.Targets[$child.ModuleRelativePath]
                    ParentName   = $ancestor
                    ParentTarget = $parentTarget
                    IssuePath    = $versionPath
                    IssueRoot    = $RepositoryRoot
                }
            }
        })
    return @{ Entries = $cases; Ancestors = $ancestors }
}
