function Initialize-AvmModuleMetadata {
    <#
    .SYNOPSIS
        Create metadata.json without overwriting an existing file.
    .DESCRIPTION
        Validates the metadata values before writing UTF-8/LF metadata.json.
        Existing metadata is validated and preserved instead of regenerated.
        Missing required values are prompted for in an interactive terminal;
        non-interactive callers must supply them explicitly. A missing Bicep
        prefix is generated against published and local metadata when required.
        A missing Bicep module directory is created after validation.
        Optional Bicep source wiring loads the telemetry prefix without changing
        its transport. Terraform source wiring is not supported.
        WhatIf performs validation and returns the plan.
    .PARAMETER Path
        Module directory to initialize. Missing Bicep directories are created
        after validation; Terraform requires an existing directory by default.
    .PARAMETER InputObject
        Optional metadata values supplied by the caller. Supplied values must be
        valid; absent required values are prompted for only in interactive hosts.
    .PARAMETER Ecosystem
        The containing module's ecosystem: bicep or terraform.
    .PARAMETER ModuleType
        Module kind derived from its path or repository name.
    .PARAMETER ChildModule
        Initialize the reduced child shape, inheriting root ownership.
        This scope also permits canonicalType helper with optional telemetry.
    .PARAMETER UpdateSource
        Wire Bicep's scoped telemetry prefix load. Existing conflicting readers
        are not replaced. Terraform rejects this switch before any writes.
    .PARAMETER CreateDirectory
        Explicitly permit creating a missing Terraform module directory. Used
        by local avm init; legacy Terraform callers still require an existing
        module directory by default.
    .PARAMETER SkipModuleVersionCheck
        Skip the standard installed-module version check for offline initialization.
    .EXAMPLE
        Initialize-AvmModuleMetadata -Path . -InputObject $metadata -Ecosystem terraform -ModuleType resource -WhatIf
    .OUTPUTS
        A result with Status, Changed, PlannedFiles, and Metadata.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Metadata is the shared metadata.json contract name.')]
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [string] $Path = $PWD.Path,

        [System.Collections.IDictionary] $InputObject = @{},

        [Parameter(Mandatory)]
        [ValidateSet('bicep', 'terraform')]
        [string] $Ecosystem,

        [Parameter(Mandatory)]
        [ValidateSet('resource', 'pattern', 'utility')]
        [string] $ModuleType,

        [switch] $ChildModule,

        [switch] $UpdateSource,

        [switch] $CreateDirectory,

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ($UpdateSource -and $Ecosystem -eq 'terraform') {
        throw [AvmNotSupportedException]::new('Terraform -UpdateSource is not supported. Omit -UpdateSource; Terraform telemetry changes belong in a later MaPoTF update.')
    }
    $root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $existingDirectory = Get-AvmExistingDirectory -Path $root
    $rootExists = Test-Path -LiteralPath $root -PathType Container
    if (-not $rootExists -and $Ecosystem -ne 'bicep' -and -not $CreateDirectory) {
        throw [System.ArgumentException]::new("Module directory does not exist: $root")
    }
    $parent = Split-Path -Path $root -Parent
    if (-not $rootExists -and $Ecosystem -eq 'terraform' -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw [System.ArgumentException]::new("Parent directory does not exist: $parent")
    }
    if ($rootExists) {
        $root = (Get-Item -LiteralPath $root).FullName
    }
    $sentinel = Test-AvmDisableSentinel -Path $existingDirectory
    if ($sentinel) {
        throw [AvmConfigurationException]::new("avm is disabled in this repository (remove '$sentinel' to re-enable).")
    }
    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck
    if ($UpdateSource -and -not (Test-Path -LiteralPath (Join-Path -Path $root -ChildPath 'main.bicep') -PathType Leaf)) {
        throw [System.ArgumentException]::new('-UpdateSource requires an existing main.bicep; omit -UpdateSource for proposed modules.')
    }

    $metadataPath = Join-Path -Path $root -ChildPath 'metadata.json'
    $metadataFiles = @(
        if ($rootExists) {
            Get-ChildItem -LiteralPath $root -Force | Where-Object { $_.Name -ieq 'metadata.json' }
        }
    )
    if ($metadataFiles.Count -gt 0) {
        if ($metadataFiles.Count -ne 1 -or $metadataFiles[0].PSIsContainer -or $metadataFiles[0].Name -cne 'metadata.json') {
            throw [System.ArgumentException]::new('metadata.json must be a file with that exact casing.')
        }
    }
    $existing = $metadataFiles.Count -eq 1
    $json = if ($existing) {
        Read-AvmMetadataJson -Path $metadataPath
    }
    else {
        $inputMetadata = New-AvmMetadataInputObject -Path $root -InputObject $InputObject `
            -Ecosystem $Ecosystem -ModuleType $ModuleType -ChildModule:$ChildModule -UpdateSource:$UpdateSource
        ConvertTo-Json -InputObject $inputMetadata -Depth 50
    }
    $validation = Test-AvmMetadataContent -Json $json -Ecosystem $Ecosystem `
        -ModuleType $ModuleType -ChildModule:$ChildModule `
        -TelemetryRequired (Test-AvmMetadataTelemetryRequired -Path $root -Ecosystem $Ecosystem -ModuleType $ModuleType -ChildModule:$ChildModule)
    if ($validation.Issues.Count -gt 0) {
        throw [System.ArgumentException]::new(($validation.Issues.Message -join ' '))
    }

    $plans = [System.Collections.Generic.List[object]]::new()
    if (-not $existing) {
        $content = (ConvertTo-Json -InputObject $validation.Metadata -Depth 50).Replace("`r`n", "`n") + "`n"
        $plans.Add([pscustomobject]@{ Path = $metadataPath; Content = $content; Original = $null })
    }
    if ($UpdateSource) {
        foreach ($plan in @(Get-AvmMetadataSourcePlan -Path $root -Metadata $validation.Metadata)) {
            $plans.Add($plan)
        }
    }

    $changed = $false
    if ($plans.Count -gt 0 -and $PSCmdlet.ShouldProcess($root, 'Initialize module metadata and requested JSON source readers')) {
        $createdDirectories = [System.Collections.Generic.List[string]]::new()
        try {
            if (-not $rootExists) {
                $pending = [System.Collections.Generic.Stack[string]]::new()
                $directory = $root
                $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase }
                else { [System.StringComparison]::Ordinal }
                while (-not [string]::Equals($directory, $existingDirectory, $comparison)) {
                    $pending.Push($directory)
                    $parentDirectory = Split-Path -Path $directory -Parent
                    if (-not $parentDirectory -or [string]::Equals($directory, $parentDirectory, $comparison)) {
                        throw [System.IO.IOException]::new("Cannot locate the existing parent of $root.")
                    }
                    $directory = $parentDirectory
                }
                while ($pending.Count -gt 0) {
                    $directory = $pending.Pop()
                    $null = New-Item -ItemType Directory -Path $directory -ErrorAction Stop
                    $createdDirectories.Add($directory)
                }
            }
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
        catch {
            for ($i = $createdDirectories.Count - 1; $i -ge 0; $i--) {
                $directory = $createdDirectories[$i]
                if ([System.IO.Directory]::Exists($directory) -and
                    @(Get-ChildItem -LiteralPath $directory -Force).Count -eq 0) {
                    [System.IO.Directory]::Delete($directory)
                }
            }
            throw
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
