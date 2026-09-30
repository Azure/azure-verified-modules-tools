function Get-AvmBicepModuleInitializationPlan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [ValidateSet('resource', 'pattern', 'utility')]
        [string] $ModuleType,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $InputObject,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $AncestorInputObject,

        [switch] $ChildModule,

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $pathInfo = Get-AvmBicepScaffoldPath -Path $Path -ModuleType $ModuleType -ChildModule:$ChildModule
    $ancestors = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    if ($ChildModule) {
        $null = $ancestors.Add('.')
        for ($index = 1; $index -lt $pathInfo.ChildSegments.Count; $index++) {
            $null = $ancestors.Add(($pathInfo.ChildSegments[0..($index - 1)] -join '/'))
        }
    }
    $provided = [System.Collections.Generic.Dictionary[string, System.Collections.IDictionary]]::new(
        [System.StringComparer]::Ordinal)
    foreach ($key in $AncestorInputObject.Keys) {
        if ($key -isnot [string] -or -not $ancestors.Contains($key)) {
            throw [System.ArgumentException]::new(
                "AncestorInputObject key '$key' is not an exact root-relative ancestor path.")
        }
        if ($AncestorInputObject[$key] -isnot [System.Collections.IDictionary]) {
            throw [System.ArgumentException]::new(
                "AncestorInputObject value for '$key' must be a metadata dictionary.")
        }
        if (-not $provided.TryAdd($key, $AncestorInputObject[$key])) {
            throw [System.ArgumentException]::new("AncestorInputObject contains duplicate path '$key'.")
        }
    }

    $plans = [System.Collections.Generic.List[object]]::new()
    $plannedPrefixes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $modulePath = $pathInfo.RootModulePath
    $targetMetadata = $null
    for ($index = 0; $index -le $pathInfo.ChildSegments.Count; $index++) {
        if ($index -gt 0) {
            $modulePath = Join-Path -Path $modulePath -ChildPath $pathInfo.ChildSegments[$index - 1]
        }
        $relative = if ($index -eq 0) { '.' }
        else { $pathInfo.ChildSegments[0..($index - 1)] -join '/' }
        $isTarget = $index -eq $pathInfo.ChildSegments.Count
        $values = if ($isTarget) { $InputObject }
        elseif ($provided.ContainsKey($relative)) { $provided[$relative] }
        else { @{} }
        $isChild = $index -gt 0
        $sourcePath = Join-Path -Path $modulePath -ChildPath 'main.bicep'
        $metadataPath = Join-Path -Path $modulePath -ChildPath 'metadata.json'
        $metadataArgs = @{
            Path                   = $modulePath
            InputObject            = $values
            Ecosystem              = 'bicep'
            ModuleType             = $ModuleType
            ChildModule            = $isChild
            PreserveSourcePrefix   = (Test-Path -LiteralPath $sourcePath -PathType Leaf) -and
            -not (Test-Path -LiteralPath $metadataPath -PathType Leaf)
            KnownPrefix            = [string[]]@($plannedPrefixes)
            SkipModuleVersionCheck = $SkipModuleVersionCheck
        }
        if ($isChild -and -not (Test-Path -LiteralPath $sourcePath -PathType Leaf) -and
            -not (Test-Path -LiteralPath (Join-Path -Path $modulePath -ChildPath 'version.json') -PathType Leaf)) {
            $metadataArgs.TelemetryRequired = $false
        }
        try {
            $metadataPlan = Get-AvmModuleMetadataInitializationPlan @metadataArgs
            $scaffoldPlan = @(Get-AvmBicepScaffoldPlan -Path $modulePath -Metadata $metadataPlan.Metadata `
                    -ModuleType $ModuleType -ChildModule:$isChild)
        }
        catch {
            if (-not $isTarget) {
                throw [System.ArgumentException]::new(
                    "Cannot initialize ancestor '$relative' ($modulePath): $($_.Exception.Message)", $_.Exception)
            }
            throw
        }

        if ($metadataPlan.Plans.Count -gt 0) {
            $prefixes = @(
                if ($metadataPlan.Metadata.Contains('telemetryIdPrefix')) {
                    $metadataPlan.Metadata.telemetryIdPrefix
                }
                if ($metadataPlan.Metadata.Contains('alternativeTelemetryIdPrefixes')) {
                    foreach ($prefix in $metadataPlan.Metadata.alternativeTelemetryIdPrefixes) {
                        $prefix
                    }
                }
            )
            foreach ($prefix in $prefixes) {
                if ($prefix -and -not $plannedPrefixes.Add([string]$prefix)) {
                    throw [System.ArgumentException]::new(
                        "Telemetry prefix '$prefix' is repeated in the planned Bicep module chain.")
                }
            }
        }
        foreach ($item in $metadataPlan.Plans) {
            $plans.Add($item)
        }
        foreach ($item in $scaffoldPlan) {
            $plans.Add($item)
        }
        if ($isTarget) {
            $targetMetadata = $metadataPlan.Metadata
        }
    }

    return [pscustomobject][ordered]@{
        Root     = $pathInfo.RootModulePath
        Target   = $pathInfo.Path
        Metadata = $targetMetadata
        Plans    = $plans.ToArray()
    }
}
