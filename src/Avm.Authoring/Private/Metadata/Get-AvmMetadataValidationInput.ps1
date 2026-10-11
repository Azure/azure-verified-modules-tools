function Get-AvmMetadataValidationInput {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Json,
        [Parameter(Mandatory)][ValidateSet('bicep', 'terraform')][string] $Ecosystem,
        [Parameter(Mandatory)][ValidateSet('resource', 'pattern', 'utility')][string] $ModuleType,
        [switch] $ChildModule,
        [Nullable[bool]] $TelemetryRequired = $null,
        [string] $Path = '.',
        [switch] $CheckSource
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $metadata = ConvertFrom-AvmMetadataJson -Json $Json
    $schemaPath = Join-Path -Path $PSScriptRoot -ChildPath '..' `
        -AdditionalChildPath '..', 'Resources', 'Schemas', 'v1', 'avm-module-metadata.schema.json'
    $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json -AsHashtable
    $shape = if ($ChildModule) { 'child' } else { 'root' }
    $schema.oneOf = @(@{ '$ref' = "#/definitions/$shape" })

    $resourceType = @{ pattern = $schema.definitions.canonicalType.anyOf[0].pattern }
    $kindType = if ($ModuleType -eq 'resource') { $resourceType } else { @{ not = $resourceType } }
    if ($ChildModule) {
        $kindType = @{ anyOf = @(@{ const = 'helper' }, $kindType) }
    }
    $marker = if ($Ecosystem -eq 'bicep') { '46d3xbcp' } else { '46d3xtrf' }
    $kind = @{ resource = 'res'; pattern = 'ptn'; utility = 'utl' }[$ModuleType]
    $prefix = @{ pattern = '^' + [regex]::Escape("$marker.$kind.") }
    if ($Ecosystem -eq 'bicep' -and $ModuleType -eq 'resource' -and
        $metadata['canonicalType'] -ceq 'Microsoft.ResourceGraph/queries') {
        $prefix = @{ anyOf = @($prefix, @{ const = '46d3xbcp.resourcegraph-query' }) }
    }
    $history = if ($metadata.Contains('telemetryIdPrefix')) {
        @{ properties = @{ alternativeTelemetryIdPrefixes = @{ items = @{ not = @{ const = $metadata['telemetryIdPrefix'] } } } } }
    }
    else { @{} }
    $required = if (($null -eq $TelemetryRequired -and $ModuleType -ne 'utility') -or $TelemetryRequired -eq $true) {
        @{ required = @('telemetryIdPrefix') }
    }
    else { @{} }
    if ($ChildModule) {
        $required = @{
            if   = @{ properties = @{ canonicalType = @{ not = @{ const = 'helper' } } } }
            then = $required
        }
    }

    $schemas = [ordered]@{
        Shape             = $schema
        Kind              = @{ properties = @{ canonicalType = $kindType } }
        Telemetry         = @{ properties = @{ telemetryIdPrefix = $prefix; alternativeTelemetryIdPrefixes = @{ items = $prefix } } }
        History           = $history
        RequiredTelemetry = $required
        Owners            = @{ properties = @{ owners = @{ uniqueItems = $true } } }
    }
    foreach ($name in @($schemas.Keys)) {
        $schemas[$name] = ConvertTo-Json -InputObject $schemas[$name] -Depth 50 -Compress
    }
    $ownerJson = $Json
    if (-not $ChildModule -and $metadata['owners'] -is [array]) {
        $normalized = $Json | ConvertFrom-Json -AsHashtable
        $normalized['owners'] = @($metadata['owners'] | ForEach-Object {
                if ($_ -is [string]) { $_.ToLowerInvariant() } else { $_ }
            })
        $ownerJson = ConvertTo-Json -InputObject $normalized -Depth 50 -Compress
    }
    $sourceItems = @()
    $sourceText = $null
    if ($CheckSource -and $Ecosystem -eq 'bicep') {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            $sourceItems = @(Get-ChildItem -LiteralPath $Path -Force)
        }
        $mainFiles = @($sourceItems | Where-Object { $_.Name -ieq 'main.bicep' })
        if ($mainFiles.Count -eq 1 -and -not $mainFiles[0].PSIsContainer -and
            $mainFiles[0].Name -ceq 'main.bicep' -and
            -not ($mainFiles[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            $sourceText = [System.IO.File]::ReadAllText($mainFiles[0].FullName)
        }
    }
    return @{
        Json         = $Json
        OwnerJson    = $ownerJson
        Metadata     = $metadata
        Schemas      = $schemas
        Shape        = $shape
        Ecosystem    = $Ecosystem
        ModuleType   = $ModuleType
        Path         = $Path
        CheckSource  = [bool]($CheckSource -and $Ecosystem -eq 'bicep')
        SourceItems  = $sourceItems
        SourceText   = $sourceText
        SourceParser = Join-Path $PSScriptRoot 'Get-AvmBicepMetadataLiteral.ps1'
        ShapeValid   = Test-Json -Json $Json -Schema $schemas.Shape -ErrorAction SilentlyContinue
    }
}
