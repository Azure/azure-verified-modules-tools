function Read-AvmPins {
    <#
    .SYNOPSIS
        Load and validate the Avm.Authoring pin manifest.

    .DESCRIPTION
        Defaults to the module-bundled manifest at Resources/avm.pins.jsonc,
        the single source of truth for every externally-sourced version this
        module depends on: managed tool binaries, the conftest policy library,
        and the TFLint plugin versions.

        The manifest is JSONC. ConvertFrom-Json accepts // line comments,
        /* block */ comments, and trailing commas natively, so the schema stays
        documented inline. Do not switch this to Test-Json or System.Text.Json
        without enabling comment handling on those APIs; they are stricter.

        Pass -Path to read a fixture manifest during tests. Always validates via
        Test-AvmPins before returning; an invalid manifest throws.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Noun mirrors the avm.pins.jsonc manifest, which holds many pins.')]
    [OutputType([hashtable])]
    param(
        [string] $Path,
        [switch] $AllowFileUrls
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not $Path) {
        $Path = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath @('..', 'Resources', 'avm.pins.jsonc')
    }

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $raw = Get-Content -LiteralPath $resolved.Path -Raw -Encoding utf8

    try {
        $pins = $raw | ConvertFrom-Json -AsHashtable
    }
    catch {
        throw [System.Data.DataException]::new(
            "avm.pins: '$($resolved.Path)' is not valid JSON/JSONC. $($_.Exception.Message)", $_.Exception)
    }

    if ($null -eq $pins -or $pins -isnot [hashtable]) {
        throw [System.Data.DataException]::new(
            "avm.pins: '$($resolved.Path)' must contain a JSON object at the root.")
    }

    Test-AvmPins -Pins $pins -AllowFileUrls:$AllowFileUrls | Out-Null
    return $pins
}
