function Get-AvmTerraformCredentialledDataSource {
    <#
    .SYNOPSIS
        Find data sources that Terraform reads during plan and that need a
        real Azure credential to resolve.

    .DESCRIPTION
        A create-only plan against empty state makes no Azure API call, so the
        policy stage can plan with a synthetic token. Data sources are the
        exception: Terraform reads them during plan, and '-refresh=false' does
        not suppress that, so one backed by a live API fails without a real
        credential.

        Crucially, that only applies to data sources Terraform can read at
        plan time. A data source whose arguments reference a resource the
        configuration is about to create is deferred to apply and rendered as
        'will be read during apply', so it never executes during the policy
        plan. Verified against Terraform 1.15: a listKeys action whose
        resource_id comes from a resource in the same configuration plans
        cleanly on a synthetic credential.

        A declaration is therefore reported only when both hold:

          - its type comes from a provider that authenticates to Azure, and
          - every argument is known at plan time, so nothing defers the read.

        An argument referencing a managed resource, a module output or another
        data source defers the read, as does 'depends_on'. 'var.' and 'local.'
        do not, because they are known during plan. Locals are treated
        conservatively as known; a local built from a resource attribute would
        be a false positive, which is the safe direction.

        Types known to resolve without an API call are allow-listed:
        azurerm_client_config and azapi_client_config come from the token
        claims, azapi_resource_id parses IDs locally, and
        azuread_application_published_app_ids returns a static map compiled
        into the provider.

        Unknown types from a credentialled provider are treated as needing a
        credential. That is the safe direction: the alternative is a confusing
        provider error deep inside terraform plan.

        Comments and heredoc bodies are stripped before matching, so
        commented-out declarations, which are common in AVM examples, are not
        reported.

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
    # (local, random, null, time, tls, http, ...) either needs no credential
    # or is not an Azure concern.
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
        'azuread_application_published_app_ids'
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
                '(?m)^\s*data\s+"(?<type>[A-Za-z][A-Za-z0-9_-]*)"\s+"(?<name>[A-Za-z_][A-Za-z0-9_-]*)"\s*\{',
                [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
            $type = $match.Groups['type'].Value
            if ($type -in $locallyResolved) {
                continue
            }
            if (-not ($credentialledPrefixes | Where-Object { $type.StartsWith($_, [System.StringComparison]::Ordinal) })) {
                continue
            }

            $openBrace = $match.Index + $match.Value.LastIndexOf('{')
            $body = Get-AvmTerraformBlockBody -Content $content -OpenBraceIndex $openBrace
            if (Test-AvmTerraformReadDeferred -Body $body) {
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
