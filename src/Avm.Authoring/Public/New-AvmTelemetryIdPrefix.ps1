function New-AvmTelemetryIdPrefix {
    <#
    .SYNOPSIS
        Generate a seven-character hexadecimal telemetry identifier.
    .DESCRIPTION
        Returns a random Bicep or Terraform telemetry prefix. Retries if the
        candidate is in KnownPrefix, which should include current and former
        identifiers from the relevant module inventory.
    .PARAMETER Ecosystem
        The module ecosystem: bicep or terraform.
    .PARAMETER Kind
        The module kind: res, ptn, or utl.
    .PARAMETER KnownPrefix
        Prefixes that must not be reused.
    .PARAMETER SkipModuleVersionCheck
        Skip the installed-module version check for a trusted checkout.
    .EXAMPLE
        New-AvmTelemetryIdPrefix -Ecosystem bicep -Kind res -KnownPrefix $existing -SkipModuleVersionCheck
    .OUTPUTS
        A telemetry prefix string.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only returns an in-memory random identifier; no state is changed.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('bicep', 'terraform')]
        [string] $Ecosystem,

        [Parameter(Mandatory)]
        [ValidateSet('res', 'ptn', 'utl')]
        [string] $Kind,

        [string[]] $KnownPrefix = @(),

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck
    $taken = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@($KnownPrefix), [System.StringComparer]::Ordinal)
    $marker = if ($Ecosystem -eq 'bicep') { '46d3xbcp' } else { '46d3xtrf' }
    $bytes = [byte[]]::new(4)
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
        $suffix = (($bytes | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 7)
        $candidate = '{0}.{1}.{2}' -f $marker, $Kind, $suffix
        if (-not $taken.Contains($candidate)) {
            return $candidate
        }
    }
    throw [System.InvalidOperationException]::new(
        'Could not generate a telemetry prefix unique against known prefixes; provide a different inventory or try again.')
}
