function Sync-AvmRepositoryTeamAccess {
    <#
    .SYNOPSIS
        Grant teams at least the requested permission on a repository.
    .DESCRIPTION
        Reads each team's current access directly, which does not need
        repository administrator access. Equal, higher, and custom grants are
        left unchanged, and each new grant is read back. Returns one record per
        requested team.
    .PARAMETER Organization
        Organization that owns the repository and teams.
    .PARAMETER Repository
        Repository name without the organization.
    .PARAMETER Team
        Objects with Slug and Permission (pull, triage, push, maintain, or admin).
    .PARAMETER PlanOnly
        Report the grants that are needed without changing access.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Organization,

        [Parameter(Mandatory)]
        [string] $Repository,

        [Parameter(Mandatory)]
        [object[]] $Team,

        [switch] $PlanOnly
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $rank = [ordered]@{ admin = 5; maintain = 4; push = 3; triage = 2; pull = 1 }
    $readPermission = {
        param([string] $Slug)
        $access = Invoke-AvmGitHubApi -Endpoint "orgs/$Organization/teams/$Slug/repos/$Organization/$Repository" `
            -Accept 'application/vnd.github.v3.repository+json' -AllowNotFound
        if ($null -eq $access) {
            return $null
        }
        if ($access['permissions'] -is [System.Collections.IDictionary]) {
            foreach ($name in $rank.Keys) {
                if ($access['permissions'][$name] -eq $true) {
                    return $name
                }
            }
        }
        return 'unknown'
    }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $Team) {
        $requested = [string]$entry.Permission
        if (-not $rank.Contains($requested)) {
            throw [System.ArgumentException]::new("Unsupported team permission '$requested'.")
        }
        $previous = & $readPermission ([string]$entry.Slug)
        $satisfied = $null -ne $previous -and (-not $rank.Contains($previous) -or $rank[$previous] -ge $rank[$requested])
        $status = if ($satisfied) {
            'unchanged'
        }
        elseif (-not $PlanOnly -and
            $PSCmdlet.ShouldProcess("$Organization/$Repository", "Grant team $($entry.Slug) $requested access")) {
            $null = Invoke-AvmGitHubApi -Method PUT `
                -Endpoint "orgs/$Organization/teams/$($entry.Slug)/repos/$Organization/$Repository" `
                -Body @{ permission = $requested }
            $current = & $readPermission ([string]$entry.Slug)
            if ($null -eq $current -or ($rank.Contains($current) -and $rank[$current] -lt $rank[$requested])) {
                throw [System.InvalidOperationException]::new(
                    "Could not verify $requested access for team $($entry.Slug) on $Organization/$Repository.")
            }
            'granted'
        }
        else {
            'planned'
        }
        $results.Add([pscustomobject][ordered]@{
                Slug       = [string]$entry.Slug
                Permission = $requested
                Previous   = $previous
                Status     = $status
            })
    }
    return $results.ToArray()
}
