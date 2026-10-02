#Requires -Version 7.4

function Get-AvmPrReviewerRoutingEcosystem {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Repository)

    if ($Repository -ieq 'Azure/bicep-registry-modules') {
        return 'bicep'
    }
    if ($Repository.StartsWith('Azure/', [System.StringComparison]::OrdinalIgnoreCase) -and
        (Get-RepositoryTerraformModuleIdentity -Name $Repository.Substring(6))) {
        return 'terraform'
    }
    throw [System.ArgumentException]::new("Repository '$Repository' is not an Azure AVM routing target.")
}

function Get-AvmPrReviewerRoutingTarget {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $PullRequestUrl,
        [string] $DefaultRepository = 'Azure/bicep-registry-modules'
    )

    $value = $PullRequestUrl.Trim()
    $number = 0
    if ($value -match '^[1-9][0-9]*$' -and [int]::TryParse($value, [ref]$number)) {
        return @{ Repository = $DefaultRepository; Url = "https://github.com/$DefaultRepository/pull/$number" }
    }
    $urlMatch = [regex]::Match($value,
        '^https://(?:github\.com/|api\.github\.com/repos/)(?<repository>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pulls?/(?<number>[1-9][0-9]*)/?(?:[?#].*)?$',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $urlMatch.Success -or -not [int]::TryParse($urlMatch.Groups['number'].Value, [ref]$number)) {
        throw [System.ArgumentException]::new('Supply a GitHub pull request URL or a positive pull request number.')
    }
    $repository = $urlMatch.Groups['repository'].Value
    return @{ Repository = $repository; Url = "https://github.com/$repository/pull/$number" }
}

function Get-AvmPrReviewerRoutingRepositories {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string] $PullRequestUrl)

    $repositories = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($repository in @(Get-RepositoryInstalledRepositories)) {
        if ($repository.archived -or $repository.full_name -ine "Azure/$($repository.name)") {
            continue
        }
        if ($repository.name -ieq 'bicep-registry-modules' -or
            (Get-RepositoryTerraformModuleIdentity -Name $repository.name)) {
            $null = $repositories.Add([string]$repository.full_name)
        }
    }
    if ($repositories.Count -eq 0) {
        throw [System.InvalidOperationException]::new('No active AVM routing repositories were found in the app installation.')
    }
    if (-not [string]::IsNullOrWhiteSpace($PullRequestUrl)) {
        $target = Get-AvmPrReviewerRoutingTarget -PullRequestUrl $PullRequestUrl
        if (-not $repositories.Contains($target.Repository)) {
            throw [System.ArgumentException]::new("Repository '$($target.Repository)' is not an active AVM repository in the app installation.")
        }
        return @($repositories | Where-Object { $_ -ieq $target.Repository })
    }
    return @($repositories)
}

function Get-AvmPrReviewerRoutingSearchCandidates {
    <#
    .SYNOPSIS
    Searches batches of repositories, rejecting incomplete or capped results.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [string[]] $Repositories,
        [Parameter(Mandatory)] [ValidateRange(1, [int]::MaxValue)] [int] $UpdatedWithinMinutes
    )

    $cutoff = [datetime]::UtcNow.AddMinutes(-$UpdatedWithinMinutes).ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)
    $candidates = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    for ($offset = 0; $offset -lt $Repositories.Count; $offset += 20) {
        $batch = @($Repositories[$offset..([math]::Min($offset + 19, $Repositories.Count - 1))])
        $query = "is:pr is:open draft:false archived:false updated:>=$cutoff " +
            (($batch | ForEach-Object { "repo:$_" }) -join ' ')
        $batchCount = 0
        $expectedCount = $null
        $page = 1
        do {
            $response = Invoke-RepositoryGitHub -AsJson -Arguments @(
                'api', '--hostname', 'github.com', '--method', 'GET', 'search/issues',
                '-f', "q=$query", '-f', 'per_page=100', '-f', "page=$page",
                '-f', 'sort=created', '-f', 'order=asc'
            )
            if ($null -eq $response -or -not $response.PSObject.Properties['total_count'] -or
                -not $response.PSObject.Properties['incomplete_results'] -or -not $response.PSObject.Properties['items']) {
                throw [System.IO.InvalidDataException]::new('GitHub returned an invalid reviewer-routing search response.')
            }
            if ($response.incomplete_results -or $response.total_count -gt 1000 -or $response.total_count -lt 0) {
                throw [System.IO.InvalidDataException]::new('GitHub reviewer-routing search returned incomplete results or exceeded its 1,000-result limit.')
            }
            if ($null -eq $expectedCount) {
                $expectedCount = $response.total_count
            }
            elseif ($expectedCount -ne $response.total_count) {
                throw [System.IO.InvalidDataException]::new('GitHub reviewer-routing search changed during pagination.')
            }
            $items = @($response.items)
            if ($items.Count -eq 0 -and $batchCount -lt $expectedCount) {
                throw [System.IO.InvalidDataException]::new('GitHub reviewer-routing search ended before all results were retrieved.')
            }
            foreach ($item in $items) {
                $target = Get-AvmPrReviewerRoutingTarget -PullRequestUrl $item.html_url
                if ($batch -inotcontains $target.Repository -or
                    -not $item.PSObject.Properties['pull_request'] -or -not $seen.Add($target.Url)) {
                    throw [System.IO.InvalidDataException]::new('GitHub reviewer-routing search returned an unexpected or duplicate pull request.')
                }
                $candidates.Add([pscustomobject]@{
                        Repository = $target.Repository
                        number     = $item.number
                        url        = $target.Url
                    })
            }
            $batchCount += $items.Count
            $page++
        } while ($batchCount -lt $expectedCount)
        if ($batchCount -ne $expectedCount) {
            throw [System.IO.InvalidDataException]::new('GitHub reviewer-routing search result count does not match its total.')
        }
    }
    return $candidates.ToArray()
}

function Invoke-AvmPrReviewerRoutingSweep {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string[]] $Repository,
        [string] $PullRequestUrl,
        [ValidateRange(0, [int]::MaxValue)] [int] $UpdatedWithinMinutes = 0
    )

    $repositories = @($Repository | Sort-Object -Unique)
    if (-not [string]::IsNullOrWhiteSpace($PullRequestUrl)) {
        $defaultRepository = if ($repositories.Count -eq 1) { $repositories[0] } else { 'Azure/bicep-registry-modules' }
        $target = Get-AvmPrReviewerRoutingTarget -PullRequestUrl $PullRequestUrl -DefaultRepository $defaultRepository
        if ($repositories -inotcontains $target.Repository) {
            throw [System.ArgumentException]::new("Pull request repository '$($target.Repository)' is outside the requested routing repositories.")
        }
        $repositories = @($repositories | Where-Object { $_ -ieq $target.Repository })
        $PullRequestUrl = $target.Url
    }
    $ecosystems = @{}
    foreach ($name in $repositories) {
        $ecosystems[$name] = Get-AvmPrReviewerRoutingEcosystem -Repository $name
    }
    $catalog = Get-AvmReviewerRoutingCatalog
    $terraformRepositories = @($repositories | Where-Object { $ecosystems[$_] -ceq 'terraform' })
    $searchCandidates = @()
    $useSearch = $terraformRepositories.Count -gt 0 -and $UpdatedWithinMinutes -gt 0 -and
        [string]::IsNullOrWhiteSpace($PullRequestUrl)
    if ($useSearch) {
        try {
            $searchCandidates = @(Get-AvmPrReviewerRoutingSearchCandidates -Repositories $terraformRepositories -UpdatedWithinMinutes $UpdatedWithinMinutes)
            Write-Host "Found $($searchCandidates.Count) recently updated Terraform pull request(s) across $($terraformRepositories.Count) repositories."
        }
        catch {
            Write-Warning "Cross-repository reviewer discovery failed: $($_.Exception.Message) Falling back to complete per-repository lists."
            $useSearch = $false
        }
    }

    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $repositories) {
        try {
            $parameters = @{
                Repository           = $name
                Ecosystem            = $ecosystems[$name]
                CatalogIndex         = Get-AvmReviewerRoutingCatalogIndex -Repository $name -Ecosystem $ecosystems[$name] -Catalog $catalog
                PullRequestUrl       = $PullRequestUrl
                UpdatedWithinMinutes = $UpdatedWithinMinutes
                WhatIf               = $WhatIfPreference
            }
            if ($useSearch -and $ecosystems[$name] -ceq 'terraform') {
                $parameters.PullRequests = @($searchCandidates | Where-Object { $_.Repository -ieq $name })
                if ($parameters.PullRequests.Count -eq 0) {
                    continue
                }
            }
            Invoke-AvmPrReviewerRouting @parameters
        }
        catch {
            $failures.Add("[$name]: $($_.Exception.Message)")
            Write-Warning "Reviewer routing failed for [$name]. $($_.Exception.Message)"
        }
    }
    Write-AvmRunSummary -Title 'Reviewer routing fleet' `
        -Overview "$($repositories.Count) repositories selected, $($terraformRepositories.Count) Terraform, $($failures.Count) failed." `
        -Failures $failures.ToArray() -DryRun:$WhatIfPreference
    if ($failures.Count -gt 0) {
        throw [System.AggregateException]::new(($failures -join [System.Environment]::NewLine))
    }
}
