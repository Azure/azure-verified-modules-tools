function Get-AvmRulesetOptOutRecordPath {
    <#
    .SYNOPSIS
        Return the path of the record that holds a repository's original global-rulesets-opt-out value.
    .DESCRIPTION
        The record lives in the user's Avm state folder while avm init has the
        property temporarily changed, so a later run can restore it.
    .PARAMETER Repository
        Repository as owner/name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Repository
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $folder = Join-Path -Path (Get-AvmFolder -Kind State) -ChildPath 'repository-init'
    return Join-Path -Path $folder -ChildPath (($Repository -replace '[^A-Za-z0-9._-]', '_') + '.ruleset-opt-out.json')
}
