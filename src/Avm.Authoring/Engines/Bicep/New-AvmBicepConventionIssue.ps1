function New-AvmBicepConventionIssue {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs a diagnostic in memory.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Code,

        [Parameter(Mandatory)]
        [string] $Message,

        [int] $Line = 0
    )

    [pscustomobject][ordered]@{
        File     = [System.IO.Path]::GetRelativePath($Root, $Path).Replace('\', '/')
        Line     = $Line
        Column   = if ($Line -gt 0) { 1 } else { 0 }
        Severity = 'error'
        Code     = $Code
        Message  = $Message
    }
}
