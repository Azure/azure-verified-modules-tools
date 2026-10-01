#Requires -Version 7.4

[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory)]
    [string] $RegistryPath,

    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $RegistryCommit = '6eb8e6ff3fe2910043d184da4192799752271ecf',

    [Parameter(Mandatory, ParameterSetName = 'Probe')]
    [switch] $Probe,

    [Parameter(Mandatory, ParameterSetName = 'Probe')]
    [string] $InstallRoot,

    [Parameter(Mandatory, ParameterSetName = 'Probe')]
    [string] $ModuleVersion,

    [Parameter(Mandatory, ParameterSetName = 'Probe')]
    [string] $ScratchRoot,

    [Parameter(Mandatory, ParameterSetName = 'Probe')]
    [string] $ReportPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Assert-AvmPackageSmoke {
    param(
        [Parameter(Mandatory)]
        [bool] $Condition,

        [Parameter(Mandatory)]
        [string] $Message
    )

    if (-not $Condition) {
        throw [System.InvalidOperationException]::new($Message)
    }
}

function Join-AvmPackageSmokePath {
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [string[]] $Segments
    )

    return [System.IO.Path]::Combine([string[]](@($Root) + $Segments))
}

$registryRoot = (Resolve-Path -LiteralPath $RegistryPath).ProviderPath
$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceCommit = (& git -C $repoRoot rev-parse HEAD).Trim()
Assert-AvmPackageSmoke -Condition ($LASTEXITCODE -eq 0) -Message 'Unable to read the tools source commit.'
$actualCommit = (& git -C $registryRoot rev-parse HEAD).Trim()
Assert-AvmPackageSmoke -Condition ($LASTEXITCODE -eq 0 -and $actualCommit -ceq $RegistryCommit) `
    -Message "Registry checkout must be at $RegistryCommit; found $actualCommit."
$registryStatus = @(& git -C $registryRoot status --porcelain --untracked-files=all)
Assert-AvmPackageSmoke -Condition ($LASTEXITCODE -eq 0 -and $registryStatus.Count -eq 0) `
    -Message 'Registry checkout must be clean before the smoke test.'

if ($Probe) {
    $env:AVM_OFFLINE = '1'
    $env:AVM_NO_AUTO_INSTALL = '1'
    $env:PSModulePath = $InstallRoot + [System.IO.Path]::PathSeparator + (Join-Path $PSHOME 'Modules')
    $expectedModule = Join-AvmPackageSmokePath -Root $InstallRoot -Segments @('Avm.Authoring', $ModuleVersion)
    $module = Import-Module -Name 'Avm.Authoring' -RequiredVersion $ModuleVersion -PassThru -ErrorAction Stop
    Assert-AvmPackageSmoke -Condition ($module.ModuleBase -ceq $expectedModule) `
        -Message "Imported module from '$($module.ModuleBase)', not the extracted package '$expectedModule'."

    $scopes = @(
        @{ Segments = @('avm', 'res', 'azure-stack-hci', 'cluster'); Child = $false; Source = $true }
        @{ Segments = @('avm', 'res', 'azure-stack-hci', 'cluster', 'arc-setting', 'extension'); Child = $true; Source = $false }
        @{ Segments = @('avm', 'res', 'azure-stack-hci', 'logical-network'); Child = $false; Source = $true }
        @{ Segments = @('avm', 'res', 'storage', 'storage-account'); Child = $false; Source = $true }
        @{ Segments = @('avm', 'res', 'storage', 'storage-account', 'blob-service', 'container'); Child = $true; Source = $true }
    )
    $scopeResults = @(
        foreach ($scope in $scopes) {
            $path = Join-AvmPackageSmokePath -Root $registryRoot -Segments $scope.Segments
            $relative = $scope.Segments -join '/'
            $sourcePath = Join-Path $path 'main.bicep'
            Assert-AvmPackageSmoke -Condition ((Test-Path -LiteralPath $sourcePath -PathType Leaf) -eq $scope.Source) `
                -Message "Unexpected main.bicep presence at $relative."
            $result = Test-AvmModuleMetadata -Path $path -Ecosystem bicep -ModuleType resource `
                -ChildModule:$scope.Child -CheckSource -SkipModuleVersionCheck
            Assert-AvmPackageSmoke -Condition ($result.Status -eq 'pass' -and @($result.Issues).Count -eq 0) `
                -Message "Packaged source validation failed at ${relative}: $($result.Issues | ConvertTo-Json -Compress -Depth 4)"
            if ($scope.Source) {
                $source = [System.IO.File]::ReadAllText($sourcePath)
                $literal = & $module { Get-AvmBicepMetadataLiteral -Source $args[0] } $source
                Assert-AvmPackageSmoke -Condition ($literal['description'] -cne $result.Metadata['moduleDescription']) `
                    -Message "Expected independent source and JSON descriptions at $relative."
                $wiring = & $module { Test-AvmBicepTelemetrySourceWiring -Source $args[0] } $source
                Assert-AvmPackageSmoke -Condition ($wiring -and $source.Contains("var telemetryIdPrefix = loadJsonContent('metadata.json', 'telemetryIdPrefix')")) `
                    -Message "Expected the registry's canonical telemetry reader at $relative."
                $plan = @(& $module { Get-AvmMetadataSourcePlan -Path $args[0] -Metadata $args[1] } $path $result.Metadata)
                Assert-AvmPackageSmoke -Condition ($plan.Count -eq 0) `
                    -Message "Packaged source planner would rewrite canonical source at $relative."
            }
            else {
                foreach ($marker in @('version.json', 'main.json')) {
                    Assert-AvmPackageSmoke -Condition (-not (Test-Path -LiteralPath (Join-Path $path $marker))) `
                        -Message "The metadata-only scope unexpectedly contains $marker at $relative."
                }
            }
            [pscustomobject]@{
                Path                   = $relative
                Status                 = $result.Status
                Issues                 = @($result.Issues).Count
                Source                 = $scope.Source
                DescriptionIndependent = $scope.Source
            }
        }
    )

    $rootCases = @(
        @{ Name = 'sparse monorepo'; Segments = @(); Expected = 22 }
        @{ Name = 'HCI cluster'; Segments = @('avm', 'res', 'azure-stack-hci', 'cluster'); Expected = 3 }
        @{ Name = 'HCI logical network'; Segments = @('avm', 'res', 'azure-stack-hci', 'logical-network'); Expected = 1 }
        @{ Name = 'storage account'; Segments = @('avm', 'res', 'storage', 'storage-account'); Expected = 14 }
    )
    $stepResults = @(
        foreach ($case in $rootCases) {
            $path = if ($case.Segments.Count -gt 0) {
                Join-AvmPackageSmokePath -Root $registryRoot -Segments $case.Segments
            }
            else {
                $registryRoot
            }
            $context = Get-AvmModuleContext -Path $path -Ecosystem bicep -SkipModuleVersionCheck
            $discovered = @(& $module { Get-AvmMetadataScope -Context $args[0] } $context)
            Assert-AvmPackageSmoke -Condition ($discovered.Count -eq $case.Expected) `
                -Message "Metadata discovery at $($case.Name) found $($discovered.Count) scopes, expected $($case.Expected)."
            $step = & $module { Test-AvmMetadataModules -Context $args[0] } $context
            Assert-AvmPackageSmoke -Condition ($step.Status -eq 'pass' -and @($step.Issues).Count -eq 0) `
                -Message "Packaged pre-commit metadata step failed at $($case.Name): $($step.Issues | ConvertTo-Json -Compress -Depth 4)"
            [pscustomobject]@{ Root = $case.Name; Scopes = $discovered.Count; Status = $step.Status; Issues = @($step.Issues).Count }
        }
    )

    $storageRoot = Join-AvmPackageSmokePath -Root $registryRoot `
        -Segments @('avm', 'res', 'storage', 'storage-account')
    $source = [System.IO.File]::ReadAllText((Join-Path $storageRoot 'main.bicep'))
    $metadata = (Get-Content -LiteralPath (Join-Path $storageRoot 'metadata.json') -Raw | ConvertFrom-Json -AsHashtable)
    $canonicalDeclaration = "var telemetryIdPrefix = loadJsonContent('metadata.json', 'telemetryIdPrefix')"
    $canonicalReference = '${telemetryIdPrefix}'
    Assert-AvmPackageSmoke -Condition ($source.Contains($canonicalDeclaration) -and $source.Contains($canonicalReference)) `
        -Message 'The pinned storage source no longer contains the canonical wiring.'
    $fixture = Join-Path $ScratchRoot 'source-forms'
    $null = New-Item -ItemType Directory -Path $fixture
    Copy-Item -LiteralPath (Join-Path $storageRoot 'metadata.json') -Destination $fixture
    $fixtureSource = Join-Path $fixture 'main.bicep'

    $legacySource = $source.Replace($canonicalDeclaration, "var avmTelemetryIdPrefix = loadJsonContent('metadata.json', '$.telemetryIdPrefix')")
    $legacySource = $legacySource.Replace($canonicalReference, '${avmTelemetryIdPrefix}')
    [System.IO.File]::WriteAllText($fixtureSource, $legacySource, [System.Text.UTF8Encoding]::new($false))
    $legacyHash = (Get-FileHash -LiteralPath $fixtureSource -Algorithm SHA256).Hash
    $legacyResult = Test-AvmModuleMetadata -Path $fixture -Ecosystem bicep -ModuleType resource `
        -CheckSource -SkipModuleVersionCheck
    Assert-AvmPackageSmoke -Condition ($legacyResult.Status -eq 'pass' -and @($legacyResult.Issues).Count -eq 0) `
        -Message 'The packaged validator rejected legacy telemetry source wiring.'
    $legacyPlan = @(& $module { Get-AvmMetadataSourcePlan -Path $args[0] -Metadata $args[1] } $fixture $legacyResult.Metadata)
    Assert-AvmPackageSmoke -Condition ($legacyPlan.Count -eq 0) `
        -Message 'The packaged planner would migrate legacy source wiring.'
    $preview = Initialize-AvmModuleMetadata -Path $fixture -Ecosystem bicep -ModuleType resource `
        -UpdateSource -SkipModuleVersionCheck -WhatIf
    Assert-AvmPackageSmoke -Condition ($preview.Status -eq 'pass' -and @($preview.PlannedFiles).Count -eq 0 -and
        -not $preview.Changed -and (Get-FileHash -LiteralPath $fixtureSource -Algorithm SHA256).Hash -eq $legacyHash) `
        -Message 'Legacy source changed or produced a write plan under -UpdateSource -WhatIf.'

    $literalSource = $source.Replace($canonicalDeclaration, '').Replace($canonicalReference, $metadata.telemetryIdPrefix)
    [System.IO.File]::WriteAllText($fixtureSource, $literalSource, [System.Text.UTF8Encoding]::new($false))
    $generated = @(& $module { Get-AvmMetadataSourcePlan -Path $args[0] -Metadata $args[1] } $fixture $legacyResult.Metadata)
    Assert-AvmPackageSmoke -Condition ($generated.Count -eq 1 -and
        $generated[0].Content.Contains($canonicalDeclaration) -and
        $generated[0].Content.Contains($canonicalReference) -and
        -not $generated[0].Content.Contains('avmTelemetryIdPrefix')) `
        -Message 'New source wiring did not plan the canonical telemetry reader.'
    $originalLiterals = & $module { Get-AvmBicepMetadataLiteral -Source $args[0] } $source
    $plannedLiterals = & $module { Get-AvmBicepMetadataLiteral -Source $args[0] } $generated[0].Content
    Assert-AvmPackageSmoke -Condition ($plannedLiterals['name'] -ceq $originalLiterals['name'] -and
        $plannedLiterals['description'] -ceq $originalLiterals['description']) `
        -Message 'New telemetry wiring altered authored name or description literals.'

    $conflictSource = $source.Replace($canonicalDeclaration, "var telemetryIdPrefix = 'overridden'")
    [System.IO.File]::WriteAllText($fixtureSource, $conflictSource, [System.Text.UTF8Encoding]::new($false))
    $collisionRejected = $false
    try {
        $null = & $module { Get-AvmMetadataSourcePlan -Path $args[0] -Metadata $args[1] } $fixture $legacyResult.Metadata
    }
    catch [System.ArgumentException] {
        $collisionRejected = $_.Exception.Message -like '*already defines telemetryIdPrefix differently*'
        if (-not $collisionRejected) { throw }
    }
    Assert-AvmPackageSmoke -Condition $collisionRejected -Message 'Conflicting telemetry variables must fail closed.'

    foreach ($literalName in @('name', 'description')) {
        $literalPattern = [regex]::new(("(?m)^[\t ]*metadata[\t ]+{0}[^\r\n]*(?:\r?\n)?" -f $literalName))
        $invalidSource = $literalPattern.Replace($source, '', 1)
        [System.IO.File]::WriteAllText($fixtureSource, $invalidSource, [System.Text.UTF8Encoding]::new($false))
        $invalidLiteral = Test-AvmModuleMetadata -Path $fixture -Ecosystem bicep -ModuleType resource `
            -CheckSource -SkipModuleVersionCheck
        Assert-AvmPackageSmoke -Condition ($invalidLiteral.Status -eq 'fail' -and
            @($invalidLiteral.Issues | Where-Object { $_.Code -eq 'AVM_METADATA_SOURCE' }).Count -gt 0) `
            -Message "A missing Bicep $literalName literal was not rejected."
    }
    Remove-Item -LiteralPath $fixtureSource
    foreach ($marker in @('version.json', 'main.json')) {
        $markerPath = Join-Path $fixture $marker
        [System.IO.File]::WriteAllText($markerPath, "{}`n", [System.Text.UTF8Encoding]::new($false))
        $missingSource = Test-AvmModuleMetadata -Path $fixture -Ecosystem bicep -ModuleType resource `
            -CheckSource -SkipModuleVersionCheck
        Assert-AvmPackageSmoke -Condition ($missingSource.Status -eq 'fail' -and
            @($missingSource.Issues | Where-Object { $_.Code -eq 'AVM_METADATA_SOURCE' }).Count -gt 0) `
            -Message "Missing source with $marker was not rejected."
        Remove-Item -LiteralPath $markerPath
    }

    $utilityMetadata = $metadata.Clone()
    $utilityMetadata['canonicalType'] = 'naming'
    $utilityMetadata.Remove('telemetryIdPrefix')
    $utilityMetadata.Remove('alternativeTelemetryIdPrefixes')
    [System.IO.File]::WriteAllText((Join-Path $fixture 'metadata.json'),
        (ConvertTo-Json -InputObject $utilityMetadata -Depth 20), [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($fixtureSource, $source, [System.Text.UTF8Encoding]::new($false))
    $missingTelemetry = Test-AvmModuleMetadata -Path $fixture -Ecosystem bicep -ModuleType utility `
        -CheckSource -SkipModuleVersionCheck
    Assert-AvmPackageSmoke -Condition ($missingTelemetry.Status -eq 'fail' -and
        @($missingTelemetry.Issues | Where-Object { $_.Code -eq 'AVM_METADATA_TELEMETRY' }).Count -gt 0) `
        -Message 'An instrumented utility without a JSON telemetry prefix was not rejected.'

    $report = [pscustomobject]@{
        PackageVersion    = $module.Version.ToString()
        ImportedFrom      = 'isolated versioned PSModulePath'
        Scopes            = $scopeResults
        MetadataSteps     = $stepResults
        LegacyIdempotent  = $true
        CanonicalNewWires = $true
        CollisionRejected = $true
        SourceControls    = 'missing name/description literals, version.json, main.json, telemetry prefix rejected'
    }
    [System.IO.File]::WriteAllText($ReportPath, (ConvertTo-Json -InputObject $report -Depth 8),
        [System.Text.UTF8Encoding]::new($false))
    return
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("avm-bicep-metadata-package-$([guid]::NewGuid().ToString('N'))")
$previousOffline = $env:AVM_OFFLINE
$previousAutoInstall = $env:AVM_NO_AUTO_INSTALL
$env:AVM_OFFLINE = '1'
$env:AVM_NO_AUTO_INSTALL = '1'
try {
    $null = New-Item -ItemType Directory -Path $tempRoot
    & (Join-Path $repoRoot 'build.ps1') build
    $stage = Join-AvmPackageSmokePath -Root $repoRoot -Segments @('out', 'Avm.Authoring')
    $manifest = Test-ModuleManifest -Path (Join-Path $stage 'Avm.Authoring.psd1')
    $moduleVersion = $manifest.Version.ToString()
    $archive = Join-Path $tempRoot 'Avm.Authoring-local.zip'
    Compress-Archive -LiteralPath $stage -DestinationPath $archive
    $extracted = Join-Path $tempRoot 'extracted'
    Expand-Archive -LiteralPath $archive -DestinationPath $extracted
    $installRoot = Join-Path $tempRoot 'modules'
    $moduleParent = Join-Path $installRoot 'Avm.Authoring'
    $null = New-Item -ItemType Directory -Path $moduleParent
    $installPath = Join-Path $moduleParent $moduleVersion
    Move-Item -LiteralPath (Join-Path $extracted 'Avm.Authoring') -Destination $installPath
    $scratchRoot = Join-Path $tempRoot 'scratch'
    $null = New-Item -ItemType Directory -Path $scratchRoot
    $reportPath = Join-Path $tempRoot 'result.json'
    $pwsh = (Get-Process -Id $PID).Path
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-File', $PSCommandPath,
        '-Probe', '-RegistryPath', $registryRoot, '-RegistryCommit', $RegistryCommit,
        '-InstallRoot', $installRoot, '-ModuleVersion', $moduleVersion,
        '-ScratchRoot', $scratchRoot, '-ReportPath', $reportPath
    )
    $output = @(& $pwsh @arguments 2>&1)
    Assert-AvmPackageSmoke -Condition ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $reportPath -PathType Leaf)) `
        -Message "Packaged metadata probe failed: $($output -join [System.Environment]::NewLine)"
    $registryStatus = @(& git -C $registryRoot status --porcelain --untracked-files=all)
    Assert-AvmPackageSmoke -Condition ($LASTEXITCODE -eq 0 -and $registryStatus.Count -eq 0) `
        -Message 'The metadata probe changed the pinned registry checkout.'
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    [pscustomobject]@{
        ToolsCommit       = $sourceCommit
        RegistryCommit    = $actualCommit
        PackageKind       = 'local unsigned zip from build.ps1 build; not a signed release'
        ArchiveSha256     = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        PackageVersion    = $report.PackageVersion
        ImportedFrom      = $report.ImportedFrom
        Scopes            = $report.Scopes
        MetadataSteps     = $report.MetadataSteps
        LegacyIdempotent  = $report.LegacyIdempotent
        CanonicalNewWires = $report.CanonicalNewWires
        CollisionRejected = $report.CollisionRejected
        SourceControls    = $report.SourceControls
        RegistryClean     = $true
        Offline           = $true
        FullPreCommitRun  = $false
    } | ConvertTo-Json -Depth 8
}
finally {
    if ($null -eq $previousOffline) {
        Remove-Item Env:AVM_OFFLINE -ErrorAction SilentlyContinue
    }
    else {
        $env:AVM_OFFLINE = $previousOffline
    }
    if ($null -eq $previousAutoInstall) {
        Remove-Item Env:AVM_NO_AUTO_INSTALL -ErrorAction SilentlyContinue
    }
    else {
        $env:AVM_NO_AUTO_INSTALL = $previousAutoInstall
    }
    if (Test-Path -LiteralPath $tempRoot -PathType Container) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
