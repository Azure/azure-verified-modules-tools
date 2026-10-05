#Requires -Version 7.4

# Loads the packaged Bicep convention rules into the imported module's scope so
# tests can call a single rule directly with module-private helpers available.
$conventionModule = Get-Module -Name 'Avm.Authoring' -ErrorAction Stop
if ($null -eq $conventionModule) {
    throw [System.InvalidOperationException]::new('Import Avm.Authoring before loading its convention rules.')
}
$conventionRules = @(Get-ChildItem -File -Filter '*.ps1' -ErrorAction Stop -LiteralPath (
        Join-Path $conventionModule.ModuleBase 'Resources' 'bicep' 'conventions' 'rules') |
        ForEach-Object FullName)
. $conventionModule {
    foreach ($conventionRule in $args[0]) {
        . $conventionRule
    }
} $conventionRules
