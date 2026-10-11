function Get-AvmBicepApiVersionInput {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [object] $Module
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $resources = @()
    $readError = $null
    try { $resources = @(Get-AvmBicepDocsCompiledResource -Template $Module.Template) }
    catch [AvmConfigurationException], [System.Management.Automation.RuntimeException] {
        $readError = $_.Exception.Message
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $cases = @(foreach ($entry in $resources) {
            $resource = $entry.Resource
            $type = $null
            $api = $null
            if ($resource -is [System.Collections.IDictionary]) {
                $type = $resource['type']
                $api = $resource['apiVersion']
                if ($type -ceq 'Microsoft.Resources/deployments') { continue }
                if ($type -is [string] -and $api -is [string] -and -not $seen.Add("$type|$api")) { continue }
            }
            @{ Resource = $resource; Type = $type; Api = $api }
        })
    return @{ IssuePath = $Module.Path; Resources = $cases; ReadError = $readError }
}
