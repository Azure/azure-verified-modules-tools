function Test-AvmBicepConventionLayout {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        $Scope
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $issues = [System.Collections.Generic.List[object]]::new()
    $exemptions = (Get-AvmBicepConfiguration)['conventionExemptions']
    $items = @(Get-ChildItem -LiteralPath $Scope.Path -Force)
    $source = @($items | Where-Object { $_.Name -ieq 'main.bicep' })
    $metadata = @($items | Where-Object { $_.Name -ceq 'metadata.json' })
    $compiled = @($items | Where-Object { $_.Name -ieq 'main.json' })

    if (-not $Scope.IsTopLevel -and $source.Count -eq 0 -and
        $metadata.Count -eq 1 -and $compiled.Count -eq 0) {
        return $issues.ToArray()
    }

    if ($source.Count -ne 1 -or $source[0].PSIsContainer -or $source[0].Name -cne 'main.bicep') {
        $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path (Join-Path $Scope.Path 'main.bicep') `
                    -Code 'avm.bicep.required-source' -Message 'A regular main.bicep with exact casing is required.'))
        return $issues.ToArray()
    }

    foreach ($name in @('main.json', 'README.md')) {
        $matching = @($items | Where-Object { $_.Name -ieq $name })
        if ($matching.Count -ne 1 -or $matching[0].PSIsContainer -or $matching[0].Name -cne $name -or
            ($name -ceq 'main.json' -and
            ($matching[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint))) {
            $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path (Join-Path $Scope.Path $name) `
                        -Code 'avm.bicep.required-file' -Message "A regular $name with exact casing is required."))
        }
    }

    if ($Scope.ModuleType -ceq 'res' -and
        (Split-Path -Path $Scope.Path -Leaf) -cnotmatch '^[a-z0-9]+(?:-+[a-z0-9]+)*$') {
        $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path (Join-Path $Scope.Path 'main.bicep') `
                    -Code 'avm.bicep.resource-folder-name' `
                    -Message 'Resource module folder names must use lowercase letters, digits and hyphens.'))
    }

    $version = @($items | Where-Object { $_.Name -ieq 'version.json' })
    if ($version.Count -gt 0 -and
        ($version.Count -ne 1 -or $version[0].PSIsContainer -or $version[0].Name -cne 'version.json')) {
        $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path (Join-Path $Scope.Path 'version.json') `
                    -Code 'avm.bicep.version-file' -Message 'version.json must be a regular file with exact casing.'))
    }

    if (-not $Scope.IsTopLevel) {
        return $issues.ToArray()
    }

    if ($Scope.ScopeDirectories.Count -gt 0 -and $version.Count -gt 0) {
        $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path (Join-Path $Scope.Path 'version.json') `
                    -Code 'avm.bicep.multiscope-version' `
                    -Message 'A multi-scope parent must not have version.json; version its scope modules instead.'))
    }
    elseif ($Scope.ScopeDirectories.Count -eq 0 -and $version.Count -eq 0) {
        $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path (Join-Path $Scope.Path 'version.json') `
                    -Code 'avm.bicep.version-missing' -Message 'A top-level module requires version.json.'))
    }

    $tests = @($items | Where-Object { $_.Name -ieq 'tests' })
    $testsPath = Join-Path $Scope.Path 'tests'
    if ($tests.Count -ne 1 -or -not $tests[0].PSIsContainer -or $tests[0].Name -cne 'tests' -or
        ($tests[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $testsPath `
                    -Code 'avm.bicep.tests-missing' -Message 'A regular tests directory with exact casing is required.'))
        return $issues.ToArray()
    }

    $e2e = @(Get-ChildItem -LiteralPath $testsPath -Force | Where-Object { $_.Name -ieq 'e2e' })
    $e2ePath = Join-Path $testsPath 'e2e'
    if ($e2e.Count -ne 1 -or -not $e2e[0].PSIsContainer -or $e2e[0].Name -cne 'e2e' -or
        ($e2e[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $e2ePath `
                    -Code 'avm.bicep.e2e-missing' -Message 'A regular tests/e2e directory with exact casing is required.'))
        return $issues.ToArray()
    }

    $testFolders = @(Get-ChildItem -LiteralPath $e2ePath -Directory -Force | Sort-Object Name -CaseSensitive)
    if ($Scope.ModuleType -ceq 'res') {
        if ($Scope.ScopeDirectories.Count -eq 0) {
            if (@($testFolders | Where-Object { $_.Name -clike '*waf-aligned' }).Count -eq 0) {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $e2ePath `
                            -Code 'avm.bicep.waf-test-missing' `
                            -Message 'Resource modules require a waf-aligned e2e test directory.'))
            }
        }
        else {
            foreach ($scopeName in $Scope.ScopeDirectories) {
                foreach ($kind in @('waf-aligned', 'defaults')) {
                    if ($kind -ceq 'defaults' -and $Scope.ModuleRelativePath -cin $exemptions['defaultsTestOptionalModules']) {
                        continue
                    }
                    if (@($testFolders | Where-Object { $_.Name -clike "$scopeName*.$kind" }).Count -eq 0) {
                        $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $e2ePath `
                                    -Code 'avm.bicep.scope-test-missing' `
                                    -Message "Multi-scope resource modules require a $kind test directory for $scopeName."))
                    }
                }
            }
        }
    }

    foreach ($folder in $testFolders) {
        if ($folder.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $folder.FullName `
                        -Code 'avm.bicep.test-directory' -Message 'Linked e2e test directories cannot be validated.'))
            continue
        }

        $testFiles = @(Get-ChildItem -LiteralPath $folder.FullName -Force)
        $mainTest = @($testFiles | Where-Object { $_.Name -ieq 'main.test.bicep' })
        if ($mainTest.Count -ne 1 -or $mainTest[0].PSIsContainer -or $mainTest[0].Name -cne 'main.test.bicep') {
            $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path (Join-Path $folder.FullName 'main.test.bicep') `
                        -Code 'avm.bicep.test-file-missing' `
                        -Message 'Each e2e test directory requires a regular main.test.bicep with exact casing.'))
        }

        $ignore = @($testFiles | Where-Object { $_.Name -ieq '.e2eignore' })
        if ($ignore.Count -eq 0) {
            continue
        }
        if ($ignore.Count -ne 1 -or $ignore[0].PSIsContainer -or $ignore[0].Name -cne '.e2eignore') {
            $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path (Join-Path $folder.FullName '.e2eignore') `
                        -Code 'avm.bicep.e2eignore-file' -Message '.e2eignore must be a regular file with exact casing.'))
            continue
        }
        if ($Scope.ModuleType -ceq 'res' -and $folder.Name -cmatch '(defaults|waf-aligned)$' -and
            $Scope.ModuleRelativePath -cnotin $exemptions['e2eIgnoreAllowedModules']) {
            $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $ignore[0].FullName `
                        -Code 'avm.bicep.e2eignore-required-test' `
                        -Message 'Resource defaults and waf-aligned tests cannot be excluded from deployment.'))
        }
        if ([string]::IsNullOrWhiteSpace([System.IO.File]::ReadAllText($ignore[0].FullName))) {
            $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $ignore[0].FullName `
                        -Code 'avm.bicep.e2eignore-reason' -Message '.e2eignore must explain why deployment is skipped.'))
        }
    }

    return $issues.ToArray()
}
