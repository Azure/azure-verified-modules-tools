function Get-AvmBicepAzModuleManifest {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    foreach ($name in @('Az.Accounts', 'Az.Resources')) {
        $modules = @(Get-Module -Name $name)
        if ($modules.Count -ne 1) {
            throw [AvmConfigurationException]::new("Exactly one loaded $name module is required for deployment.")
        }
        $manifest = Join-Path $modules[0].ModuleBase "$name.psd1"
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
            throw [AvmConfigurationException]::new("The loaded $name module manifest is unavailable.")
        }
        $manifest
    }
}
