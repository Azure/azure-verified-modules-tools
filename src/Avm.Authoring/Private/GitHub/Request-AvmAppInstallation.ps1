function Request-AvmAppInstallation {
    <#
    .SYNOPSIS
        Ensure a pull request requests the AVM app installations for a repository.
    .DESCRIPTION
        Checks each app configuration file on the operations repository's main
        branch. When the repository is listed in all of them, returns
        'installed'. Otherwise an open pull request that names the module is
        reused ('pending'). If none exists, the change is committed to a branch
        in the caller's fork, which is created when missing, and a pull request
        is opened ('requested'). Re-running reuses an existing fork, branch, or
        pull request.
    .PARAMETER Repository
        Module repository name without the organization.
    .PARAMETER ModuleName
        Module name, for example avm-res-network-virtualnetwork.
    .PARAMETER OperationsRepository
        Repository holding the app configuration files, as owner/name.
    .PARAMETER ConfigurationPath
        App configuration files that must list the repository.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Repository,

        [Parameter(Mandatory)]
        [string] $ModuleName,

        [string] $OperationsRepository = 'microsoft/github-operations',

        [string[]] $ConfigurationPath = @(
            'apps/azure/azure-verified-modules.yaml',
            'apps/azure/terraform-cloud.yaml'
        )
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $missing = @(Get-AvmAppInstallationMissingConfiguration -Repository $Repository `
            -OperationsRepository $OperationsRepository -ConfigurationPath $ConfigurationPath)
    if ($missing.Count -eq 0) {
        return [pscustomobject]@{ Status = 'installed'; PullRequest = $null; Files = @() }
    }

    $boundary = '(?<![A-Za-z0-9-])({0}|{1})(?![A-Za-z0-9-])' -f [regex]::Escape($Repository), [regex]::Escape($ModuleName)
    $query = "repo:$OperationsRepository is:pr is:open `"$ModuleName`""
    $search = Invoke-AvmGitHubApi -Endpoint ('search/issues?per_page=50&q=' + [uri]::EscapeDataString($query))
    $open = @(
        foreach ($item in @($search['items'])) {
            if ($item -is [System.Collections.IDictionary] -and
                (([string]$item['title']) -match $boundary -or ([string]$item['body']) -match $boundary)) {
                $item
            }
        }
    )
    if ($open.Count -gt 0) {
        return [pscustomobject]@{ Status = 'pending'; PullRequest = [string]$open[0]['html_url']; Files = [string[]]$missing }
    }
    if (-not $PSCmdlet.ShouldProcess($OperationsRepository, "Open an app installation pull request for $Repository")) {
        return [pscustomobject]@{ Status = 'planned'; PullRequest = $null; Files = [string[]]$missing }
    }

    # Creating a fork returns the caller's existing fork, even a renamed one.
    try {
        $fork = Invoke-AvmGitHubApi -Method POST -Endpoint "repos/$OperationsRepository/forks" -Body @{ default_branch_only = $true }
    }
    catch [AvmGitHubException] {
        $login = [string](Invoke-AvmGitHubApi -Endpoint 'user')['login']
        $fork = Invoke-AvmGitHubApi -Endpoint "repos/$login/$(($OperationsRepository -split '/')[-1])" -AllowNotFound
        if ($null -eq $fork -or $fork['fork'] -ne $true -or $fork['parent'] -isnot [System.Collections.IDictionary] -or
            [string]$fork['parent']['full_name'] -ne $OperationsRepository) {
            throw
        }
    }
    $forkName = [string]$fork['full_name']
    $forkOwner = [string]$fork['owner']['login']
    $branch = "chore/app-install-avm/$ModuleName"
    $sha = [string](Invoke-AvmGitHubApi -Endpoint "repos/$OperationsRepository/git/ref/heads/main")['object']['sha']
    for ($attempt = 1; ; $attempt++) {
        try {
            if ($null -eq (Invoke-AvmGitHubApi -Endpoint "repos/$forkName/git/ref/heads/$branch" -AllowNotFound)) {
                $null = Invoke-AvmGitHubApi -Method POST -Endpoint "repos/$forkName/git/refs" `
                    -Body @{ ref = "refs/heads/$branch"; sha = $sha }
            }
            break
        }
        catch [AvmGitHubException] {
            # A new fork is created asynchronously and rejects Git data calls until it is ready.
            if ($_.Exception.Message -match 'Reference already exists') {
                break
            }
            if ($attempt -ge 10 -or $_.Exception.StatusCode -notin @(404, 409, 422)) {
                throw
            }
            Start-Sleep -Seconds 3
        }
    }

    $message = "chore: app install avm $ModuleName"
    $encodedBranch = [uri]::EscapeDataString($branch)
    foreach ($path in $missing) {
        $file = Invoke-AvmGitHubApi -Endpoint "repos/$forkName/contents/$($path)?ref=$encodedBranch"
        $text = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(([string]$file['content'] -replace '\s', '')))
        $update = Get-AvmAppInstallationListContent -Content $text -Repository $Repository
        if ($update.Changed) {
            $body = @{
                message = $message
                content = [System.Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($update.Content))
                sha     = [string]$file['sha']
                branch  = $branch
            }
            $null = Invoke-AvmGitHubApi -Method PUT -Endpoint "repos/$forkName/contents/$path" -Body $body
        }
    }

    $head = "$($forkOwner):$branch"
    try {
        $pullRequest = Invoke-AvmGitHubApi -Method POST -Endpoint "repos/$OperationsRepository/pulls" -Body @{
            title = $message
            head  = $head
            base  = 'main'
            body  = "This PR requests the Azure Verified Modules app installations for https://github.com/Azure/$Repository ($ModuleName)."
        }
        $url = [string]$pullRequest['html_url']
    }
    catch [AvmGitHubException] {
        if ($_.Exception.StatusCode -ne 422) {
            throw
        }
        $existing = @(Invoke-AvmGitHubApi -Endpoint (
                "repos/$OperationsRepository/pulls?state=open&head=" + [uri]::EscapeDataString($head)))
        if ($existing.Count -eq 0) {
            throw
        }
        $url = [string]$existing[0]['html_url']
    }
    return [pscustomobject]@{ Status = 'requested'; PullRequest = $url; Files = [string[]]$missing }
}
