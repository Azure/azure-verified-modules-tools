function Get-AvmReleaseVersionPlan {
    <#
    .SYNOPSIS
        Calculate the next module version from the version labels of release-triggering pull requests.

    .DESCRIPTION
        Applies one increment to the current version. The highest version label among the pull requests wins, in the order major, minor, patch. Before 1.0.0, a minor label bumps the minor number, a patch label bumps the patch number, and a major label is rejected. Each pull request must carry exactly one version label. When any rule fails, the plan lists the issues and returns no version, so publication blocks instead of guessing.

    .PARAMETER CurrentVersion
        The latest published version, with or without a leading 'v'. Null or empty means no published version is known.

    .PARAMETER PullRequests
        The release-triggering pull requests. Each entry has Number and Labels (the version labels currently on the pull request).

    .EXAMPLE
        Get-AvmReleaseVersionPlan -CurrentVersion '0.8.2' -PullRequests @(@{ Number = 1; Labels = @('patch') }, @{ Number = 2; Labels = @('minor') })

        Returns Version '0.9.0' and Increment 'minor'.

    .OUTPUTS
        Ordered dictionary with Version, PreviousVersion, Increment, and Issues. Each issue has Code, PullRequest, and Message.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $CurrentVersion,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $PullRequests = @()
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $policy = Get-AvmReleasePolicy
    $issues = [System.Collections.Generic.List[object]]::new()
    $rank = @{ patch = 1; minor = 2; major = 3 }

    $major = 0
    $minor = 0
    $patch = 0
    $previous = $null
    if ([string]::IsNullOrWhiteSpace($CurrentVersion)) {
        $issues.Add([ordered]@{ Code = 'missing-base-version'; PullRequest = $null; Message = 'No published version is known, so the next version cannot be calculated.' })
    }
    else {
        $match = [regex]::Match($CurrentVersion.Trim(), '^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$')
        if (-not $match.Success) {
            $issues.Add([ordered]@{ Code = 'invalid-base-version'; PullRequest = $null; Message = "The latest version '$CurrentVersion' is not a MAJOR.MINOR.PATCH version." })
        }
        else {
            $major = [int]$match.Groups[1].Value
            $minor = [int]$match.Groups[2].Value
            $patch = [int]$match.Groups[3].Value
            $previous = "$major.$minor.$patch"
        }
    }

    $prs = @($PullRequests | Where-Object { $null -ne $_ })
    if ($prs.Count -eq 0) {
        $issues.Add([ordered]@{ Code = 'nothing-to-release'; PullRequest = $null; Message = 'No release-triggering pull request is pending.' })
    }

    $highest = 0
    foreach ($pr in ($prs | Sort-Object -Property { [int](Get-AvmPropertyValue -InputObject $_ -Name 'Number') })) {
        $number = [int](Get-AvmPropertyValue -InputObject $pr -Name 'Number')
        $labels = @(Get-AvmPropertyValue -InputObject $pr -Name 'Labels') |
            Where-Object { $null -ne $_ } |
            ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } |
            Where-Object { $policy.VersionLabels -contains $_ } |
            Select-Object -Unique
        $labels = @($labels)
        if ($labels.Count -eq 0) {
            $issues.Add([ordered]@{ Code = 'missing-label'; PullRequest = $number; Message = "Pull request #$number has no version label." })
            continue
        }
        if ($labels.Count -gt 1) {
            $issues.Add([ordered]@{ Code = 'conflicting-labels'; PullRequest = $number; Message = "Pull request #$number has more than one version label: $($labels -join ', ')." })
            continue
        }
        $label = $labels[0]
        if ($label -eq 'major' -and $null -ne $previous -and $major -eq 0) {
            $issues.Add([ordered]@{ Code = 'major-before-1.0'; PullRequest = $number; Message = "Pull request #$number has a major label, but major labels are not allowed before 1.0.0. Use minor for breaking changes." })
            continue
        }
        if ($rank[$label] -gt $highest) {
            $highest = $rank[$label]
        }
    }

    $increment = $null
    if ($highest -gt 0) {
        $increment = @($rank.Keys | Where-Object { $rank[$_] -eq $highest })[0]
    }

    $version = $null
    if ($issues.Count -eq 0 -and $null -ne $increment) {
        switch ($increment) {
            'major' {
                $version = "$($major + 1).0.0"
            }
            'minor' {
                $version = "$major.$($minor + 1).0"
            }
            default {
                $version = "$major.$minor.$($patch + 1)"
            }
        }
    }

    return [ordered]@{
        Version         = $version
        PreviousVersion = $previous
        Increment       = $increment
        Issues          = $issues.ToArray()
    }
}
