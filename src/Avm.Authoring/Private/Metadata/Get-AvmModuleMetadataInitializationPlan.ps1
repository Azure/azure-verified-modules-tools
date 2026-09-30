function Get-AvmModuleMetadataInitializationPlan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $InputObject,

        [Parameter(Mandatory)]
        [ValidateSet('bicep', 'terraform')]
        [string] $Ecosystem,

        [Parameter(Mandatory)]
        [ValidateSet('resource', 'pattern', 'utility')]
        [string] $ModuleType,

        [switch] $ChildModule,

        [switch] $UpdateSource,

        [switch] $CreateDirectory,

        [string[]] $KnownPrefix = @(),

        [switch] $PreserveSourcePrefix,

        [Nullable[bool]] $TelemetryRequired = $null,

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ($UpdateSource -and $Ecosystem -eq 'terraform') {
        throw [AvmNotSupportedException]::new('Terraform -UpdateSource is not supported. Omit -UpdateSource; Terraform telemetry changes belong in a later MaPoTF update.')
    }
    if ($PreserveSourcePrefix -and $Ecosystem -ne 'bicep') {
        throw [AvmNotSupportedException]::new('Preserving a Bicep source prefix requires -Ecosystem bicep.')
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
    if ($PreserveSourcePrefix -and
        -not (Test-Path -LiteralPath (Join-Path -Path $root -ChildPath 'main.bicep') -PathType Leaf)) {
        throw [System.ArgumentException]::new('Preserving a source prefix requires an existing main.bicep.')
    }

    $telemetryRequiredForModule = if ($null -ne $TelemetryRequired) {
        [bool]$TelemetryRequired
    }
    else {
        Test-AvmMetadataTelemetryRequired -Path $root -Ecosystem $Ecosystem -ModuleType $ModuleType -ChildModule:$ChildModule
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
            -Ecosystem $Ecosystem -ModuleType $ModuleType -ChildModule:$ChildModule -UpdateSource:$UpdateSource `
            -PreserveSourcePrefix:$PreserveSourcePrefix -KnownPrefix $KnownPrefix -TelemetryRequired $telemetryRequiredForModule
        ConvertTo-Json -InputObject $inputMetadata -Depth 50
    }
    $validation = Test-AvmMetadataContent -Json $json -Ecosystem $Ecosystem `
        -ModuleType $ModuleType -ChildModule:$ChildModule `
        -TelemetryRequired $telemetryRequiredForModule
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

    return [pscustomobject][ordered]@{
        Root              = $root
        ExistingDirectory = $existingDirectory
        RootExists        = $rootExists
        Metadata          = $validation.Metadata
        Plans             = $plans.ToArray()
    }
}
