function Test-AvmMetadataResourceType {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $CanonicalType
    )

    return $CanonicalType -cmatch '^(Microsoft\.[A-Z]\w+|Oracle\.Database)(/[a-zA-Z]\w*)+$'
}
