function New-AvmMetadataInputObject {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory metadata object without writing state.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $InputObject,

        [Parameter(Mandatory)]
        [ValidateSet('bicep', 'terraform')]
        [string] $Ecosystem,

        [Parameter(Mandatory)]
        [ValidateSet('resource', 'pattern', 'utility')]
        [string] $ModuleType,

        [switch] $ChildModule,

        [switch] $UpdateSource
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $metadata = [ordered]@{}
    foreach ($key in $InputObject.Keys) {
        $metadata[$key] = $InputObject[$key]
    }
    if (-not $metadata.Contains('$schema')) {
        $schemaPath = Join-Path -Path $PSScriptRoot -ChildPath '..' `
            -AdditionalChildPath '..', 'Resources', 'Schemas', 'v1', 'avm-module-metadata.schema.json'
        $metadata['$schema'] = (Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json -AsHashtable)['$id']
    }

    $required = @('moduleDisplayName', 'moduleDescription', 'canonicalType')
    if (-not $ChildModule) {
        $required += 'owners'
    }
    $telemetryRequired = Test-AvmMetadataTelemetryRequired -Path $Path -Ecosystem $Ecosystem `
        -ModuleType $ModuleType -ChildModule:$ChildModule
    $isHelper = $ChildModule -and $metadata.Contains('canonicalType') -and $metadata.canonicalType -ceq 'helper'
    if ($Ecosystem -eq 'terraform' -and $telemetryRequired -and -not $isHelper) {
        $required += 'telemetryIdPrefix'
    }
    $missing = @($required | Where-Object { -not $metadata.Contains($_) })

    $kind = @{ resource = 'res'; pattern = 'ptn'; utility = 'utl' }[$ModuleType]
    $marker = if ($Ecosystem -eq 'bicep') { '46d3xbcp' } else { '46d3xtrf' }
    $placeholder = "$marker.$kind.placeholder"
    $placeholderIndex = 0
    while (@($metadata['alternativeTelemetryIdPrefixes']) -ccontains $placeholder) {
        $placeholderIndex++
        $placeholder = "$marker.$kind.placeholder$placeholderIndex"
    }
    $probe = [ordered]@{}
    foreach ($key in $metadata.Keys) {
        $probe[$key] = $metadata[$key]
    }
    foreach ($field in $missing) {
        if ($field -eq 'owners') {
            $probe.owners = @()
            continue
        }
        $probe[$field] = switch ($field) {
            'moduleDisplayName' { 'Module name' }
            'moduleDescription' { 'Module description.' }
            'canonicalType' { if ($ModuleType -eq 'resource') { 'Microsoft.Storage/storageAccounts' } else { 'naming' } }
            'telemetryIdPrefix' { $placeholder }
        }
    }
    if (-not $probe.Contains('telemetryIdPrefix') -and $telemetryRequired -and -not $isHelper) {
        $probe.telemetryIdPrefix = $placeholder
    }
    $probeValidation = Test-AvmMetadataContent -Json (ConvertTo-Json -InputObject $probe -Depth 50) `
        -Ecosystem $Ecosystem -ModuleType $ModuleType -ChildModule:$ChildModule -TelemetryRequired $telemetryRequired
    if ($probeValidation.Issues.Count -gt 0) {
        throw [System.ArgumentException]::new(($probeValidation.Issues.Message -join ' '))
    }

    if ($missing.Count -gt 0) {
        if (-not (Test-AvmInteractiveHost)) {
            throw [System.ArgumentException]::new(
                "Missing required metadata fields: $($missing -join ', '). Supply them with -InputObject or run in an interactive terminal.")
        }
        $prompts = @{
            moduleDisplayName = 'Module display name'
            moduleDescription = 'Module description'
            canonicalType     = 'Canonical type (ARM resource type or pattern/utility taxonomy)'
            owners            = 'Owners (comma-separated GitHub handles; leave blank for none)'
            telemetryIdPrefix = 'Terraform telemetry ID prefix'
        }
        foreach ($field in $missing) {
            $answer = Read-Host -Prompt $prompts[$field]
            if ($field -eq 'owners') {
                $metadata.owners = @(
                    $answer -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 }
                )
            }
            else {
                $metadata[$field] = $answer
            }
            $probe[$field] = $metadata[$field]
        }
        $promptValidation = Test-AvmMetadataContent -Json (ConvertTo-Json -InputObject $probe -Depth 50) `
            -Ecosystem $Ecosystem -ModuleType $ModuleType -ChildModule:$ChildModule -TelemetryRequired $telemetryRequired
        if ($promptValidation.Issues.Count -gt 0) {
            throw [System.ArgumentException]::new(($promptValidation.Issues.Message -join ' '))
        }
    }

    $isHelper = $ChildModule -and $metadata.canonicalType -ceq 'helper'
    $requiresBicepPrefix = $Ecosystem -eq 'bicep' -and -not $isHelper -and $telemetryRequired -and -not $metadata.Contains('telemetryIdPrefix')
    if ($requiresBicepPrefix -and $UpdateSource) {
        $authoredPrefix = Get-AvmBicepTelemetrySourcePrefix -Path $Path
        if ($authoredPrefix) {
            $metadata.telemetryIdPrefix = $authoredPrefix
            $sourceValidation = Test-AvmMetadataContent -Json (ConvertTo-Json -InputObject $metadata -Depth 50) `
                -Ecosystem bicep -ModuleType $ModuleType -ChildModule:$ChildModule -TelemetryRequired $telemetryRequired
            if ($sourceValidation.Issues.Count -gt 0) {
                throw [System.ArgumentException]::new(($sourceValidation.Issues.Message -join ' '))
            }

            $localKnown = @(Get-AvmLocalBicepTelemetryPrefix -Path $Path)
            if ($localKnown -ccontains $authoredPrefix) {
                throw [System.ArgumentException]::new(
                    "main.bicep telemetryIdPrefix '$authoredPrefix' is already used by another module. Resolve the collision before initializing metadata.")
            }
            $monorepoRoot = Get-AvmBicepMonorepoRoot -Path $Path
            $catalogArgs = @{ SkipModuleVersionCheck = $true }
            if ($monorepoRoot) {
                $catalogArgs.ExcludeBicepModulePath = [System.IO.Path]::GetRelativePath($monorepoRoot, $Path).Replace('\', '/')
            }
            $publishedKnown = @(Get-AvmCatalogTelemetryPrefix @catalogArgs)
            if ($publishedKnown -ccontains $authoredPrefix) {
                throw [System.ArgumentException]::new(
                    "main.bicep telemetryIdPrefix '$authoredPrefix' is already used by another module. Resolve the collision before initializing metadata.")
            }
            return $metadata
        }
    }
    if ($requiresBicepPrefix) {
        $known = @(Get-AvmLocalBicepTelemetryPrefix -Path $Path) + @(Get-AvmCatalogTelemetryPrefix -SkipModuleVersionCheck)
        $metadata.telemetryIdPrefix = New-AvmTelemetryIdPrefix -Ecosystem bicep -Kind $kind `
            -KnownPrefix $known -SkipModuleVersionCheck
    }
    return $metadata
}
