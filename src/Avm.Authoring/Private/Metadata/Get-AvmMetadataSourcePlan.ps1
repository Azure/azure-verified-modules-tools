function Get-AvmMetadataSourcePlan {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Metadata,

        [Parameter(Mandatory)]
        [ValidateSet('bicep', 'terraform')]
        [string] $Ecosystem,

        [switch] $ChildModule
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Ecosystem -eq 'bicep') {
        $sourcePath = Join-Path -Path $Path -ChildPath 'main.bicep'
        $source = Get-Content -LiteralPath $sourcePath -Raw
        $code = Get-AvmBicepCommentFreeSource -Source $source
        $literals = Get-AvmBicepMetadataLiteral -Source $source
        if ($literals.name -cne $Metadata.moduleDisplayName -or
            $literals.description -cne $Metadata.moduleDescription) {
            throw [System.ArgumentException]::new('The metadata values must match the existing main.bicep name and description.')
        }
        if (-not $Metadata.Contains('telemetryIdPrefix')) {
            if ([regex]::IsMatch($code, "(?m)^[\t ]*resource[\t ]+avmTelemetry[\t ]+'Microsoft\.Resources/deployments@")) {
                throw [System.ArgumentException]::new('This Bicep module emits telemetry and requires telemetryIdPrefix.')
            }
            return
        }

        $declaration = "var avmTelemetryIdPrefix = loadJsonContent('metadata.json', '$.telemetryIdPrefix')"
        $nameReference = '${avmTelemetryIdPrefix}'
        $headPattern = "(?m)(?<head>^[\t ]*resource[\t ]+avmTelemetry[\t ]+'Microsoft\.Resources/deployments@[^']+'[^\r\n]*\{\s*name[\t ]*:[\t ]*')"
        if ($code.Contains($declaration) -and
            [regex]::IsMatch($code, $headPattern + [regex]::Escape($nameReference) + '\.')) {
            return
        }
        if ([regex]::IsMatch($code, '(?m)^[\t ]*var[\t ]+avmTelemetryIdPrefix\b')) {
            throw [System.ArgumentException]::new('main.bicep already defines avmTelemetryIdPrefix differently; review its source manually.')
        }

        $prefixPattern = $headPattern + [regex]::Escape($Metadata.telemetryIdPrefix) + '(?=\.)'
        $prefixMatches = [regex]::Matches($code, $prefixPattern)
        if ($prefixMatches.Count -ne 1) {
            throw [System.ArgumentException]::new('Expected one avmTelemetry deployment using the supplied telemetryIdPrefix; inspect this Bicep source before changing it.')
        }
        $prefixMatch = $prefixMatches[0]
        $prefixIndex = $prefixMatch.Index + $prefixMatch.Groups['head'].Length
        $content = $source.Substring(0, $prefixIndex) + $nameReference +
        $source.Substring($prefixIndex + $Metadata.telemetryIdPrefix.Length)
        $content = $content.Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n`n$declaration`n"
        return [pscustomobject]@{ Path = $sourcePath; Content = $content; Original = $source }
    }

    $sourcePath = Join-Path -Path $Path -ChildPath 'main.metadata.tf'
    $fields = [ordered]@{
        avm_metadata       = 'jsondecode(file("${path.module}/metadata.json"))'
        avm_canonical_type = 'local.avm_metadata.canonicalType'
        avm_tier           = 'local.avm_metadata.tier'
    }
    if ($ChildModule) {
        if ((Split-Path -Leaf (Split-Path -Parent $Path)) -cne 'modules') {
            throw [System.ArgumentException]::new('Terraform child source readers require an immediate modules/{name} directory.')
        }
        $fields.avm_tier = 'jsondecode(file("${path.module}/../../metadata.json")).tier'
    }
    if ($Metadata.Contains('telemetryIdPrefix')) {
        $fields.avm_telemetry_id_prefix = 'local.avm_metadata.telemetryIdPrefix'
    }
    $width = ($fields.Keys | Measure-Object -Property Length -Maximum).Maximum
    $lines = @('locals {') + @($fields.GetEnumerator() | ForEach-Object {
            '  {0} = {1}' -f $_.Key.PadRight($width), $_.Value
        }) + @('}', '')
    $content = $lines -join "`n"

    foreach ($file in Get-ChildItem -LiteralPath $Path -Filter '*.tf' -File) {
        if ($file.Name -ceq 'main.metadata.tf') {
            continue
        }
        $existingSource = Get-Content -LiteralPath $file.FullName -Raw
        foreach ($field in $fields.Keys) {
            if ([regex]::IsMatch($existingSource, "(?m)^[\t ]*$field[\t ]*=")) {
                throw [System.ArgumentException]::new("$($file.Name) already defines $field; review the existing metadata reader before backfill.")
            }
        }
    }
    if (Test-Path -LiteralPath $sourcePath) {
        if ((Get-Content -LiteralPath $sourcePath -Raw) -cne $content) {
            throw [System.ArgumentException]::new('main.metadata.tf already exists with different content and will not be overwritten.')
        }
        return
    }
    return [pscustomobject]@{ Path = $sourcePath; Content = $content; Original = $null }
}
