function Test-AvmReleaseActorAuthorized {
    <#
    .SYNOPSIS
        Decide whether a GitHub user may control releases for a module repository.

    .DESCRIPTION
        A user may post release commands, opt in routine bot pull requests, and correct version labels after merge only when one of these is true:

        - The user is listed in the owners array of the repository's metadata.json.
        - The user belongs to a team listed there as '@org/team'.
        - The user belongs to the core AVM team.

        Write or triage access alone never authorises a user. Bot accounts are never authorised. Matching is case-insensitive, and a leading '@' is ignored. The caller fetches team membership. This function only compares the values.

    .PARAMETER Actor
        The GitHub login of the user who acted.

    .PARAMETER Owners
        The owners entries from metadata.json. User entries are logins. Team entries are '@org/team'. Null means the owners are unknown, so only the core team can act.

    .PARAMETER ActorTeams
        The teams the actor belongs to, as 'org/team' slugs.

    .PARAMETER CoreTeam
        The core AVM team as 'org/team'.

    .EXAMPLE
        Test-AvmReleaseActorAuthorized -Actor 'dave' -Owners @('alice', '@Azure/example-owners') -ActorTeams @('Azure/example-owners') -CoreTeam 'Azure/azure-verified-modules-engineering-owners'

        Returns Authorized $true and Reason 'owner-team'.

    .OUTPUTS
        Ordered dictionary with Authorized, Reason ('owner', 'owner-team', 'core-team', 'not-owner', 'bot', or 'missing-actor'), and MatchedEntry.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Actor,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Owners,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $ActorTeams = @(),

        [Parameter(Mandatory)]
        [string] $CoreTeam
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $core = $CoreTeam.Trim().TrimStart('@')
    if ($core -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]*)/[A-Za-z0-9._-]+$') {
        throw [System.ArgumentException]::new("CoreTeam '$CoreTeam' must be an 'org/team' slug.")
    }

    $result = [ordered]@{
        Authorized   = $false
        Reason       = 'not-owner'
        MatchedEntry = $null
    }

    $login = ''
    if ($null -ne $Actor) {
        $login = $Actor.Trim().TrimStart('@')
    }
    if ($login.Length -eq 0) {
        $result.Reason = 'missing-actor'
        return $result
    }
    if ($login.EndsWith('[bot]', [System.StringComparison]::OrdinalIgnoreCase)) {
        $result.Reason = 'bot'
        return $result
    }

    $teams = @($ActorTeams | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim().TrimStart('@') })

    foreach ($entry in @($Owners | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $value = $entry.Trim().TrimStart('@')
        if ($value -notmatch '/' -and $value -eq $login) {
            $result.Authorized = $true
            $result.Reason = 'owner'
            $result.MatchedEntry = $entry
            return $result
        }
    }

    foreach ($entry in @($Owners | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $value = $entry.Trim().TrimStart('@')
        if ($value -match '/' -and @($teams | Where-Object { $_ -eq $value }).Count -gt 0) {
            $result.Authorized = $true
            $result.Reason = 'owner-team'
            $result.MatchedEntry = $entry
            return $result
        }
    }

    if (@($teams | Where-Object { $_ -eq $core }).Count -gt 0) {
        $result.Authorized = $true
        $result.Reason = 'core-team'
        $result.MatchedEntry = $core
    }

    return $result
}
