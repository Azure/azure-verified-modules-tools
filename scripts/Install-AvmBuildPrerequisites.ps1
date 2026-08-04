[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [switch] $IncludePSScriptAnalyzer,

    [ValidateRange(1, 10)]
    [int] $MaxAttempts = 3,

    [ValidateRange(0, 300)]
    [int] $InitialDelaySeconds = 5
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Test-AvmTransientGalleryFailure {
    param(
        [Parameter(Mandatory)]
        [System.Exception] $Exception
    )

    $detail = $Exception.ToString()
    return $detail -match '(?i)(no route to host|name or service not known|temporary failure in name resolution|connection (?:refused|reset)|timed? out|too many requests|\b429\b|\b50[234]\b|temporarily unavailable)'
}

function Invoke-AvmGalleryOperation {
    param(
        [Parameter(Mandatory)]
        [string] $Description,

        [Parameter(Mandatory)]
        [scriptblock] $Operation
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            & $Operation
            return
        }
        catch {
            if ($attempt -eq $MaxAttempts -or
                -not (Test-AvmTransientGalleryFailure -Exception $_.Exception)) {
                throw
            }

            $delay = $InitialDelaySeconds * [math]::Pow(2, $attempt - 1)
            Write-Warning ("$Description failed transiently on attempt $attempt of $MaxAttempts; retrying in $delay seconds.")
            if ($delay -gt 0) {
                Start-Sleep -Seconds $delay
            }
        }
    }
}

if (-not (Get-Module -ListAvailable -Name 'Microsoft.PowerShell.PSResourceGet')) {
    if ($PSCmdlet.ShouldProcess('Microsoft.PowerShell.PSResourceGet', 'Install build prerequisite')) {
        Invoke-AvmGalleryOperation -Description 'Installing Microsoft.PowerShell.PSResourceGet' -Operation {
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
$packages.Add(@{ Name = 'Pester'; Version = '[5.5.0,)' })
if ($IncludePSScriptAnalyzer) {
    $packages.Add(@{ Name = 'PSScriptAnalyzer'; Version = '[1.21.0,)' })
}

foreach ($package in $packages) {
    if ($PSCmdlet.ShouldProcess($package.Name, 'Install build prerequisite')) {
        Invoke-AvmGalleryOperation -Description "Installing $($package.Name)" -Operation {
            Install-PSResource @package -Scope CurrentUser -TrustRepository
        }
    }
}
