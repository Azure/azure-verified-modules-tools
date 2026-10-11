function Invoke-AvmBicepTransform {
    <#
    .SYNOPSIS
        Compile Bicep module sources into their checked-in main.json files.

    .DESCRIPTION
        Discovers root and child modules, including modules/ children, builds
        each main.bicep through the pinned Bicep CLI, and writes main.json
        only when its bytes differ.
        Proposed modules without main.bicep do not need a compiled artifact.
        All builds finish before any files are written. -CheckDrift instead
        reports missing or stale main.json files without changing them.
        README generation and repeatable test scaffolding are separate slices.

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='bicep'.

    .PARAMETER AllowPathFallback
        Permit a PATH-resolved Bicep CLI matching the pinned version.

    .PARAMETER CheckDrift
        Compare compiled JSON without writing any module files.

    .OUTPUTS
        pscustomobject with Engine, Tool, ToolPath, ToolSource, Status,
        FilesProcessed, Changed, Issues.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Context,

        [switch] $AllowPathFallback,

        [switch] $CheckDrift
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Context.Ecosystem -ne 'bicep') {
        throw [System.ArgumentException]::new(
            "Invoke-AvmBicepTransform requires a bicep context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $tool = Resolve-AvmTool -Name 'bicep' -ModuleRoot $Context.Root -AllowPathFallback:$AllowPathFallback
    $scopes = @(Get-AvmMetadataScope -Context $Context -IncludeModuleDirectories)
    $plan = [System.Collections.Generic.List[object]]::new()
    $changed = [System.Collections.Generic.List[string]]::new()
    $issues = [System.Collections.Generic.List[object]]::new()
    $filesProcessed = 0

    foreach ($scope in $scopes) {
        $items = @(Get-ChildItem -LiteralPath $scope.Path -Force)
        $sourceFiles = @($items | Where-Object { $_.Name -ieq 'main.bicep' })
        $compiledFiles = @($items | Where-Object { $_.Name -ieq 'main.json' })
        if ($sourceFiles.Count -gt 0 -and
            ($sourceFiles.Count -ne 1 -or $sourceFiles[0].PSIsContainer -or
            $sourceFiles[0].Name -cne 'main.bicep' -or
            ($sourceFiles[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint))) {
            throw [AvmConfigurationException]::new("Expected a regular main.bicep with exact casing in '$($scope.Path)'.")
        }
        if ($compiledFiles.Count -gt 0 -and
            ($compiledFiles.Count -ne 1 -or $compiledFiles[0].PSIsContainer -or
            $compiledFiles[0].Name -cne 'main.json' -or
            ($compiledFiles[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint))) {
            throw [AvmConfigurationException]::new("Expected a regular main.json with exact casing in '$($scope.Path)'.")
        }
        if ($sourceFiles.Count -eq 0) {
            if ($compiledFiles.Count -gt 0) {
                throw [AvmConfigurationException]::new(
                    "Found main.json without main.bicep in '$($scope.Path)'; remove the stale artifact or restore the source.")
            }
            continue
        }

        $sourcePath = $sourceFiles[0].FullName
        $targetPath = Join-Path -Path $scope.Path -ChildPath 'main.json'
        $compiled = Get-AvmBicepCompiledJson -SourcePath $sourcePath -ToolPath $tool.Path
        $filesProcessed++
        $current = if ($compiledFiles.Count -gt 0) { [System.IO.File]::ReadAllBytes($targetPath) } else { $null }
        $kind = Get-AvmBicepCompiledJsonDrift -CompiledJson $compiled -CurrentBytes $current
        if ($null -eq $kind) {
            continue
        }

        $relative = [System.IO.Path]::GetRelativePath($Context.Root, $targetPath).Replace('\', '/')
        if ($CheckDrift) {
            $issues.Add([pscustomobject][ordered]@{
                    File     = $relative
                    Line     = 0
                    Column   = 0
                    Severity = 'error'
                    Code     = "avm.bicep.json-$kind"
                    Message  = "'$relative' is $kind; run 'avm pre-commit' and commit the generated main.json."
                })
            continue
        }

        $plan.Add([pscustomobject]@{
                Path     = $targetPath
                Original = if ($null -ne $current) { [System.IO.File]::ReadAllText($targetPath) } else { $null }
                Content  = $compiled
            })
    }

    $status = 'pass'
    if ($CheckDrift -and $issues.Count -gt 0) {
        $status = 'fail'
    }
    elseif ($plan.Count -gt 0) {
        $paths = @($plan | ForEach-Object { $_.Path })
        if ($PSCmdlet.ShouldProcess(($paths -join ', '), 'Write compiled Bicep main.json files')) {
            $null = Write-AvmModuleInitializationPlan -Root $Context.Root -Plan $plan.ToArray() -Confirm:$false
            foreach ($path in $paths) {
                $changed.Add($path)
            }
        }
        else {
            $status = 'skipped'
        }
    }

    return [pscustomobject][ordered]@{
        Engine         = 'bicep'
        Tool           = ('{0}/{1}' -f $tool.Name, $tool.Version)
        ToolPath       = $tool.Path
        ToolSource     = $tool.Source
        Status         = $status
        FilesProcessed = $filesProcessed
        Changed        = $changed.ToArray()
        Issues         = $issues.ToArray()
    }
}
