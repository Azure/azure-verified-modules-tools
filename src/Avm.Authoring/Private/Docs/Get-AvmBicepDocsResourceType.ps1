function Get-AvmBicepDocsResourceType {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Template
    )

    Set-StrictMode -Version 3.0
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $resources = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in @(Get-AvmBicepDocsCompiledResource -Template $Template)) {
        $resource = $entry.Resource
        $type = [string]$resource['type']
        $version = [string]$resource['apiVersion']
        if ($type -and $type -cne 'Microsoft.Resources/deployments' -and
            $seen.Add("$type`0$version")) {
            $resources.Add([pscustomobject]@{ Type = $type; ApiVersion = $version })
        }
    }

    return @($resources | Sort-Object -Culture 'en-US' -Property Type)
}
