function Test-AvmBicepConventionChildPublish {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory)]
        [object[]] $Scopes
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $issues = [System.Collections.Generic.List[object]]::new()
    $versioned = [System.Collections.Generic.List[object]]::new()
    foreach ($scope in $Scopes) {
        if ($scope.IsTopLevel) {
            continue
        }
        $versions = @(Get-ChildItem -LiteralPath $scope.Path -Force |
                Where-Object { $_.Name -ieq 'version.json' })
        if ($versions.Count -eq 0) {
            continue
        }
        if ($versions.Count -ne 1 -or $versions[0].Name -cne 'version.json' -or
            $versions[0].PSIsContainer -or
            ($versions[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot `
                        -Path (Join-Path $scope.Path 'version.json') `
                        -Code 'avm.bicep.child-publish-version-file' `
                        -Message 'A published child needs a regular version.json with exact casing.'))
            continue
        }
        $versioned.Add($scope)
    }

    if ($versioned.Count -eq 0) {
        return $issues.ToArray()
    }

    $allowlistPath = Join-Path $RepositoryRoot `
        'utilities/pipelines/staticValidation/compliance/helper/child-module-publish-allowed-list.json'
    try {
        $allowlist = Get-AvmBicepChildPublishAllowlist -RepositoryRoot $RepositoryRoot
    }
    catch [AvmConfigurationException] {
        $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot `
                    -Path $allowlistPath -Code 'avm.bicep.child-publish-allowlist' `
                    -Message "$($_.Exception.Message) Versioned children cannot be approved without it."))
        return $issues.ToArray()
    }
    foreach ($scope in $versioned) {
        if (-not $allowlist.Allowed.Contains($scope.ModuleRelativePath)) {
            $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot `
                        -Path (Join-Path $scope.Path 'version.json') `
                        -Code 'avm.bicep.child-publish-not-allowed' `
                        -Message "Published child '$($scope.ModuleRelativePath)' is not in the repository's child publishing allowlist."))
        }
    }
    return $issues.ToArray()
}
