function Get-AvmModuleContextInternal {
    <#
    .SYNOPSIS
        Resolve module context from one authoritative filesystem root.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [ValidateSet('auto', 'bicep', 'terraform')]
        [string] $Ecosystem = 'auto'
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    try {
        $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    }
    catch {
        throw [AvmContextException]::new("Path does not exist: $Path", $_.Exception)
    }

    if ($resolved.Provider.Name -ne 'FileSystem') {
        throw [AvmContextException]::new("Path must use the FileSystem provider: $Path")
    }

    $item = Get-Item -LiteralPath $resolved.ProviderPath -Force
    $root = if ($item.PSIsContainer) { $item.FullName } else { $item.Directory.FullName }

    $reservedAncestor = Get-AvmReservedContextAncestor -Path $root
    if ($reservedAncestor) {
        throw [AvmContextException]::new(
            "Path '$root' contains the reserved context folder '$($reservedAncestor.ReservedName)' at '$($reservedAncestor.ReservedPath)'. " +
            'AVM commands must run from the module root, and its full path must not contain reserved context folder names.')
    }

    $override = Read-AvmContextOverride -Path $root
    if ($override) {
        Write-AvmLog ("context: override resolved kind={0}; ecosystem={1}; root={2}" -f $override.Kind, $override.Ecosystem, $override.Root) -Level Verbose | Out-Null
        if ($Ecosystem -ne 'auto' -and $override.Ecosystem -ne $Ecosystem) {
            throw [AvmContextException]::new(
                "Ecosystem '$Ecosystem' conflicts with .avm/context.psd1 at $($override.Root) which declares '$($override.Ecosystem)'.")
        }
        return $override
    }

    $signature = Get-AvmContextRootSignature -Path $root
    $hasTerraform = $signature.HasTerraformSource
    $hasBicep = $signature.HasBicepSource -or $signature.HasBicepMonorepo

    if ($Ecosystem -eq 'auto' -and $hasTerraform -and $hasBicep) {
        throw [AvmContextException]::new(
            "Both Terraform and Bicep source signatures exist at authoritative module root '$root'. " +
            'Specify -Ecosystem terraform or -Ecosystem bicep.')
    }

    if ($Ecosystem -eq 'terraform' -and -not $hasTerraform) {
        throw [AvmContextException]::new(
            "Ecosystem 'terraform' was requested, but no direct *.tf source files exist at authoritative module root '$root'. " +
            'AVM commands must run from the module root.')
    }

    if ($Ecosystem -eq 'bicep' -and -not $hasBicep) {
        throw [AvmContextException]::new(
            "Ecosystem 'bicep' was requested, but no direct *.bicep source files or Bicep monorepo signature exist at authoritative module root '$root'. " +
            'AVM commands must run from the module root.')
    }

    $selectedEcosystem = if ($Ecosystem -eq 'auto') {
        if ($hasTerraform) {
            'terraform'
        }
        elseif ($hasBicep) {
            'bicep'
        }
        else {
            $null
        }
    }
    else {
        $Ecosystem
    }

    if ($null -eq $selectedEcosystem) {
        throw [AvmContextException]::new(
            "Could not detect an AVM context at authoritative module root '$root'. " +
            'Expected direct *.tf or *.bicep source files, or a Bicep monorepo signature. ' +
            'AVM commands must run from the module root.')
    }

    if ($selectedEcosystem -eq 'terraform') {
        $kind = if ($signature.HasTerraformRoot) { 'terraform-module-repo' } else { 'terraform-module-path' }
        $scope = $null
    }
    elseif ($signature.HasBicepSource) {
        $kind = 'bicep-module'
        $scope = $null
        $segments = $root -split '[\\/]'
        for ($index = 0; $index -lt ($segments.Count - 1); $index++) {
            if ($segments[$index] -eq 'avm' -and $segments[$index + 1] -in @('res', 'ptn', 'utl')) {
                $scope = $segments[$index + 1]
                break
            }
        }
    }
    else {
        $kind = 'bicep-monorepo'
        $scope = $null
    }

    Write-AvmLog ("context: detected kind={0}; ecosystem={1}; root={2}; scope={3}" -f $kind, $selectedEcosystem, $root, $scope) -Level Verbose | Out-Null
    return [pscustomobject]@{
        Kind      = $kind
        Root      = $root
        Ecosystem = $selectedEcosystem
        Scope     = $scope
        Owner     = $null
    }
}
