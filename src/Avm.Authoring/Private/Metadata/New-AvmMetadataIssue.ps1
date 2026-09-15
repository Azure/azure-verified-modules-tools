function New-AvmMetadataIssue {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory diagnostic; no state is changed.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Code,

        [Parameter(Mandatory)]
        [string] $Message,

        [string] $File = 'metadata.json'
    )

    [pscustomobject][ordered]@{
        File     = $File
        Line     = 1
        Column   = 1
        Severity = 'error'
        Code     = $Code
        Message  = $Message
    }
}
