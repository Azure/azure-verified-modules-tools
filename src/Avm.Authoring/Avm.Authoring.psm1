#Requires -Version 7.4

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$script:AvmLatestModuleVersion = $null
$script:AvmModuleVersionCheckCompleted = $false
$script:AvmModuleVersionSkipWarningWritten = $false
$script:AvmNestedCommandDepth = 0
$script:AvmPresentedIssues = [System.Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()

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

# Reparsing a script that declares classes creates new types, and PowerShell may evict its parsed-script cache at
# any time. Reuse one parsed copy of the exception classes per runspace so reimports keep a single type identity
# for each exception; a changed file hashes differently and is redefined.
$exceptionsPath = Join-Path -Path $privateRoot -ChildPath 'Exceptions' -AdditionalChildPath 'AvmExceptions.ps1'
$exceptionsKey = 'Avm.Authoring.Exceptions/{0}/{1}' -f [runspace]::DefaultRunspace.InstanceId,
(Get-FileHash -LiteralPath $exceptionsPath -Algorithm SHA256).Hash
$exceptionsScript = [AppDomain]::CurrentDomain.GetData($exceptionsKey)
if ($exceptionsScript -isnot [scriptblock]) {
    $exceptionsScript = (Get-Command -Name $exceptionsPath -CommandType ExternalScript).ScriptBlock
    [AppDomain]::CurrentDomain.SetData($exceptionsKey, $exceptionsScript)
}
. $exceptionsScript

if (Test-Path -LiteralPath $privateRoot) {
    foreach ($file in Get-ChildItem -Path $privateRoot -Filter '*.ps1' -Recurse -File) {
        if ($file.FullName -ceq $exceptionsPath) { continue }
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
