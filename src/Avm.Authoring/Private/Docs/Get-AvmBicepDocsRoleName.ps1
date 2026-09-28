function Get-AvmBicepDocsRoleName {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Template,

        [Parameter(Mandatory)]
        [string] $SourcePath
    )

    Set-StrictMode -Version 3.0
    $roles = [System.Collections.Generic.List[object]]::new()
    $candidates = [System.Collections.Generic.List[object]]::new()
    $candidates.Add([pscustomobject]@{ Identifier = ''; Template = $Template })
    foreach ($entry in @(Get-AvmBicepDocsCompiledResource -Template $Template)) {
        $resource = $entry.Resource
        if ($resource['type'] -cne 'Microsoft.Resources/deployments') {
            continue
        }
        $properties = $resource['properties']
        if ($properties -is [System.Collections.IDictionary] -and
            $properties['template'] -is [System.Collections.IDictionary]) {
            $candidates.Add([pscustomobject]@{
                    Identifier = $entry.Identifier
                    Template   = $properties['template']
                })
        }
    }

    foreach ($candidate in $candidates) {
        $variables = $candidate.Template['variables']
        if ($variables -isnot [System.Collections.IDictionary] -or
            -not $variables.Contains('builtInRoleNames')) {
            continue
        }
        $builtIn = $variables['builtInRoleNames']
        if ($builtIn -isnot [System.Collections.IDictionary]) {
            throw [AvmConfigurationException]::new(
                "Compiled Bicep builtInRoleNames must be a JSON object in '$SourcePath'.")
        }
        $names = @($builtIn.psbase.Keys)
        $roles.Add([pscustomobject]@{
                Identifier = [string]$candidate.Identifier
                Names      = $names
            })
    }

    Write-Output -NoEnumerate -InputObject $roles.ToArray()
}
