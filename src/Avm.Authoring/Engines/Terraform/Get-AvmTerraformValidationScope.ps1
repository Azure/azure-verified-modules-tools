function Get-AvmTerraformValidationScope {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Root
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $rootPath = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($Root))
    $targets = [string[]]@(Get-AvmRuleTargetRoot `
            -Rule ([pscustomobject]@{ AppliesTo = @('root', 'examples', 'modules') }) `
            -ContextRoot $rootPath)
    [System.Array]::Sort($targets, [System.StringComparer]::Ordinal)

    $examples = [System.Collections.Generic.List[object]]::new()
    $modules = [System.Collections.Generic.List[object]]::new()
    foreach ($target in $targets) {
        $files = [string[]]@(
            Get-ChildItem -LiteralPath $target -File -ErrorAction Stop |
                Where-Object {
                    ($_.Name -clike '*.tf' -or $_.Name -clike '*.tf.json') -and
                    -not (Test-AvmIgnoredPath -Root $rootPath -Path $_.FullName)
                } |
                ForEach-Object { $_.FullName }
        )
        if ($files.Count -eq 0) { continue }
        [System.Array]::Sort($files, [System.StringComparer]::Ordinal)

        $relativePath = [System.IO.Path]::GetRelativePath($rootPath, $target).Replace('\', '/')
        $scope = [pscustomobject][ordered]@{
            Path         = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($target))
            RelativePath = $relativePath
            Files        = $files
            TestFiles    = @()
        }
        if ($relativePath.StartsWith('examples/', [System.StringComparison]::Ordinal)) {
            $testFiles = [System.Collections.Generic.List[string]]::new()
            foreach ($testRoot in @($target, (Join-Path $target 'tests'))) {
                if (-not (Test-Path -LiteralPath $testRoot -PathType Container)) { continue }
                foreach ($testFile in (Get-ChildItem -LiteralPath $testRoot -File -Filter '*.tftest.*' -Recurse:($testRoot -cne $target) -ErrorAction Stop)) {
                    if (($testFile.Name -clike '*.tftest.hcl' -or $testFile.Name -clike '*.tftest.json') -and
                        -not (Test-AvmIgnoredPath -Root $rootPath -Path $testFile.FullName)) {
                        $testFiles.Add([System.IO.Path]::GetRelativePath($target, $testFile.FullName).Replace('\', '/'))
                    }
                }
            }
            $scope.TestFiles = $testFiles.ToArray()
            $examples.Add($scope)
        }
        else {
            $modules.Add($scope)
        }
    }

    return [pscustomobject][ordered]@{
        Examples = $examples.ToArray()
        Modules  = $modules.ToArray()
    }
}
