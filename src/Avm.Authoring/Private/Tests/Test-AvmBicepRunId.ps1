function Test-AvmBicepRunId {
    <#
    .SYNOPSIS
        Return whether a value is a well-formed Bicep e2e run ID string.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [object] $RunId
    )

    Set-StrictMode -Version 3.0
    return $RunId -is [string] -and $RunId -cmatch (Get-AvmBicepConfiguration)['e2e']['runIdPattern']
}