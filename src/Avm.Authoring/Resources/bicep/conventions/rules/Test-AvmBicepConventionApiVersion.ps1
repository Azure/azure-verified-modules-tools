function Test-AvmBicepConventionApiVersion {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Modules,

        # Provider API-version catalogue from Get-AvmBicepApiSpecList, fetched before the suite runs.
        [AllowNull()]
        [System.Collections.IDictionary] $ApiSpecs,

        # Why the catalogue could not be fetched; reported instead of silently passing.
        [string] $ApiSpecsUnavailableReason = ''
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $issues = [System.Collections.Generic.List[object]]::new()
    if ($Modules.Count -eq 0) {
        return $issues.ToArray()
    }
    if (-not [string]::IsNullOrEmpty($ApiSpecsUnavailableReason)) {
        $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $Root `
                    -Code 'avm.bicep.api-specs-unavailable' `
                    -Message $ApiSpecsUnavailableReason))
        return $issues.ToArray()
    }
    if ($null -eq $ApiSpecs) {
        throw [System.ArgumentException]::new('ApiSpecs or ApiSpecsUnavailableReason is required when modules are compiled.')
    }
    $specs = $ApiSpecs

    $extensionMappings = @(
        @{ Suffix = 'diagnosticSettings'; Provider = 'Microsoft.Insights' }
        @{ Suffix = 'locks'; Provider = 'Microsoft.Authorization' }
        @{ Suffix = 'roleAssignments'; Provider = 'Microsoft.Authorization' }
        @{ Suffix = 'privateEndpoints'; Provider = 'Microsoft.Network' }
    )
    foreach ($module in $Modules) {
        try {
            $resources = @(Get-AvmBicepDocsCompiledResource -Template $module.Template)
        }
        catch [AvmConfigurationException], [System.Management.Automation.RuntimeException] {
            $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $module.Path `
                        -Code 'avm.bicep.api-resources-uninspectable' `
                        -Message "Cannot enumerate compiled resources for API-version checks: $($_.Exception.Message)"))
            continue
        }
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($entry in $resources) {
            $resource = $entry.Resource
            if ($resource -isnot [System.Collections.IDictionary]) {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $module.Path `
                            -Code 'avm.bicep.api-resource-invalid' `
                            -Message 'A compiled resource must be an object for API-version checks.'))
                continue
            }
            $type = $resource['type']
            if ($type -ceq 'Microsoft.Resources/deployments') {
                continue
            }
            $api = $resource['apiVersion']
            $date = [datetime]::MinValue
            if ($type -isnot [string] -or $type -cnotmatch '^[A-Za-z0-9.-]+(?:/[A-Za-z0-9.-]+)+\z') {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $module.Path `
                            -Code 'avm.bicep.api-resource-invalid' `
                            -Message 'A compiled resource has no inspectable type for API-version checks.'))
                continue
            }
            if ($api -isnot [string] -or $api -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}(?:-[A-Za-z0-9-]+)?\z' -or
                -not [datetime]::TryParseExact($api.Substring(0, 10), 'yyyy-MM-dd',
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::None, [ref]$date)) {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $module.Path `
                            -Code 'avm.bicep.api-version-invalid' `
                            -Message "A compiled resource of type '$type' has no inspectable apiVersion."))
                continue
            }
            if (-not $seen.Add("$type|$api")) {
                continue
            }
            $parts = $type.Split('/')
            $provider = $parts[0]
            $resourceType = $parts[1..($parts.Length - 1)] -join '/'
            $extension = @($extensionMappings | Where-Object {
                    $type.EndsWith("/$($_.Suffix)", [System.StringComparison]::OrdinalIgnoreCase)
                })
            if ($extension.Count -eq 1) {
                $provider = $extension[0].Provider
                $resourceType = $extension[0].Suffix
            }

            $providers = @($specs.Keys | Where-Object { $_ -eq $provider })
            if ($providers.Count -eq 0) {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $module.Path `
                            -Code 'avm.bicep.api-provider-unknown' -Severity warning `
                            -Message "API specifications do not list provider '$provider' for '$type'. Update the registry API-specification list."))
                continue
            }
            if ($providers.Count -ne 1 -or $specs[$providers[0]] -isnot [System.Collections.IDictionary]) {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $module.Path `
                            -Code 'avm.bicep.api-specs-invalid' `
                            -Message "API specifications for '$provider' are ambiguous or malformed."))
                continue
            }
            $providerSpecs = $specs[$providers[0]]
            $types = @($providerSpecs.Keys | Where-Object { $_ -eq $resourceType })
            if ($types.Count -eq 0) {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $module.Path `
                            -Code 'avm.bicep.api-type-unknown' -Severity warning `
                            -Message "API specifications do not list '$provider/$resourceType' for '$type'. Update the registry API-specification list."))
                continue
            }
            if ($types.Count -ne 1 -or $providerSpecs[$types[0]] -isnot [array] -or
                $providerSpecs[$types[0]].Count -eq 0) {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $module.Path `
                            -Code 'avm.bicep.api-specs-invalid' `
                            -Message "API specifications for '$provider/$resourceType' need a nonempty version array."))
                continue
            }

            $available = $providerSpecs[$types[0]]
            $unique = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            $valid = $true
            foreach ($version in $available) {
                $releaseDate = [datetime]::MinValue
                if ($version -isnot [string] -or
                    $version -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}(?:-[A-Za-z0-9-]+)?\z' -or
                    -not [datetime]::TryParseExact($version.Substring(0, 10), 'yyyy-MM-dd',
                        [Globalization.CultureInfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]::None, [ref]$releaseDate) -or
                    -not $unique.Add($version)) {
                    $valid = $false
                    break
                }
            }
            if (-not $valid) {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $module.Path `
                            -Code 'avm.bicep.api-specs-invalid' `
                            -Message "API specifications for '$provider/$resourceType' contain an invalid or duplicate version."))
                continue
            }

            $ordered = @($available | Sort-Object -Culture 'en-US')
            $recent = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            foreach ($version in @($ordered | Select-Object -Last 5) +
                @($ordered | Where-Object { $_ -notlike '*-preview' } | Select-Object -Last 5)) {
                $null = $recent.Add($version)
            }
            $approved = @($recent | Sort-Object -Culture 'en-US' -Descending)
            if (-not $recent.Contains($api)) {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $module.Path `
                            -Code 'avm.bicep.api-version-outdated' -Severity warning `
                            -Message "Resource '$type' uses '$api'; recent approved versions for '$provider/$resourceType' are $($approved -join ', ')."))
            }
            elseif ($approved.Count -gt 1 -and $api -ceq $approved[-1]) {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $module.Path `
                            -Code 'avm.bicep.api-version-near-expiry' -Severity warning `
                            -Message "Resource '$type' uses the oldest approved API version '$api'; consider $($approved[0..($approved.Count - 2)] -join ', ')."))
            }
        }
    }
    return $issues.ToArray()
}
