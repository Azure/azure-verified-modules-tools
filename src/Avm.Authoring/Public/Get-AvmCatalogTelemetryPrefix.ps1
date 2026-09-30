function Get-AvmCatalogTelemetryPrefix {
    <#
    .SYNOPSIS
        Read current and historical telemetry prefixes from the public AVM catalog.
    .DESCRIPTION
        Uses the raw HTTPS catalog by default. An explicit local JSON path is
        accepted for offline review. If the catalog cannot be read or parsed,
        warns and returns no prefixes; callers must also check local metadata.
    .PARAMETER CatalogUri
        Raw HTTPS catalog URI or path to an existing local catalog document.
    .PARAMETER Catalog
        Already parsed catalog object, for callers sharing the prefix traversal.
    .PARAMETER ExcludeBicepModulePath
        Exclude the matching module's own identifiers when checking an already
        authored Bicep source prefix.
    .PARAMETER SkipModuleVersionCheck
        Skip the installed-module version check for a trusted checkout.
    .OUTPUTS
        Unique current and historical telemetry prefix strings.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Uri')]
    [OutputType([string[]])]
    param(
        [Parameter(ParameterSetName = 'Uri')]
        [string] $CatalogUri = 'https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/main/docs/static/module-indexes/v1/modules.json',

        [Parameter(Mandatory, ParameterSetName = 'Object')]
        [System.Collections.IDictionary] $Catalog,

        [string] $ExcludeBicepModulePath,

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck

    if ($PSCmdlet.ParameterSetName -eq 'Object') {
        return Get-AvmTelemetryPrefixFromCatalog -Catalog $Catalog -ExcludeBicepModulePath $ExcludeBicepModulePath
    }

    try {
        if ($CatalogUri.StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase)) {
            if ($env:AVM_OFFLINE -eq '1') {
                throw [AvmConfigurationException]::new('AVM_OFFLINE=1 prevents retrieving the published module catalog.')
            }
            $tls12 = [System.Net.SecurityProtocolType]::Tls12
            $protocols = $tls12
            if ($null -ne [System.Net.SecurityProtocolType].GetField('Tls13')) {
                $protocols = $tls12 -bor [System.Net.SecurityProtocolType]::Tls13
            }
            [System.Net.ServicePointManager]::SecurityProtocol = $protocols
            $module = Get-Module -Name Avm.Authoring
            $userAgent = 'Avm.Authoring/{0} ({1})' -f $module.Version, (Get-AvmToolPlatform)
            $response = Invoke-WebRequest -Uri $CatalogUri -TimeoutSec 15 -UserAgent $userAgent -ErrorAction Stop
            $json = if ($response.Content -is [byte[]]) {
                [System.Text.Encoding]::UTF8.GetString($response.Content)
            }
            else {
                [string]$response.Content
            }
        }
        elseif ($CatalogUri -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
            throw [System.ArgumentException]::new('The module catalog URI must use HTTPS.')
        }
        else {
            $json = Get-Content -LiteralPath $CatalogUri -Raw -ErrorAction Stop
        }
        $document = ConvertFrom-Json -InputObject $json -AsHashtable -Depth 100
        if ($document -isnot [System.Collections.IDictionary]) {
            throw [System.ArgumentException]::new('The module catalog must be a JSON object.')
        }
        return Get-AvmTelemetryPrefixFromCatalog -Catalog $document -ExcludeBicepModulePath $ExcludeBicepModulePath
    }
    catch {
        Write-Warning ("Could not resolve the module catalog at {0}; a generated telemetryIdPrefix cannot be checked against published identifiers. {1}" -f $CatalogUri, $_.Exception.Message)
        return [string[]]@()
    }
}
