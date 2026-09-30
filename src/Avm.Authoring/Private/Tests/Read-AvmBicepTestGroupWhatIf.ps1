function Read-AvmBicepTestGroupWhatIf {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Output,

        [Parameter(Mandatory)]
        [string] $File,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Template,

        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $ResourceGroupName,

        [Parameter(Mandatory)]
        [string] $RunId
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    Assert-AvmBicepTestIsolation -Template $Template -SourcePath $File
    $types = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $literalNames = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.HashSet[string]]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $dynamicNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $templates = [System.Collections.Generic.Stack[object]]::new()
    $templates.Push([pscustomobject]@{ Template = $Template; LiteralNames = $true })
    while ($templates.Count -gt 0) {
        $current = $templates.Pop()
        foreach ($resource in $current.Template['resources']) {
            $type = [string]$resource['type']
            $null = $types.Add($type)
            if (-not $literalNames.ContainsKey($type)) {
                $literalNames[$type] = [System.Collections.Generic.HashSet[string]]::new(
                    [System.StringComparer]::OrdinalIgnoreCase)
            }
            $name = [string]$resource['name']
            if ($current.LiteralNames -and -not [string]::IsNullOrWhiteSpace($name) -and
                -not $name.StartsWith('[', [System.StringComparison]::Ordinal)) {
                $null = $literalNames[$type].Add($name)
            }
            else {
                $null = $dynamicNames.Add($type)
            }
            if ($resource.Contains('resources') -and $resource['resources'].Count -gt 0) {
                $templates.Push([pscustomobject]@{
                        Template     = @{ resources = $resource['resources'] }
                        LiteralNames = $false
                    })
            }
            if ($resource['type'] -ieq 'Microsoft.Resources/deployments') {
                $templates.Push([pscustomobject]@{
                        Template     = $resource['properties']['template']
                        LiteralNames = $true
                    })
            }
        }
    }

    $changes = @(Read-AvmBicepWhatIfChange -Output $Output -File $File)
    if ($changes.Count -eq 0) {
        throw [AvmConfigurationException]::new(
            "Bicep e2e what-if for '$File' predicted no resources; deployment was refused.")
    }
    $plan = $Output | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $resources = [System.Collections.Generic.List[object]]::new()
    $deployments = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $changes.Count; $index++) {
        $change = $changes[$index]
        if ($change.ChangeType -cne 'Create' -or -not $seen.Add($change.ResourceId)) {
            throw [AvmConfigurationException]::new(
                "Bicep e2e what-if for '$File' contains a non-Create or duplicate change at '$($change.ResourceId)'.")
        }
        $resource = Get-AvmBicepTestGroupResource -ResourceId $change.ResourceId `
            -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -RunId $RunId
        if (-not $types.Contains($resource.Type)) {
            throw [AvmConfigurationException]::new(
                "Bicep e2e what-if for '$File' predicts undeclared resource type '$($resource.Type)'.")
        }
        if (-not $dynamicNames.Contains($resource.Type) -and
            -not $literalNames[$resource.Type].Contains($resource.Name)) {
            throw [AvmConfigurationException]::new(
                "Bicep e2e what-if for '$File' predicts undeclared literal name '$($resource.Name)' for '$($resource.Type)'.")
        }
        $after = $plan['changes'][$index]['after']
        if ($after -isnot [System.Collections.IDictionary] -or
            -not [string]::Equals([string]$after['name'], $resource.Name,
                [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$after['type'], $resource.Type,
                [System.StringComparison]::OrdinalIgnoreCase) -or
            ($after.Contains('id') -and
            -not [string]::Equals([string]$after['id'], $resource.Id,
                [System.StringComparison]::OrdinalIgnoreCase))) {
            throw [AvmConfigurationException]::new(
                "Bicep e2e what-if for '$File' did not expand '$($resource.Id)' into its exact full resource payload.")
        }
        foreach ($property in @('scope', 'subscriptionId', 'resourceGroup', 'managementGroupId', 'tenantId')) {
            if ($after.Contains($property)) {
                throw [AvmConfigurationException]::new(
                    "Bicep e2e what-if for '$File' returned a cross-scope $property for '$($resource.Id)'.")
            }
        }
        $tags = $after['tags']
        if ($null -ne $tags -and $tags -isnot [System.Collections.IDictionary]) {
            throw [AvmConfigurationException]::new(
                "Bicep e2e what-if for '$File' returned uninspectable ownership tags for '$($resource.Id)'.")
        }
        if ($tags -is [System.Collections.IDictionary]) {
            $ownerKeys = @($tags.Keys | Where-Object { $_ -is [string] -and $_ -ieq 'avm-e2e-run-id' })
            if ($ownerKeys.Count -gt 1 -or
                ($ownerKeys.Count -eq 1 -and
                ($ownerKeys[0] -cne 'avm-e2e-run-id' -or
                $tags['avm-e2e-run-id'] -cne $RunId))) {
                throw [AvmConfigurationException]::new(
                    "Bicep e2e what-if for '$File' returned foreign or ambiguous ownership tags.")
            }
        }
        if ($resource.Kind -eq 'Deployment') {
            $properties = $after['properties']
            if ($properties -isnot [System.Collections.IDictionary] -or
                $properties['mode'] -isnot [string] -or
                $properties['mode'] -cne 'Incremental' -or
                $properties['template'] -isnot [System.Collections.IDictionary]) {
                throw [AvmConfigurationException]::new(
                    "Bicep e2e what-if for '$File' did not expand an incremental inline deployment.")
            }
            Assert-AvmBicepTestIsolation -Template $properties['template'] -SourcePath $File
            $deployments.Add($resource)
        }
        else {
            $resources.Add($resource)
        }
    }
    if ($resources.Count -eq 0) {
        throw [AvmConfigurationException]::new(
            "Bicep e2e what-if for '$File' predicted no inspectable group resources.")
    }
    return [pscustomobject]@{
        Resources   = $resources.ToArray()
        Deployments = $deployments.ToArray()
        Changes     = $changes
    }
}
