function ConvertFrom-AvmMetadataJson {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Json
    )

    ConvertFrom-AvmStrictJson -Json $Json -Description Metadata
}
