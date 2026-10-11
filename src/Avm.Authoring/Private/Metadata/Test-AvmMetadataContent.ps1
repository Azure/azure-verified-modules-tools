function Test-AvmMetadataContent {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Json,
        [Parameter(Mandatory)][ValidateSet('bicep', 'terraform')][string] $Ecosystem,
        [Parameter(Mandatory)][ValidateSet('resource', 'pattern', 'utility')][string] $ModuleType,
        [switch] $ChildModule,
        [Nullable[bool]] $TelemetryRequired = $null
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    try {
        $inputData = Get-AvmMetadataValidationInput @PSBoundParameters
    }
    catch [System.ArgumentException] {
        return [pscustomobject]@{
            Metadata = $null
            Issues   = @((New-AvmMetadataIssue -Code 'AVM_METADATA_JSON' -Message $_.Exception.Message))
        }
    }
    $issues = [System.Collections.Generic.List[object]]::new()
    $codes = @{
        Shape             = 'AVM_METADATA_SCHEMA'
        Kind              = 'AVM_METADATA_KIND'
        Telemetry         = 'AVM_METADATA_TELEMETRY'
        History           = 'AVM_METADATA_TELEMETRY'
        RequiredTelemetry = 'AVM_METADATA_TELEMETRY'
        Owners            = 'AVM_METADATA_OWNER'
    }
    foreach ($name in $inputData.Schemas.Keys) {
        $errors = @()
        $text = if ($name -eq 'Owners') { $inputData.OwnerJson } else { $inputData.Json }
        if (-not (Test-Json -Json $text -Schema $inputData.Schemas[$name] `
                    -ErrorAction SilentlyContinue -ErrorVariable errors)) {
            $detail = @($errors | ForEach-Object { $_.Exception.Message }) -join ' '
            $message = if ($name -eq 'Shape') { "Invalid $($inputData.Shape) module metadata. $detail" }
            elseif ($name -eq 'Kind') { "canonicalType '$($inputData.Metadata['canonicalType'])' does not identify a $ModuleType module. $detail" }
            else { "$name metadata constraint failed. $detail" }
            $issues.Add((New-AvmMetadataIssue -Code $codes[$name] -Message $message))
            if ($name -eq 'Shape') { break }
        }
    }
    return [pscustomobject]@{ Metadata = $inputData.Metadata; Issues = $issues.ToArray() }
}
