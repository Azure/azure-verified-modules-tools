function Get-AvmReleaseActorAuthorization {
    <#
    .SYNOPSIS
        Check an actor against the authorisation facts.

    .DESCRIPTION
        Looks up the actor's team slugs in the normalised authorisation facts and calls Test-AvmReleaseActorAuthorized. Use it wherever the decision engine accepts a command, an opt-in, or a label correction.

    .PARAMETER Actor
        The GitHub login of the user who acted.

    .PARAMETER Authorization
        The Authorization entry from ConvertTo-AvmReleaseFacts.

    .EXAMPLE
        Get-AvmReleaseActorAuthorization -Actor 'alice' -Authorization $facts.Authorization

        Returns the authorisation result for alice.

    .OUTPUTS
        Ordered dictionary with Authorized, Reason, and MatchedEntry.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Actor,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Authorization
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $teams = @()
    if (-not [string]::IsNullOrWhiteSpace($Actor) -and $Authorization['ActorTeams'].ContainsKey($Actor)) {
        $teams = @($Authorization['ActorTeams'][$Actor])
    }
    return Test-AvmReleaseActorAuthorized -Actor $Actor -Owners $Authorization['Owners'] -ActorTeams $teams -CoreTeam $Authorization['CoreTeam']
}
