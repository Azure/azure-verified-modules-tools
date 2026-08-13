function Get-AvmManagedFilesVersionPinPath {
    <#
    .SYNOPSIS
        Resolve the managed-files version pin path for a repository root.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Root
    )

    return (Join-Path (Join-Path $Root '.avm') 'managed-files-version.json')
}
