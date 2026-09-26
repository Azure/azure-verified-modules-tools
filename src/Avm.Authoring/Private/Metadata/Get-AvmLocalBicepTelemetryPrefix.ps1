function Get-AvmLocalBicepTelemetryPrefix {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $root = Get-AvmBicepMonorepoRoot -Path $Path
    if (-not $root) {
        return [string[]]@()
    }

    $context = [pscustomobject]@{ Root = $root; Kind = 'bicep-monorepo'; Ecosystem = 'bicep'; Scope = $null }
    $prefixes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($scope in @(Get-AvmMetadataScope -Context $context)) {
        $files = @(Get-ChildItem -LiteralPath $scope.Path -Force | Where-Object { $_.Name -ieq 'metadata.json' })
        if ($files.Count -eq 0) { continue }
        if ($files.Count -ne 1 -or $files[0].PSIsContainer -or $files[0].Name -cne 'metadata.json') {
            throw [System.ArgumentException]::new("Local metadata in '$($scope.Path)' must be exactly one file named metadata.json.")
        }
        $metadataPath = $files[0].FullName
        try {
            $json = Read-AvmMetadataJson -Path $metadataPath
            $metadata = ConvertFrom-AvmMetadataJson -Json $json
            $moduleType = Get-AvmMetadataModuleType -Context $context -Path $scope.Path -Metadata $metadata
            $validation = Test-AvmMetadataContent -Json $json -Ecosystem bicep -ModuleType $moduleType `
                -ChildModule:$scope.ChildModule `
                -TelemetryRequired (Test-AvmMetadataTelemetryRequired -Path $scope.Path -Ecosystem bicep `
                    -ModuleType $moduleType -ChildModule:$scope.ChildModule)
            if ($validation.Issues.Count -gt 0) {
                throw [System.ArgumentException]::new(($validation.Issues.Message -join ' '))
            }
        }
        catch [System.ArgumentException] {
            throw [System.ArgumentException]::new(
                "Cannot check telemetry prefix uniqueness: invalid local metadata '$metadataPath'. $($_.Exception.Message)", $_.Exception)
        }
        if ($metadata.Contains('telemetryIdPrefix')) {
            $null = $prefixes.Add([string]$metadata.telemetryIdPrefix)
        }
        if ($metadata.Contains('alternativeTelemetryIdPrefixes')) {
            foreach ($prefix in $metadata.alternativeTelemetryIdPrefixes) {
                $null = $prefixes.Add([string]$prefix)
            }
        }
    }
    return [string[]]@($prefixes)
}
