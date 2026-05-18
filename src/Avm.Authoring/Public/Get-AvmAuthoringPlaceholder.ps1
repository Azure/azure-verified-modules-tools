function Get-AvmAuthoringPlaceholder {
    <#
    .SYNOPSIS
        Returns a placeholder message confirming the Avm.Authoring module is installed.

    .DESCRIPTION
        The first PSGallery release of Avm.Authoring (0.0.1) was a name-reservation
        placeholder that exported only this function. The function is retained for
        backward compatibility while the module grows out its real verb surface.

    .EXAMPLE
        PS> Get-AvmAuthoringPlaceholder
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    [pscustomobject]@{
        Module     = 'Avm.Authoring'
        Version    = (Get-Module -Name Avm.Authoring).Version
        Status     = 'Placeholder - name reserved on PSGallery'
        Repository = 'https://github.com/Azure/azure-verified-modules-tools'
        Message    = 'A functional release will follow. See the repository roadmap for details.'
    }
}
