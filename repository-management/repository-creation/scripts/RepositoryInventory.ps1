#Requires -Version 7.4

function Publish-AvmRepositoryInventory {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.PSModuleInfo] $AuthoringModule,

        [Parameter(Mandatory)]
        [pscustomobject] $InputObject,

        [string] $ToolingRepoUrl = 'https://github.com/Azure/azure-verified-modules-tools',

        [string] $WorkPath = (Join-Path $PWD.Path 'out' 'repository-creation'),

        [switch] $PlanOnly
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $uri = $null
    if (-not [uri]::TryCreate($ToolingRepoUrl, [System.UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com' -or
        $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -notmatch '^/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/?$') {
        throw [System.ArgumentException]::new('toolingRepoUrl must be an HTTPS GitHub repository URL.')
    }
    $repository = $uri.AbsolutePath.Trim('/')
    if ($repository.EndsWith('.git', [System.StringComparison]::Ordinal)) {
        $repository = $repository.Substring(0, $repository.Length - 4)
    }
    $repositoryName = $repository.Split('/')[-1]
    $moduleId = [string]$InputObject.moduleId
    if ($moduleId -notmatch '^avm-(res|ptn|utl)-[a-z-]+$') {
        throw [System.ArgumentException]::new('The inventory moduleId must be an AVM module name.')
    }
    $branch = "chore/add/$moduleId"
    $relativeCsvPath = Join-Path 'repository-management' 'repository-sync' 'config' 'repository-metadata.csv'
    if ($PlanOnly -or -not $PSCmdlet.ShouldProcess($ToolingRepoUrl, "Append $moduleId to the repository inventory and publish its pull request")) {
        return [pscustomobject]@{
            Status = 'plan'
            ToolingRepositoryUrl = $ToolingRepoUrl
            Branch = $branch
            File = $relativeCsvPath
            PullRequestUrl = $null
        }
    }

    $process = @{ AuthoringModule = $AuthoringModule }
    $null = Invoke-AvmRepositoryCreationProcess @process -Tool gh -ArgumentList @('auth', 'status')
    $workRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkPath)
    $stagingRoot = Join-Path $workRoot ('inventory-' + [guid]::NewGuid().ToString('N'))
    $checkout = Join-Path $stagingRoot $repositoryName
    $published = $false
    try {
        $null = New-Item -ItemType Directory -Path $stagingRoot -Force
        $process.WorkingDirectory = $stagingRoot
        $null = Invoke-AvmRepositoryCreationProcess @process -Tool gh -ArgumentList @(
            'repo', 'fork', '--clone', '--default-branch-only', $ToolingRepoUrl
        )
        $process.WorkingDirectory = $checkout
        $null = Invoke-AvmRepositoryCreationProcess @process -Tool gh -ArgumentList @('repo', 'set-default', $repository)
        $null = Invoke-AvmRepositoryCreationProcess @process -Tool git -ArgumentList @('fetch', 'upstream')
        $null = Invoke-AvmRepositoryCreationProcess @process -Tool git -ArgumentList @('reset', '--hard', 'upstream/main')
        $null = Invoke-AvmRepositoryCreationProcess @process -Tool git -ArgumentList @('checkout', '-b', $branch)

        # This compatibility index is publication output, never an input to metadata.json.
        $csvPath = Join-Path $checkout $relativeCsvPath
        $rows = @(Import-Csv -LiteralPath $csvPath)
        $rows += $InputObject
        $rows | Sort-Object -Property moduleId |
            Export-Csv -LiteralPath $csvPath -NoTypeInformation -UseQuotes AsNeeded -Force -Encoding utf8NoBOM
        $content = [System.IO.File]::ReadAllText($csvPath).Replace("`r`n", "`n")
        [System.IO.File]::WriteAllText($csvPath, $content, [System.Text.UTF8Encoding]::new($false))

        $null = Invoke-AvmRepositoryCreationProcess @process -Tool git -ArgumentList @('add', '--', $relativeCsvPath)
        $null = Invoke-AvmRepositoryCreationProcess @process -Tool git -ArgumentList @('commit', '-m', "chore: add $moduleId metadata")
        $null = Invoke-AvmRepositoryCreationProcess @process -Tool git -ArgumentList @('push', '--set-upstream', 'origin', $branch)
        $pullRequest = Invoke-AvmRepositoryCreationProcess @process -Tool gh -ArgumentList @(
            'pr', 'create', '--title', "chore: add $moduleId metadata",
            '--body', "This PR adds metadata for the $moduleId module."
        )
        $published = $true
        return [pscustomobject]@{
            Status = 'pass'
            ToolingRepositoryUrl = $ToolingRepoUrl
            Branch = $branch
            File = $relativeCsvPath
            PullRequestUrl = $pullRequest.StdOut.Trim()
        }
    }
    catch {
        throw [System.InvalidOperationException]::new(
            "Repository inventory publication failed for $ToolingRepoUrl. Inspect '$stagingRoot' and the remote branch before retrying. $($_.Exception.Message)",
            $_.Exception
        )
    }
    finally {
        if ($published) {
            Remove-Item -LiteralPath $stagingRoot -Recurse -Force
        }
    }
}
