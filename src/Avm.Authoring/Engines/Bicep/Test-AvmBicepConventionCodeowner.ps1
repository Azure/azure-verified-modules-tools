function Test-AvmBicepConventionCodeowner {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $issues = [System.Collections.Generic.List[object]]::new()
    $github = Join-Path $RepositoryRoot '.github'
    $path = Join-Path $github 'CODEOWNERS'
    $directories = @(Get-ChildItem -LiteralPath $RepositoryRoot -Force |
            Where-Object { $_.Name -ieq '.github' })
    if ($directories.Count -ne 1 -or -not $directories[0].PSIsContainer -or
        $directories[0].Name -cne '.github' -or
        ($directories[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot -Path $path `
                    -Code 'avm.bicep.codeowners-file' `
                    -Message 'A regular .github/CODEOWNERS file with exact casing is required.'))
        return $issues.ToArray()
    }

    $files = @(Get-ChildItem -LiteralPath $github -Force |
            Where-Object { $_.Name -ieq 'CODEOWNERS' })
    if ($files.Count -ne 1 -or $files[0].PSIsContainer -or $files[0].Name -cne 'CODEOWNERS' -or
        ($files[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot -Path $path `
                    -Code 'avm.bicep.codeowners-file' `
                    -Message 'A regular .github/CODEOWNERS file with exact casing is required.'))
        return $issues.ToArray()
    }

    $readException = $null
    try {
        $lines = [System.IO.File]::ReadAllLines($path, [System.Text.UTF8Encoding]::new($false, $true))
    }
    catch [System.IO.IOException] { $readException = $_.Exception }
    catch [System.UnauthorizedAccessException] { $readException = $_.Exception }
    catch [System.Text.DecoderFallbackException] { $readException = $_.Exception }
    if ($null -ne $readException) {
        $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot -Path $path `
                    -Code 'avm.bicep.codeowners-read' `
                    -Message "CODEOWNERS could not be read as UTF-8: $($readException.Message)"))
        return $issues.ToArray()
    }
    $rules = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $text = [regex]::Replace($lines[$index].Trim(), '\s+', ' ')
        if ($text.Length -gt 0 -and -not $text.StartsWith('#')) {
            $rules.Add([pscustomobject]@{
                    Text    = $text
                    Line    = $index + 1
                    Pattern = $text.Split(' ')[0]
                })
        }
    }

    if ($rules.Count -lt 1 -or
        $rules[0].Text -cne '* @Azure/azure-verified-modules-tooling-contributors') {
        $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot -Path $path `
                    -Code 'avm.bicep.codeowners-default' `
                    -Message 'The first CODEOWNERS rule must assign the repository to the tooling contributors.'))
    }
    if ($rules.Count -lt 2 -or $rules[1].Text -cne '/avm/') {
        $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot -Path $path `
                    -Code 'avm.bicep.codeowners-module' `
                    -Message 'The second CODEOWNERS rule must leave /avm/ without an assigned owner.'))
    }
    $overrides = @(
        '*avm.core.team.tests.ps1 @Azure/azure-verified-modules-tooling-contributors'
        '*.e2eignore @Azure/azure-verified-modules-tooling-contributors'
        'metadata.json @Azure/azure-verified-modules-engineering-owners @Azure/azure-verified-modules-module-owners'
    )
    for ($index = 0; $index -lt $overrides.Count; $index++) {
        $ruleIndex = $rules.Count - $overrides.Count + $index
        if ($ruleIndex -lt 0 -or $rules[$ruleIndex].Text -cne $overrides[$index]) {
            $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot -Path $path `
                        -Code 'avm.bicep.codeowners-override' `
                        -Message ("The last three CODEOWNERS rules must end in '{0}' at position {1}." -f $overrides[$index], ($index + 1))))
        }
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    for ($index = 0; $index -lt $rules.Count; $index++) {
        $rule = $rules[$index]
        if ($index -ne 1 -and $rule.Pattern -imatch '^/?avm(?:/|$)') {
            $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot -Path $path `
                        -Code 'avm.bicep.codeowners-per-module' -Line $rule.Line `
                        -Message 'Additional avm/ ownership entries must not be added to CODEOWNERS.'))
        }
        elseif ($index -gt 1 -and $index -lt $rules.Count - $overrides.Count) {
            $anchored = [regex]::Match($rule.Pattern, '^/(?<root>[A-Za-z0-9._-]+)(?:/|$)')
            if (-not $anchored.Success -or
                $anchored.Groups['root'].Value -in @('avm', '.', '..')) {
                $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot -Path $path `
                            -Code 'avm.bicep.codeowners-module-override' -Line $rule.Line `
                            -Message 'Additional CODEOWNERS patterns must be anchored outside /avm/ to preserve the ownerless module tree.'))
            }
        }
        if (-not $seen.Add($rule.Pattern)) {
            $issues.Add((New-AvmBicepConventionIssue -Root $RepositoryRoot -Path $path `
                        -Code 'avm.bicep.codeowners-duplicate' -Line $rule.Line `
                        -Message "Ownership pattern '$($rule.Pattern)' must have only one entry."))
        }
    }

    return $issues.ToArray()
}
