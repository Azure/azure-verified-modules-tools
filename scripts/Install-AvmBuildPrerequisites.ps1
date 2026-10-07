[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [switch] $IncludePSScriptAnalyzer,

    [switch] $IncludeBicepPolicy,

    [ValidateRange(1, 10)]
    [int] $MaxAttempts = 3,

    [ValidateRange(0, 300)]
    [int] $InitialDelaySeconds = 5
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# The module cannot be imported until these prerequisites exist.
. (Join-Path -Path $PSScriptRoot -ChildPath 'Import-AvmNetworkRetry.ps1')

if (-not (Get-Module -ListAvailable -Name 'Microsoft.PowerShell.PSResourceGet')) {
    if ($PSCmdlet.ShouldProcess('Microsoft.PowerShell.PSResourceGet', 'Install build prerequisite')) {
        $null = Invoke-AvmRetry `
            -RetryActivity 'Installing Microsoft.PowerShell.PSResourceGet' `
            -RetryMaxAttempts $MaxAttempts `
            -RetryInitialDelaySeconds $InitialDelaySeconds `
            -RetryAction {
                Install-Module `
                    -Name 'Microsoft.PowerShell.PSResourceGet' `
                    -Scope CurrentUser `
                    -Force `
                    -AllowClobber
            }
    }
}

Import-Module 'Microsoft.PowerShell.PSResourceGet' -Force

$packages = [System.Collections.Generic.List[hashtable]]::new()
$packages.Add(@{ Name = 'InvokeBuild'; Version = '[5.11.0,)' })
$pins = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'src' 'Avm.Authoring' 'Resources' 'avm.pins.jsonc') -Raw |
    ConvertFrom-Json -AsHashtable
$packages.Add(@{ Name = 'Pester'; Version = $pins['powerShellModules']['Pester']['version'] })
$packages.Add(@{ Name = 'powershell-yaml'; Version = $pins['powerShellModules']['powershell-yaml']['version'] })
if ($IncludePSScriptAnalyzer) {
    $packages.Add(@{ Name = 'PSScriptAnalyzer'; Version = '[1.21.0,)' })
}
if ($IncludeBicepPolicy) {
    foreach ($name in @('PSRule', 'PSRule.Rules.Azure')) {
        $packages.Add(@{ Name = $name; Version = $pins['powerShellModules'][$name]['version'] })
    }
}

foreach ($package in $packages) {
    # Ranges stay network-resolved so CI keeps receiving the newest allowed
    # release; an exact pin that is already installed needs no Gallery request.
    $isExactPin = $package.Version -notmatch '[\[\(,]'
    if ($isExactPin -and
        (Get-InstalledPSResource -Name $package.Name -Version $package.Version -ErrorAction SilentlyContinue)) {
        Write-Verbose "$($package.Name) $($package.Version) is already installed."
        continue
    }

    if ($PSCmdlet.ShouldProcess($package.Name, 'Install build prerequisite')) {
        $null = Invoke-AvmRetry `
            -RetryActivity "Installing $($package.Name)" `
            -RetryMaxAttempts $MaxAttempts `
            -RetryInitialDelaySeconds $InitialDelaySeconds `
            -RetryAction { Install-PSResource @package -Scope CurrentUser -TrustRepository }
    }
}