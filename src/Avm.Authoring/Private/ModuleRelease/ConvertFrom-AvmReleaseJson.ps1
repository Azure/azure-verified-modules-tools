function ConvertFrom-AvmReleaseJson {
    <#
    .SYNOPSIS
        Parse and validate release state or a release record.

    .DESCRIPTION
        Parses strict JSON, rejecting duplicate keys, and validates the document with Test-AvmReleaseState or Test-AvmReleaseRecord. It never throws for damaged input. Instead it reports the damage, so the caller can stop publication and notify a maintainer.

    .PARAMETER Json
        The JSON text.

    .PARAMETER Kind
        The document kind: State or Record.

    .PARAMETER Repository
        For state, the expected repository as 'owner/name'.

    .EXAMPLE
        ConvertFrom-AvmReleaseJson -Json $text -Kind State -Repository 'Azure/terraform-azurerm-avm-res-example'

        Returns IsValid, Document, and Issues.

    .OUTPUTS
        Ordered dictionary with IsValid, Document (null when the JSON cannot be parsed), and Issues.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Json,

        [Parameter(Mandatory)]
        [ValidateSet('State', 'Record')]
        [string] $Kind,

        [string] $Repository
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $document = $null
    try {
        if ([string]::IsNullOrWhiteSpace($Json)) {
            throw [System.ArgumentException]::new('The document is empty.')
        }
        $parsed = ConvertFrom-AvmStrictJson -Json $Json -Description "Release $($Kind.ToLowerInvariant())" -RejectCaseInsensitiveDuplicates
        $document = Copy-AvmReleaseValue -Value $parsed
    }
    catch [System.ArgumentException] {
        return [ordered]@{
            IsValid  = $false
            Document = $null
            Issues   = @("`$: $($_.Exception.Message)")
        }
    }

    $issues = @(
        if ($Kind -eq 'State') {
            Test-AvmReleaseState -State $document -Repository $Repository
        }
        else {
            Test-AvmReleaseRecord -Record $document
        }
    )

    return [ordered]@{
        IsValid  = $issues.Count -eq 0
        Document = $document
        Issues   = $issues
    }
}
