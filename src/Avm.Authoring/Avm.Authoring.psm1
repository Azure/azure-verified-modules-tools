#Requires -Version 7.4

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Console encoding (spec open question 2): on Windows, the default console
# code page is often legacy (1252, 437, ...) which mangles UTF-8 output from
# child processes like terraform, bicep, and tflint. Force the console to
# UTF-8 at import time so subprocess stdout / stderr decode cleanly. Opt out
# by setting AVM_NO_CONSOLE_CONFIG=1 before importing the module.
if (-not $env:AVM_NO_CONSOLE_CONFIG -and ($IsWindows -or $env:OS -eq 'Windows_NT')) {
    try {
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [Console]::OutputEncoding = $utf8NoBom
        $script:OriginalOutputEncoding = $OutputEncoding
        $OutputEncoding = $utf8NoBom
    }
    catch {
        Write-Verbose "Avm.Authoring: skipping console encoding setup: $($_.Exception.Message)"
    }
}

# Discovery loader. Dot-source every .ps1 under Private/ first (helpers) and
# then under Public/ (user-facing cmdlets). Only public function names are
# exported; aliases declared via [Alias()] on public functions are exported via
# the wildcard.

$privateRoot = Join-Path $PSScriptRoot 'Private'
$enginesRoot = Join-Path $PSScriptRoot 'Engines'
$publicRoot = Join-Path $PSScriptRoot 'Public'

if (Test-Path -LiteralPath $privateRoot) {
    foreach ($file in Get-ChildItem -Path $privateRoot -Filter '*.ps1' -Recurse -File) {
        . $file.FullName
    }
}

if (Test-Path -LiteralPath $enginesRoot) {
    foreach ($file in Get-ChildItem -Path $enginesRoot -Filter '*.ps1' -Recurse -File) {
        . $file.FullName
    }
}

$publicNames = @()
if (Test-Path -LiteralPath $publicRoot) {
    foreach ($file in Get-ChildItem -Path $publicRoot -Filter '*.ps1' -Recurse -File) {
        . $file.FullName
        $publicNames += [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    }
}

if ($publicNames.Count -gt 0) {
    Export-ModuleMember -Function $publicNames -Alias '*'
}
