function Get-AvmBicepRunOwnership {
    <#
    .SYNOPSIS
        Classify the e2e run-ownership tag in a tag dictionary.
    .DESCRIPTION
        State is None when no key matches the ownership tag case-insensitively,
        Ambiguous when several keys match or the only key has different casing,
        Owned when the exact key holds RunId, and Foreign otherwise. Value is the
        single matching key's value, or $null when there is not exactly one.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Tags,

        [Parameter(Mandatory)]
        [string] $RunId
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $tagName = (Get-AvmBicepConfiguration)['e2e']['ownershipTag']
    $keys = @()
    if ($Tags -is [System.Collections.IDictionary]) {
        $keys = @($Tags.Keys | Where-Object { $_ -is [string] -and $_ -ieq $tagName })
    }
    $value = $null
    if ($keys.Count -eq 1) {
        $value = $Tags[$keys[0]]
    }
    $state = if ($keys.Count -eq 0) {
        'None'
    }
    elseif ($keys.Count -gt 1 -or $keys[0] -cne $tagName) {
        'Ambiguous'
    }
    elseif ($value -is [string] -and $value -ceq $RunId) {
        'Owned'
    }
    else {
        'Foreign'
    }
    return [pscustomobject]@{
        State = $state
        Value = $value
    }
}