function ConvertTo-AvmReleaseJson {
    <#
    .SYNOPSIS
        Serialise release state or a release record as canonical JSON.

    .DESCRIPTION
        Validates the document first and throws when it is damaged, so damaged state is never written. The output sorts object keys by ordinal comparison, uses LF line endings, and ends with one newline. The same document always produces the same text, which keeps state-branch diffs small and makes unchanged state easy to detect.

    .PARAMETER InputObject
        The state or record document.

    .PARAMETER Kind
        The document kind: State or Record.

    .EXAMPLE
        ConvertTo-AvmReleaseJson -InputObject (New-AvmReleaseState -Repository 'Azure/terraform-azurerm-avm-res-example') -Kind State

        Returns the canonical JSON for an empty state.

    .OUTPUTS
        String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory)]
        [ValidateSet('State', 'Record')]
        [string] $Kind
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $issues = @(
        if ($Kind -eq 'State') {
            Test-AvmReleaseState -State $InputObject
        }
        else {
            Test-AvmReleaseRecord -Record $InputObject
        }
    )
    if ($issues.Count -gt 0) {
        throw [System.ArgumentException]::new("Release $($Kind.ToLowerInvariant()) is invalid: $($issues -join ' ')")
    }

    $sorted = Copy-AvmReleaseValue -Value $InputObject -SortKeys
    $json = ConvertTo-Json -InputObject $sorted -Depth 32
    return (($json -replace "`r`n?", "`n").TrimEnd("`n") + "`n")
}
