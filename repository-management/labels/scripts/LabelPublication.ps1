#Requires -Version 7.4

function Invoke-AvmLabelGitHubApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $GitHubPath,
        [Parameter(Mandatory)][string[]] $Arguments
    )

    $result = Invoke-AvmStandardLabelProcess -FilePath $GitHubPath -ArgumentList (@('api') + $Arguments)
    if ([string]::IsNullOrWhiteSpace($result.StdOut)) {
        throw [System.IO.InvalidDataException]::new('GitHub returned an empty API response.')
    }
    return $result.StdOut
}

function ConvertFrom-AvmLabelApiPages {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Json)

    $pages = ConvertFrom-Json -InputObject $Json -AsHashtable -Depth 20 -NoEnumerate
    if ($pages -isnot [array]) {
        throw [System.IO.InvalidDataException]::new('GitHub returned an invalid paginated API response.')
    }
    foreach ($page in $pages) {
        if ($page -isnot [array]) {
            throw [System.IO.InvalidDataException]::new('GitHub returned an invalid page of API results.')
        }
        foreach ($item in $page) {
            if ($item -isnot [System.Collections.IDictionary]) {
                throw [System.IO.InvalidDataException]::new('GitHub returned an invalid API result.')
            }
            $item
        }
    }
}

function Get-AvmLabelCsvAtRef {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $GitHubPath,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Ref
    )

    $file = ConvertFrom-Json -InputObject (
        Invoke-AvmLabelGitHubApi -GitHubPath $GitHubPath -Arguments @("repos/$Repository/contents/${Path}?ref=$Ref")
    ) -AsHashtable -Depth 20
    if ($file -isnot [System.Collections.IDictionary] -or
        $file['sha'] -cnotmatch '^[0-9a-f]{40}$' -or -not $file['content']) {
        throw [System.IO.InvalidDataException]::new("GitHub returned invalid label CSV metadata for $Repository at $Ref.")
    }
    $content = [System.Text.UTF8Encoding]::new($false, $true).GetString(
        [Convert]::FromBase64String(([string] $file['content'] -replace '\s', ''))
    )
    return [pscustomobject]@{ Sha = $file['sha']; Content = $content }
}

function Test-AvmStandardGitHubLabelsCsvMatches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Published,
        [Parameter(Mandatory)][string] $Generated
    )

    $publishedRows = @($Published | ConvertFrom-Csv -ErrorAction Stop)
    $generatedRows = @($Generated | ConvertFrom-Csv -ErrorAction Stop)
    if ($publishedRows.Count -eq 0 -or
        ($publishedRows[0].PSObject.Properties.Name -join ',') -cne 'Name,Description,HEX') {
        throw [System.IO.InvalidDataException]::new('The published labels CSV has invalid columns or no rows.')
    }
    if ($publishedRows.Count -ne $generatedRows.Count) {
        return $false
    }
    for ($index = 0; $index -lt $publishedRows.Count; $index++) {
        foreach ($column in @('Name', 'Description', 'HEX')) {
            if ($publishedRows[$index].$column -cne $generatedRows[$index].$column) {
                return $false
            }
        }
    }
    return $true
}

function Invoke-AvmStandardGitHubLabelsPublication {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][string] $GitHubPath,
        [Parameter(Mandatory)][string] $Csv,
        [switch] $Publish,
        [string] $BotLogin,
        [string] $RunId,
        [string] $RunAttempt,
        [string] $SourceSha
    )

    $repository = 'Azure/Azure-Verified-Modules'
    $path = 'docs/static/governance/avm-standard-github-labels.csv'
    $main = Get-AvmLabelCsvAtRef -GitHubPath $GitHubPath -Repository $repository -Path $path -Ref 'main'
    if (Test-AvmStandardGitHubLabelsCsvMatches -Published $main.Content -Generated $Csv) {
        Write-Output "The published labels CSV in $repository already matches the tools JSON."
        return
    }

    Write-Output "The published labels CSV in $repository differs from the tools JSON."
    if (-not $Publish -or -not $PSCmdlet.ShouldProcess("$repository/$path", 'Publish generated CSV through a pull request')) {
        return
    }
    if ($BotLogin -cne 'azure-verified-modules[bot]' -or
        $RunId -cnotmatch '^[0-9]+$' -or $RunAttempt -cnotmatch '^[0-9]+$' -or
        $SourceSha -cnotmatch '^[0-9a-f]{40}$') {
        throw [System.InvalidOperationException]::new('Publishing labels requires the expected bot identity, run, and source commit.')
    }

    $open = @(ConvertFrom-AvmLabelApiPages -Json (
        Invoke-AvmLabelGitHubApi -GitHubPath $GitHubPath -Arguments @(
            '--paginate', '--slurp', "repos/$repository/pulls?state=open&base=main&per_page=100"
        )
    ) | Where-Object {
            $_['head']['ref'] -like 'automation/avm-labels-*'
        })
    if ($open.Count -gt 1) {
        throw [System.InvalidOperationException]::new("Multiple generated-label pull requests exist in $repository; resolve them before publishing.")
    }

    $existing = if ($open.Count -eq 1) { $open[0] } else { $null }
    if ($null -ne $existing) {
        $number = [int] $existing['number']
        $files = @(ConvertFrom-AvmLabelApiPages -Json (
                Invoke-AvmLabelGitHubApi -GitHubPath $GitHubPath -Arguments @(
                    '--paginate', '--slurp', "repos/$repository/pulls/$number/files?per_page=100"
                )
            ))
        $commits = @(ConvertFrom-AvmLabelApiPages -Json (
                Invoke-AvmLabelGitHubApi -GitHubPath $GitHubPath -Arguments @(
                    '--paginate', '--slurp', "repos/$repository/pulls/$number/commits?per_page=100"
                )
            ))
        Assert-AvmStandardLabelPublicationCandidate -PullRequest $existing -Files $files -Commits $commits `
            -Repository $repository -Path $path -BotLogin $BotLogin
        $branch = [string] $existing['head']['ref']
        $branchFile = Get-AvmLabelCsvAtRef -GitHubPath $GitHubPath -Repository $repository -Path $path -Ref $branch
        if (Test-AvmStandardGitHubLabelsCsvMatches -Published $branchFile.Content -Generated $Csv) {
            Write-Output "The generated-label change is awaiting review: $($existing['html_url'])"
            return
        }
        $sha = $branchFile.Sha
    }
    else {
        $base = ConvertFrom-Json -InputObject (
            Invoke-AvmLabelGitHubApi -GitHubPath $GitHubPath -Arguments @("repos/$repository/git/ref/heads/main")
        ) -AsHashtable -Depth 20
        if ($base['object']['sha'] -cnotmatch '^[0-9a-f]{40}$') {
            throw [System.IO.InvalidDataException]::new("GitHub returned an invalid main-branch ref for $repository.")
        }
        $branch = "automation/avm-labels-$RunId-$RunAttempt"
        $null = Invoke-AvmLabelGitHubApi -GitHubPath $GitHubPath -Arguments @(
            '--method', 'POST', "repos/$repository/git/refs",
            '-f', "ref=refs/heads/$branch", '-f', "sha=$($base['object']['sha'])"
        )
        $sha = $main.Sha
    }

    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Csv))
    $null = Invoke-AvmLabelGitHubApi -GitHubPath $GitHubPath -Arguments @(
        '--method', 'PUT', "repos/$repository/contents/$path",
        '-f', 'message=docs: synchronize AVM standard GitHub labels',
        '-f', "content=$encoded", '-f', "branch=$branch", '-f', "sha=$sha"
    )

    if ($null -ne $existing) {
        Write-Output "Updated the generated-label change: $($existing['html_url'])"
    }
    else {
        $created = ConvertFrom-Json -InputObject (
            Invoke-AvmLabelGitHubApi -GitHubPath $GitHubPath -Arguments @(
                '--method', 'POST', "repos/$repository/pulls",
                '-f', "head=$branch", '-f', 'base=main',
                '-f', 'title=docs: synchronize AVM standard GitHub labels',
                '-f', "body=Generated from https://github.com/Azure/azure-verified-modules-tools/blob/$SourceSha/repository-management/labels/avm-standard-github-labels.json"
            )
        ) -AsHashtable -Depth 20
        if ($created['html_url'] -cnotmatch '^https://github\.com/Azure/Azure-Verified-Modules/pull/[0-9]+$') {
            throw [System.IO.InvalidDataException]::new('GitHub did not return a valid generated-label pull request URL.')
        }
        Write-Output "Opened the generated-label change: $($created['html_url'])"
    }
}
