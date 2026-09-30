function Test-AvmBicepConventionTestFile {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        $Scope,

        [Parameter(Mandatory)]
        [hashtable] $ServiceShortIndex
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $issues = [System.Collections.Generic.List[object]]::new()
    $testsPath = Join-Path $Scope.Path 'tests'
    if (-not (Test-Path -LiteralPath $testsPath -PathType Container)) {
        return $issues.ToArray()
    }

    $testFiles = @(Get-ChildItem -LiteralPath $testsPath -File -Recurse -Filter 'main.test.bicep' |
            Sort-Object FullName -CaseSensitive)
    foreach ($testFile in $testFiles) {
        $source = Get-AvmBicepCommentFreeSource -Source ([System.IO.File]::ReadAllText($testFile.FullName))
        foreach ($metadataName in @('name', 'description')) {
            $pattern = "(?m)^[ \t]*metadata[ \t]+$metadataName[ \t]*=[ \t]*'(?<value>(?:\\.|[^'\\\r\n])*)'[ \t]*\r?$"
            $declaration = [regex]::Match($source, $pattern)
            if (-not $declaration.Success -or
                [string]::IsNullOrWhiteSpace($declaration.Groups['value'].Value)) {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $testFile.FullName `
                            -Code "avm.bicep.test-metadata-$metadataName" `
                            -Message "Test source requires a nonempty literal metadata $metadataName declaration."))
            }
        }

        $short = [regex]::Match($source, "(?m)^[ \t]*param[ \t]+serviceShort[ \t]+string[ \t]*=[ \t]*'(?<value>[^'\r\n]*)'")
        $namePrefix = [regex]::IsMatch(
            $source, "(?m)^[ \t]*param[ \t]+namePrefix[ \t]+string[ \t]*=[ \t]*'#_namePrefix_#'[ \t]*\r?$")
        $deployment = [regex]::Match(
            $source,
            "(?m)^[ \t]*module[ \t]+testDeployment[ \t]+'(?<target>(?:\.\./)+[^'\r\n]*main\.bicep)'[ \t]*=[ \t]*(?:if[ \t]*\([^\r\n]*\)[ \t]*)?(?:\[|\{)[ \t]*\r?$")
        $hasResources = [regex]::IsMatch($source, '(?m)^[ \t]*(?:module|resource)[ \t]+\w')

        if ($hasResources) {
            if (-not $short.Success) {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $testFile.FullName `
                            -Code 'avm.bicep.test-service-short' `
                            -Message 'Deploying test source requires a literal serviceShort string parameter.'))
            }
            if (-not $namePrefix) {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $testFile.FullName `
                            -Code 'avm.bicep.test-name-prefix' `
                            -Message "Deploying test source requires param namePrefix string = '#_namePrefix_#'."))
            }
            if (-not $deployment.Success) {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $testFile.FullName `
                            -Code 'avm.bicep.test-deployment' `
                            -Message 'Deploying test source must directly declare a relative module testDeployment.'))
            }
            if (-not [regex]::IsMatch($source, '(?m)^[ \t]*name:[^\r\n]*-test-[^\r\n]+\r?$')) {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $testFile.FullName `
                            -Code 'avm.bicep.test-deployment-name' `
                            -Message 'The test deployment name must contain -test-.'))
            }
        }

        $folderName = $testFile.Directory.Name
        $expectedSuffix = switch -Regex -CaseSensitive ($folderName) {
            '(?:^|\.)defaults$' { 'min'; break }
            '(?:^|\.)max$' { 'max'; break }
            '(?:^|\.)waf-aligned$' { 'waf'; break }
            default { $null }
        }
        if ($short.Success) {
            $shortValue = $short.Groups['value'].Value
            if ($expectedSuffix -and -not $shortValue.EndsWith($expectedSuffix, [System.StringComparison]::Ordinal)) {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $testFile.FullName `
                            -Code 'avm.bicep.test-service-short-suffix' `
                            -Message "The serviceShort value in '$folderName' must end in '$expectedSuffix'."))
            }
            $others = @($ServiceShortIndex[$shortValue] | Where-Object { $_ -cne $testFile.FullName })
            if ($others.Count -gt 0) {
                $relativeOther = [System.IO.Path]::GetRelativePath($Scope.RepositoryRoot, $others[0]).Replace('\', '/')
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $testFile.FullName `
                            -Code 'avm.bicep.test-service-short-duplicate' `
                            -Message "serviceShort '$shortValue' must be unique across the repository; also used by '$relativeOther'."))
            }
        }

        if ($Scope.IsTopLevel -and $Scope.ModuleType -ceq 'res' -and
            $Scope.ScopeDirectories.Count -gt 0) {
            $relativeTest = [System.IO.Path]::GetRelativePath($testsPath, $testFile.FullName).Replace('\', '/')
            $testScope = [regex]::Match($relativeTest, '(?:^|/)(?<scope>(?:rg|sub|mg)-scope)[^/]*/main\.test\.bicep$')
            if (-not $testScope.Success -or -not $deployment.Success -or
                $deployment.Groups['target'].Value -cnotmatch "(?:^|/)$($testScope.Groups['scope'].Value)/[^']*main\.bicep$") {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $testFile.FullName `
                            -Code 'avm.bicep.test-scope-reference' `
                            -Message 'Multi-scope tests must directly reference their matching scope module.'))
            }
        }
    }

    return $issues.ToArray()
}
