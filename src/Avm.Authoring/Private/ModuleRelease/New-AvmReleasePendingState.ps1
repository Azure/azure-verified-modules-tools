function New-AvmReleasePendingState {
    <#
    .SYNOPSIS
        Create an empty pending-release section for release state.

    .DESCRIPTION
        Returns the pending section of state.json with no pull requests, no release request, and no release-notes edits. The release engine uses it for new state and to reset the pending release after a publication cutoff.

    .EXAMPLE
        New-AvmReleasePendingState

        Returns an empty pending section.

    .OUTPUTS
        Ordered dictionary.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Returns an in-memory document and changes no system state.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    return [ordered]@{
        pullRequests   = @()
        releaseRequest = $null
        notes          = [ordered]@{
            commentary       = $null
            breakingOverride = $null
        }
    }
}
