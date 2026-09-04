function Get-AvmTerraformCredentialledDataSource {
    <#
    .SYNOPSIS
        Find data sources in a Terraform directory that need a real Azure
        credential to read.

    .DESCRIPTION
        A create-only plan against empty state makes no Azure API call, so the
        policy stage can plan with a synthetic token. Data sources are the
        exception: Terraform reads them during plan whenever their
        configuration is fully known, and '-refresh=false' does not suppress
        that, so a data source backed by a live API fails without a real
        credential.

        This detects those declarations so the caller can report the example
        as needing a credentialled run instead of surfacing a raw provider
        authentication error.

        Detection is by provider prefix with an allow-list of types that are
        known to resolve locally:

          - azurerm_client_config / azapi_client_config are derived from the
            token claims, never from an API read.
          - azapi_resource_id parses and builds resource IDs locally.

        Unknown types from a credentialled provider are treated as needing a
        credential. That is the safe direction: the alternative is a confusing
        provider error deep inside terraform plan.

        Comments are stripped before matching so commented-out declarations,
        which are common in AVM examples, are not reported.

    .PARAMETER Path
        Directory to scan. Only the '*.tf' files directly in it are read;
        callers scan module directories individually.

    .OUTPUTS
        pscustomobject with DataSourceAddress, Type and File for each
        declaration. 'Address' is deliberately avoided as a property name
        because it collides with a built-in member on some pipeline objects.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    # Providers whose data sources call a live API. Anything outside this set
    # (local, random, null, time, tls, ...) resolves without a credential.
    $credentialledPrefixes = @(
        'azurerm_'
        'azapi_'
        'azuread_'
        'azuredevops_'
        'azurestack_'
    )
    $locallyResolved = @(
        'azurerm_client_config'
        'azapi_client_config'
        'azapi_resource_id'
    )

    $found = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $found.ToArray()
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $Path -File -Filter '*.tf' -ErrorAction Stop |
            Sort-Object FullName)) {
        $content = Remove-AvmHclComment -Content ([System.IO.File]::ReadAllText($file.FullName))

        foreach ($match in [regex]::Matches(
                $content,
                '(?m)^\s*data\s+"(?<type>[A-Za-z][A-Za-z0-9_-]*)"\s+"(?<name>[A-Za-z_][A-Za-z0-9_-]*)"',
                [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
            $type = $match.Groups['type'].Value
            if ($type -in $locallyResolved) {
                continue
            }
            if (-not ($credentialledPrefixes | Where-Object { $type.StartsWith($_, [System.StringComparison]::Ordinal) })) {
                continue
            }

            $found.Add([pscustomobject][ordered]@{
                    DataSourceAddress = ('data.{0}.{1}' -f $type, $match.Groups['name'].Value)
                    Type              = $type
                    File              = $file.Name
                })
        }
    }

    return $found.ToArray()
}
