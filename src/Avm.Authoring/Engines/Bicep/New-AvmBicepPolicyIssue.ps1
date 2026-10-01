function New-AvmBicepPolicyIssue {
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

        [ValidateSet('error', 'warning')]
        [string] $Severity = 'error',

        [string] $Baseline = '',

        [string] $RuleName = '',

        [string] $TargetType = ''
    )

    $issue = New-AvmBicepConventionIssue -Root $Root -Path $Path -Code $Code `
        -Message $Message -Severity $Severity
    $issue | Add-Member -NotePropertyName Baseline -NotePropertyValue $Baseline
    $issue | Add-Member -NotePropertyName RuleName -NotePropertyValue $RuleName
    $issue | Add-Member -NotePropertyName TargetType -NotePropertyValue $TargetType
    return $issue
}
