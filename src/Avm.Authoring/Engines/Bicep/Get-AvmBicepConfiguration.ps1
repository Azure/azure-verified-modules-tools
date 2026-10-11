function Get-AvmBicepConfiguration {
    <#
    .SYNOPSIS
        Return the packaged Bicep settings from Resources/bicep/settings.json.
    .DESCRIPTION
        Holds the e2e ownership tag and run ID pattern plus the registry module
        exemptions used by the convention checks. Read once per session.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param()

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not (Get-Variable -Name AvmBicepConfiguration -Scope Script -ErrorAction Ignore) -or
        $null -eq $script:AvmBicepConfiguration) {
        $path = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath @('..', 'Resources', 'bicep', 'settings.json')
        $script:AvmBicepConfiguration = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable
    }
    return $script:AvmBicepConfiguration
}