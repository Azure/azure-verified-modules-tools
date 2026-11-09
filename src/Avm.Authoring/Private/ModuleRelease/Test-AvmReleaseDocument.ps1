function Test-AvmReleaseDocument {
    <#
    .SYNOPSIS
        Check a release state or record document against its JSON Schema.

    .DESCRIPTION
        Serialises the document and validates it with Test-Json against avm-release-state.schema.json or avm-release-record.schema.json in Resources/Schemas/v1. The schema rejects missing, unknown, and wrongly typed properties, and malformed timestamps, versions, labels, and commit SHAs.

        Test-Json describes only failures at the top level of the document. A failure deeper in the document returns the summary message alone, so open the document against the schema file in an editor to find it.

        JSON Schema patterns cannot reject impossible calendar dates such as 30 February. Every timestamp property is therefore also parsed as a real UTC time.

    .PARAMETER Document
        The parsed state or record document.

    .PARAMETER Kind
        The document kind: State or Record.

    .EXAMPLE
        Test-AvmReleaseDocument -Document (New-AvmReleaseState -Repository 'Azure/terraform-azurerm-avm-res-example') -Kind State

        Returns no issues.

    .OUTPUTS
        String. One message for each problem found.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Document,

        [Parameter(Mandatory)]
        [ValidateSet('State', 'Record')]
        [string] $Kind
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $name = "avm-release-$($Kind.ToLowerInvariant()).schema.json"
    $schemaPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'Resources', 'Schemas', 'v1', $name
    $json = ConvertTo-Json -InputObject $Document -Depth 32 -Compress

    $schemaErrors = @()
    if (-not (Test-Json -Json $json -Schema (Get-Content -LiteralPath $schemaPath -Raw) -ErrorVariable schemaErrors -ErrorAction SilentlyContinue)) {
        "`$: release $($Kind.ToLowerInvariant()) does not match $name."
        foreach ($schemaError in $schemaErrors) {
            "`$: $($schemaError.Exception.Message -replace '^The JSON is not valid with the schema: ', '')"
        }
        return
    }

    foreach ($match in [regex]::Matches($json, '"(?<key>[A-Za-z]*At|at|since)":"(?<value>[^"]*)"')) {
        $parsed = [System.DateTimeOffset]::MinValue
        if (-not [System.DateTimeOffset]::TryParseExact($match.Groups['value'].Value, "yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref] $parsed)) {
            "`$..$($match.Groups['key'].Value): '$($match.Groups['value'].Value)' is not a real UTC time."
        }
    }
}
