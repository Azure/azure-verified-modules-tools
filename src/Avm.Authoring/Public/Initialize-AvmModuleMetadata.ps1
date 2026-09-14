function Initialize-AvmModuleMetadata {
    <#
    .SYNOPSIS
        Initialize module-owned metadata from a reviewed seed without overwriting it.
    .DESCRIPTION
        Validates the complete seed before writing UTF-8/LF metadata.json.
        Existing metadata is validated and preserved instead of regenerated.
        Optional source wiring adds native JSON readers without changing the
        telemetry transport. WhatIf performs validation and returns the plan.
    .PARAMETER Path
        Existing module directory to initialize.
    .PARAMETER SeedPath
        Strict JSON file containing the full metadata seed.
    .PARAMETER InputObject
        Metadata seed dictionary, as an alternative to SeedPath.
    .PARAMETER Ecosystem
        The containing module's ecosystem: bicep or terraform.
    .PARAMETER ModuleType
        Module kind derived from its path or repository name.
    .PARAMETER ChildModule
        Initialize the reduced child shape, inheriting owners and tier.
    .PARAMETER UpdateSource
        Wire Bicep's scoped telemetry prefix load, or Terraform's native JSON
        locals in main.metadata.tf. Existing conflicting readers are not replaced.
    .PARAMETER SkipModuleVersionCheck
        Skip the standard installed-module version check for offline backfill.
    .EXAMPLE
        Initialize-AvmModuleMetadata -Path . -SeedPath seed.json -Ecosystem terraform -ModuleType resource -WhatIf
    .OUTPUTS
        A result with Status, Changed, PlannedFiles, and Metadata.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Metadata is the shared metadata.json contract name.')]
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium', DefaultParameterSetName = 'File')]
    [OutputType([pscustomobject])]
    param(
        [string] $Path = $PWD.Path,

        [Parameter(Mandatory, ParameterSetName = 'File')]
        [string] $SeedPath,

        [Parameter(Mandatory, ParameterSetName = 'Object')]
        [System.Collections.IDictionary] $InputObject,

        [Parameter(Mandatory)]
        [ValidateSet('bicep', 'terraform')]
        [string] $Ecosystem,

        [Parameter(Mandatory)]
        [ValidateSet('resource', 'pattern', 'utility')]
        [string] $ModuleType,

        [switch] $ChildModule,

        [switch] $UpdateSource,

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $sentinel = Test-AvmDisableSentinel -Path $Path
    if ($sentinel) {
        throw [AvmConfigurationException]::new("avm is disabled in this repository (remove '$sentinel' to re-enable).")
    }
    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw [System.ArgumentException]::new("Module directory does not exist: $Path")
    }
    $root = (Get-Item -LiteralPath $Path).FullName
    $metadataPath = Join-Path -Path $root -ChildPath 'metadata.json'
    $metadataFiles = @(Get-ChildItem -LiteralPath $root -Force | Where-Object { $_.Name -ieq 'metadata.json' })
    if ($metadataFiles.Count -gt 0) {
        if ($metadataFiles.Count -ne 1 -or $metadataFiles[0].PSIsContainer -or $metadataFiles[0].Name -cne 'metadata.json') {
            throw [System.ArgumentException]::new('metadata.json must be a file with that exact casing.')
        }
    }
    $existing = $metadataFiles.Count -eq 1
    $json = if ($existing) {
        Read-AvmMetadataJson -Path $metadataPath
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'Object') {
        ConvertTo-Json -InputObject $InputObject -Depth 50
    }
    else {
        Read-AvmMetadataJson -Path $SeedPath
    }
    $validation = Test-AvmMetadataContent -Json $json -Ecosystem $Ecosystem `
        -ModuleType $ModuleType -ChildModule:$ChildModule
    if ($validation.Issues.Count -gt 0) {
        throw [System.ArgumentException]::new(($validation.Issues.Message -join ' '))
    }

    $plans = [System.Collections.Generic.List[object]]::new()
    if (-not $existing) {
        $content = (ConvertTo-Json -InputObject $validation.Metadata -Depth 50).Replace("`r`n", "`n") + "`n"
        $plans.Add([pscustomobject]@{ Path = $metadataPath; Content = $content; Original = $null })
    }
    if ($UpdateSource) {
        foreach ($plan in @(Get-AvmMetadataSourcePlan -Path $root -Metadata $validation.Metadata `
                    -Ecosystem $Ecosystem -ChildModule:$ChildModule)) {
            $plans.Add($plan)
        }
    }

    $changed = $false
    if ($plans.Count -gt 0 -and $PSCmdlet.ShouldProcess($root, 'Initialize module metadata and requested JSON source readers')) {
        foreach ($plan in $plans) {
            if ($null -ne $plan.Original -and (Get-Content -LiteralPath $plan.Path -Raw) -cne $plan.Original) {
                throw [System.IO.IOException]::new("Source changed during initialization: $($plan.Path)")
            }
            $temporaryPath = Join-Path -Path $root -ChildPath ('.avm-metadata-' + [guid]::NewGuid().ToString('N').Substring(0, 12) + '.tmp')
            try {
                [System.IO.File]::WriteAllText($temporaryPath, $plan.Content, [System.Text.UTF8Encoding]::new($false))
                [System.IO.File]::Move($temporaryPath, $plan.Path, ($null -ne $plan.Original))
                $changed = $true
            }
            finally {
                if ([System.IO.File]::Exists($temporaryPath)) {
                    [System.IO.File]::Delete($temporaryPath)
                }
            }
        }
    }

    return [pscustomobject][ordered]@{
        Engine       = $Ecosystem
        Tool         = 'module-metadata/1'
        ToolPath     = $null
        ToolSource   = 'builtin'
        Status       = 'pass'
        Issues       = @()
        Changed      = $changed
        PlannedFiles = @($plans | ForEach-Object { [System.IO.Path]::GetRelativePath($root, $_.Path).Replace('\', '/') })
        Metadata     = $validation.Metadata
    }
}
