#Requires -Version 7.4

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $ModulePath,
    [AllowEmptyString()] [string] $ModuleConfigJson = '',
    [AllowEmptyString()] [string] $BamiSettingsJson = '',
    [string] $OutputPath = $env:GITHUB_OUTPUT
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' '..' '..' 'shared' 'TestTenant.ps1')

$selection = Resolve-AvmTestTenant -ModulePath $ModulePath -ModuleConfigJson $ModuleConfigJson -BamiSettingsJson $BamiSettingsJson
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    throw [System.ArgumentException]::new('GITHUB_OUTPUT or OutputPath is required.')
}
$settingsJson = ConvertTo-Json -InputObject $selection.Settings -Depth 5 -Compress
if ($PSCmdlet.ShouldProcess($OutputPath, 'Append validated test tenant outputs')) {
    [System.IO.File]::AppendAllText(
        $OutputPath,
        "test-tenant=$($selection.TestTenant)`nsettings-json=$settingsJson`n",
        [System.Text.UTF8Encoding]::new($false)
    )
}
