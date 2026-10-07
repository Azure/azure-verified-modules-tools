# Dot-source to load the module's shared network retry helpers into a repository
# script that runs before, or without, importing Avm.Authoring.
$avmNetworkHelperRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath @('src', 'Avm.Authoring', 'Private', 'Network')
foreach ($avmNetworkHelper in @(
        'Get-AvmNetworkRetryPolicy', 'Get-AvmNetworkFailureKind', 'ConvertFrom-AvmRetryAfterHeader',
        'Get-AvmRetryAfterDelay', 'Get-AvmRetryFailureMessage', 'Wait-AvmRetryDelay', 'Invoke-AvmRetry')) {
    . (Join-Path -Path $avmNetworkHelperRoot -ChildPath "$avmNetworkHelper.ps1")
}