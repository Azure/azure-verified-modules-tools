function New-AvmReleaseState {
    <#
    .SYNOPSIS
        Create an empty release state document for a repository.

    .DESCRIPTION
        Returns a schema version 1 state.json document with nothing pending, no hold, no cursors, and no publication in progress. The document exists only in memory. Writing it to the avm-release-state branch happens in a later step.

    .PARAMETER Repository
        The repository as 'owner/name'.

    .EXAMPLE
        New-AvmReleaseState -Repository 'Azure/terraform-azurerm-avm-res-example'

        Returns an empty state document.

    .OUTPUTS
        Ordered dictionary.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Returns an in-memory document and changes no system state.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$')]
        [string] $Repository
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    return [ordered]@{
        schemaVersion = (Get-AvmReleasePolicy).SchemaVersion
        repository    = $Repository
        releaseIssue  = $null
        commentCursor = $null
        labelCursor   = $null
        hold          = $null
        pending       = (New-AvmReleasePendingState)
        publication   = $null
    }
}
