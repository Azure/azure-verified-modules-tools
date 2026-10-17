function Get-RepositoryForkApprovalPolicy {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Repository
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $response = Invoke-RepositoryGitHubApi -Endpoint "repos/$Repository/actions/permissions/fork-pr-contributor-approval"
    if ($response -isnot [pscustomobject] -or
        -not $response.PSObject.Properties['approval_policy'] -or
        $response.approval_policy -isnot [string] -or
        $response.approval_policy -cnotin @(
            'first_time_contributors_new_to_github', 'first_time_contributors', 'all_external_contributors'
        )) {
        throw [System.IO.InvalidDataException]::new("GitHub returned an invalid fork workflow approval policy for $Repository.")
    }
    return $response.approval_policy
}

function Set-RepositoryForkApprovalPolicy {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('\AAzure/terraform-(azure|azurerm|azapi)-avm-(res|ptn|utl)-[a-z0-9]+(?:-[a-z0-9]+)*\z')]
        [string] $Repository,

        [bool] $PlanOnly = $false
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $requiredPolicy = 'first_time_contributors'
    $result = [pscustomobject]@{
        Repository = $Repository
        Status = 'Preview'
        ApprovalPolicy = $requiredPolicy
        PreviousApprovalPolicy = $null
    }
    $action = $PlanOnly ? 'Plan fork workflow approval policy' : 'Require fork workflow approval for first-time contributors'
    if (-not $PSCmdlet.ShouldProcess($Repository, $action)) {
        return $result
    }

    $currentPolicy = Get-RepositoryForkApprovalPolicy -Repository $Repository
    $result.PreviousApprovalPolicy = $currentPolicy
    if ($currentPolicy -ceq $requiredPolicy) {
        Write-Information "$Repository already requires fork workflow approval for first-time contributors." -InformationAction Continue
        $result.Status = 'Unchanged'
        return $result
    }

    $mode = $PlanOnly ? 'PLAN' : 'APPLY'
    Write-Information "[$mode] $Repository fork workflow approval: $currentPolicy -> $requiredPolicy." -InformationAction Continue
    if ($PlanOnly) {
        $result.Status = 'Planned'
        return $result
    }

    $null = Invoke-RepositoryGitHub -MaxRetries 0 -Arguments @(
        'api', '--hostname', 'github.com', '--method', 'PUT',
        '--header', 'Accept: application/vnd.github+json',
        '--header', 'X-GitHub-Api-Version: 2022-11-28',
        "repos/$Repository/actions/permissions/fork-pr-contributor-approval",
        '--raw-field', "approval_policy=$requiredPolicy"
    )
    if ((Get-RepositoryForkApprovalPolicy -Repository $Repository) -cne $requiredPolicy) {
        throw [System.InvalidOperationException]::new("GitHub did not confirm the requested fork workflow approval policy for $Repository.")
    }

    $result.Status = 'Updated'
    return $result
}
