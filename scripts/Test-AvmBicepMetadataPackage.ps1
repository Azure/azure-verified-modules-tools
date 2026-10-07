#Requires -Version 7.4

[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory)]
    [string] $RegistryPath,

    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $RegistryCommit = '6eb8e6ff3fe2910043d184da4192799752271ecf',

    [string] $DocsRegistryPath = '',

    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $DocsRegistryCommit = '82bab0404566557b9fb5efdc9780bb5ce438030b',

    [Parameter(ParameterSetName = 'Run')]
    [string] $ArtifactDirectory = '',

    [switch] $AllowWorkingTree,

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
$yamlPin = [version]((Get-Content -LiteralPath (Join-Path $repoRoot 'src' 'Avm.Authoring' 'Resources' 'avm.pins.jsonc') -Raw |
        ConvertFrom-Json -AsHashtable)['powerShellModules']['powershell-yaml']['version'])
$sourceCommit = (& git -C $repoRoot rev-parse HEAD).Trim()
Assert-AvmPackageSmoke -Condition ($LASTEXITCODE -eq 0) -Message 'Unable to read the tools source commit.'
$sourceStatus = @(& git -C $repoRoot status --porcelain --untracked-files=all -- src/Avm.Authoring)
Assert-AvmPackageSmoke -Condition ($LASTEXITCODE -eq 0 -and ($sourceStatus.Count -eq 0 -or $AllowWorkingTree)) `
    -Message 'The packaged module source must match the recorded tools commit; use -AllowWorkingTree to explicitly qualify and record uncommitted module changes.'
$actualCommit = (& git -C $registryRoot rev-parse HEAD).Trim()
Assert-AvmPackageSmoke -Condition ($LASTEXITCODE -eq 0 -and $actualCommit -ceq $RegistryCommit) `
    -Message "Registry checkout must be at $RegistryCommit; found $actualCommit."
$registryStatus = @(& git -C $registryRoot status --porcelain --untracked-files=all)
Assert-AvmPackageSmoke -Condition ($LASTEXITCODE -eq 0 -and $registryStatus.Count -eq 0) `
    -Message 'Registry checkout must be clean before the smoke test.'
$docsRoot = ''
if ($DocsRegistryPath) {
    $docsRoot = (Resolve-Path -LiteralPath $DocsRegistryPath).ProviderPath
    $actualDocsCommit = (& git -C $docsRoot rev-parse HEAD).Trim()
    Assert-AvmPackageSmoke -Condition ($LASTEXITCODE -eq 0 -and $actualDocsCommit -ceq $DocsRegistryCommit) `
        -Message "Docs checkout must be at $DocsRegistryCommit; found $actualDocsCommit."
    $docsStatus = @(& git -C $docsRoot status --porcelain --untracked-files=all)
    Assert-AvmPackageSmoke -Condition ($LASTEXITCODE -eq 0 -and $docsStatus.Count -eq 0) `
        -Message 'Docs checkout must be clean before the smoke test.'
}

if ($Probe) {
    $env:AVM_OFFLINE = '1'
    $env:AVM_NO_AUTO_INSTALL = '1'
    $env:PSModulePath = $InstallRoot + [System.IO.Path]::PathSeparator + (Join-Path $PSHOME 'Modules')
    $expectedModule = Join-AvmPackageSmokePath -Root $InstallRoot -Segments @('Avm.Authoring', $ModuleVersion)
    $module = Import-Module -Name 'Avm.Authoring' -RequiredVersion $ModuleVersion -PassThru -ErrorAction Stop
    Assert-AvmPackageSmoke -Condition ($module.ModuleBase -ceq $expectedModule) `
        -Message "Imported module from '$($module.ModuleBase)', not the extracted package '$expectedModule'."
    Assert-AvmPackageSmoke -Condition ($module.Path -ceq (Join-Path $expectedModule 'Avm.Authoring.psm1')) `
        -Message 'The imported root module is not inside the extracted package.'
    $privateNames = @(
        'Get-AvmBicepMetadataLiteral', 'Get-AvmMetadataSourcePlan', 'Test-AvmBicepTelemetrySourceWiring',
        'Test-AvmMetadataModules', 'Invoke-AvmBicepDocs', 'Invoke-AvmBicepCheckPolicy',
        'Invoke-AvmBicepCheckConvention', 'Invoke-AvmBicepConventionSuite', 'Invoke-AvmBicepTestUnit', 'Invoke-AvmBicepPesterSuite',
        'Get-AvmBicepE2ePostHook', 'Invoke-AvmBicepE2ePostHook',
        'Get-AvmBicepApiSpecList', 'Get-AvmBicepMcrTagList'
    )
    $commands = @($module.ExportedFunctions.Values) + @(
        & $module {
            param($Names)
            foreach ($name in $Names) {
                Get-Command -Name $name -CommandType Function -ErrorAction Stop
            }
        } $privateNames
    )
    $commandProof = @(
        foreach ($command in $commands) {
            $file = $command.ScriptBlock.File
            Assert-AvmPackageSmoke -Condition (-not [string]::IsNullOrWhiteSpace($file) -and
                $file.StartsWith($expectedModule + [System.IO.Path]::DirectorySeparatorChar,
                    [System.StringComparison]::Ordinal)) `
                -Message "Command '$($command.Name)' is not defined inside the extracted package."
            [pscustomobject]@{ Name = $command.Name; File = $file }
        }
    )
    Assert-AvmPackageSmoke -Condition ($module.ExportedAliases['avm'].Definition -ceq 'Invoke-Avm') `
        -Message 'The packaged avm alias does not route to Invoke-Avm.'
    $runner = Join-AvmPackageSmokePath -Root $expectedModule `
        -Segments @('Resources', 'bicep', 'Invoke-AvmPesterSuite.ps1')
    Assert-AvmPackageSmoke -Condition (Test-Path -LiteralPath $runner -PathType Leaf) `
        -Message 'The package omitted the child Pester runner.'
    $conventions = Join-AvmPackageSmokePath -Root $expectedModule -Segments @('Resources', 'bicep', 'conventions')
    $conventionRules = @(Get-ChildItem -LiteralPath (Join-Path $conventions 'rules') -Filter 'Test-AvmBicepConvention*.ps1' -File -ErrorAction SilentlyContinue)
    Assert-AvmPackageSmoke -Condition ((Test-Path -LiteralPath (Join-Path $conventions 'Conventions.Tests.ps1') -PathType Leaf) -and
        $conventionRules.Count -eq 12) `
        -Message "The package omitted the convention Pester suite or its rules ($($conventionRules.Count) of 12 rules)."
    $settings = Join-AvmPackageSmokePath -Root $expectedModule -Segments @('Resources', 'bicep', 'settings.json')
    Assert-AvmPackageSmoke -Condition ((Test-Path -LiteralPath $settings -PathType Leaf) -and
        (& $module { (Get-AvmBicepConfiguration)['e2e']['ownershipTag'] }) -ceq 'avm-e2e-run-id' -and
        (& $module { Get-AvmPowerShellModulePin -Name 'powershell-yaml' }) -eq $yamlPin) `
        -Message 'The package omitted or could not resolve its Bicep settings and PowerShell module pins.'
    $negativeCases = [System.Collections.Generic.List[object]]::new()

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
    $legacyWrite = Initialize-AvmModuleMetadata -Path $fixture -Ecosystem bicep -ModuleType resource `
        -UpdateSource -SkipModuleVersionCheck -Confirm:$false
    Assert-AvmPackageSmoke -Condition ($legacyWrite.Status -eq 'pass' -and -not $legacyWrite.Changed -and
        (Get-FileHash -LiteralPath $fixtureSource -Algorithm SHA256).Hash -ceq $legacyHash) `
        -Message 'The packaged initialization command rewrote existing legacy telemetry.'

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
    $wired = Initialize-AvmModuleMetadata -Path $fixture -Ecosystem bicep -ModuleType resource `
        -UpdateSource -SkipModuleVersionCheck -Confirm:$false
    Assert-AvmPackageSmoke -Condition ($wired.Status -eq 'pass' -and $wired.Changed -and
        [System.IO.File]::ReadAllText($fixtureSource) -ceq $generated[0].Content) `
        -Message 'The packaged initialization command did not apply the canonical source plan.'

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
    $negativeCases.Add([pscustomobject]@{ Case = 'conflicting telemetry variable'; Rejected = $collisionRejected })

    foreach ($literalName in @('name', 'description')) {
        $literalPattern = [regex]::new(("(?m)^[\t ]*metadata[\t ]+{0}[^\r\n]*(?:\r?\n)?" -f $literalName))
        $invalidSource = $literalPattern.Replace($source, '', 1)
        [System.IO.File]::WriteAllText($fixtureSource, $invalidSource, [System.Text.UTF8Encoding]::new($false))
        $invalidLiteral = Test-AvmModuleMetadata -Path $fixture -Ecosystem bicep -ModuleType resource `
            -CheckSource -SkipModuleVersionCheck
        Assert-AvmPackageSmoke -Condition ($invalidLiteral.Status -eq 'fail' -and
            @($invalidLiteral.Issues | Where-Object { $_.Code -eq 'AVM_METADATA_SOURCE' }).Count -gt 0) `
            -Message "A missing Bicep $literalName literal was not rejected."
        $negativeCases.Add([pscustomobject]@{
                Case = "missing source $literalName"; Status = $invalidLiteral.Status; Code = 'AVM_METADATA_SOURCE'
            })
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
        $negativeCases.Add([pscustomobject]@{
                Case = "$marker without source"; Status = $missingSource.Status; Code = 'AVM_METADATA_SOURCE'
            })
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
    $negativeCases.Add([pscustomobject]@{
            Case = 'instrumented utility without prefix'; Status = $missingTelemetry.Status; Code = 'AVM_METADATA_TELEMETRY'
        })

    $docsReport = $null
    $contractReport = $null
    if ($docsRoot) {
        $docsReport = & (Join-Path $PSScriptRoot 'Test-AvmBicepPackageDocs.ps1') `
            -RegistryPath $docsRoot -RegistryCommit $DocsRegistryCommit `
            -PackageRoot $expectedModule -ModuleVersion $ModuleVersion
        $contractPath = Join-Path $ScratchRoot 'contracts.json'
        $contractProcess = & $module {
            param($Script, $Root, $Version, $Report)
            Invoke-AvmProcess -FilePath ([System.Environment]::ProcessPath) -ArgumentList @(
                '-NoProfile', '-NonInteractive', '-File', $Script,
                '-InstallRoot', $Root, '-ModuleVersion', $Version, '-ReportPath', $Report
            ) -IgnoreExitCode
        } (Join-Path $PSScriptRoot 'Test-AvmBicepPackageContracts.ps1') $InstallRoot $ModuleVersion $contractPath
        Assert-AvmPackageSmoke -Condition ($contractProcess.ExitCode -eq 0 -and
            (Test-Path -LiteralPath $contractPath -PathType Leaf)) `
            -Message "Packaged fixture contracts failed: $($contractProcess.StdErr)`n$($contractProcess.StdOut)"
        $contractReport = Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json
    }

    $report = [pscustomobject]@{
        PackageVersion     = $module.Version.ToString()
        ImportedFrom       = 'isolated versioned PSModulePath'
        ModulePath         = $module.Path
        ModuleBase         = $module.ModuleBase
        ProcessId          = $PID
        CommandDefinitions = $commandProof
        PesterRunner       = $runner
        PesterRunnerSha256 = (Get-FileHash -LiteralPath $runner -Algorithm SHA256).Hash.ToLowerInvariant()
        Scopes             = $scopeResults
        MetadataSteps      = $stepResults
        LegacyIdempotent   = $true
        CanonicalNewWires  = $true
        CollisionRejected  = $true
        SourceControls     = 'missing name/description literals, version.json, main.json, telemetry prefix rejected'
        NegativeCases      = $negativeCases.ToArray()
        RealDocs           = $docsReport
        FixtureContracts   = $contractReport
    }
    [System.IO.File]::WriteAllText($ReportPath, (ConvertTo-Json -InputObject $report -Depth 8),
        [System.Text.UTF8Encoding]::new($false))
    return
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("avm-bicep-metadata-package-$([guid]::NewGuid().ToString('N'))")
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
    $stageFiles = @(Get-ChildItem -LiteralPath $stage -File -Recurse -Force)
    $installedFiles = @(Get-ChildItem -LiteralPath $installPath -File -Recurse -Force)
    Assert-AvmPackageSmoke -Condition ($stageFiles.Count -eq $installedFiles.Count) `
        -Message 'The extracted package does not contain every staged module file.'
    foreach ($file in $stageFiles) {
        $relative = [System.IO.Path]::GetRelativePath($stage, $file.FullName)
        $installedFile = Join-Path $installPath $relative
        Assert-AvmPackageSmoke -Condition ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ceq
            (Get-FileHash -LiteralPath $installedFile -Algorithm SHA256).Hash) `
            -Message "The extracted package changed staged bytes at '$relative'."
    }
    $dependencies = @()
    if ($docsRoot) {
        $dependencies = @(
            foreach ($name in @('InvokeBuild', 'Pester', 'powershell-yaml')) {
                $available = @(Get-Module -ListAvailable -Name $name | Sort-Object Version -Descending)
                $dependency = $available | Where-Object {
                    ($name -ne 'Pester' -or $_.Version -ge [version]'5.5.0') -and
                    ($name -ne 'powershell-yaml' -or $_.Version -eq $yamlPin)
                } | Select-Object -First 1
                Assert-AvmPackageSmoke -Condition ($null -ne $dependency) `
                    -Message "Required local test dependency '$name' is missing; run the standard focused selectors first."
                $dependencyParent = Join-Path $installRoot $name
                $null = New-Item -ItemType Directory -Path $dependencyParent
                $dependencyPath = Join-Path $dependencyParent $dependency.Version.ToString()
                Copy-Item -LiteralPath $dependency.ModuleBase -Destination $dependencyPath -Recurse
                [pscustomobject]@{ Name = $name; Version = $dependency.Version.ToString(); Path = $dependencyPath }
            }
        )
    }
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
    if ($docsRoot) {
        $arguments += @('-DocsRegistryPath', $docsRoot, '-DocsRegistryCommit', $DocsRegistryCommit)
    }
    if ($AllowWorkingTree) {
        $arguments += '-AllowWorkingTree'
    }
    $output = @(& $pwsh @arguments 2>&1)
    Assert-AvmPackageSmoke -Condition ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $reportPath -PathType Leaf)) `
        -Message "Packaged metadata probe failed: $($output -join [System.Environment]::NewLine)"
    $registryStatus = @(& git -C $registryRoot status --porcelain --untracked-files=all)
    Assert-AvmPackageSmoke -Condition ($LASTEXITCODE -eq 0 -and $registryStatus.Count -eq 0) `
        -Message 'The metadata probe changed the pinned registry checkout.'
    if ($docsRoot) {
        $docsStatus = @(& git -C $docsRoot status --porcelain --untracked-files=all)
        Assert-AvmPackageSmoke -Condition ($LASTEXITCODE -eq 0 -and $docsStatus.Count -eq 0) `
            -Message 'The docs probe changed the pinned registry checkout.'
    }
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    $archivePath = $null
    if ($ArtifactDirectory) {
        $null = New-Item -ItemType Directory -Path $ArtifactDirectory -Force
        $archivePath = Join-Path $ArtifactDirectory "Avm.Authoring-$moduleVersion-$($sourceCommit.Substring(0, 7))-local.zip"
        Assert-AvmPackageSmoke -Condition (-not (Test-Path -LiteralPath $archivePath)) `
            -Message 'The requested artifact already exists; choose an empty artifact directory.'
        Copy-Item -LiteralPath $archive -Destination $archivePath
    }
    $qualification = [pscustomobject]@{
        ToolsCommit         = $sourceCommit
        SourceBoundary      = if ($sourceStatus.Count -eq 0) { 'committed module source' } else { 'explicit working-tree module changes on ToolsCommit' }
        SourceChanges       = $sourceStatus
        RegistryCommit      = $actualCommit
        PackageKind         = 'local unsigned zip from build.ps1 build; not a signed release'
        ArchiveSha256       = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        ArchivePath         = $archivePath
        PayloadFiles        = $stageFiles.Count
        ManifestSha256      = (Get-FileHash -LiteralPath (Join-Path $installPath 'Avm.Authoring.psd1') -Algorithm SHA256).Hash.ToLowerInvariant()
        PackageVersion      = $report.PackageVersion
        ImportedFrom        = $report.ImportedFrom
        ModulePath          = $report.ModulePath
        ModuleBase          = $report.ModuleBase
        ProcessId           = $report.ProcessId
        CommandDefinitions  = $report.CommandDefinitions
        PesterRunner        = $report.PesterRunner
        PesterRunnerSha256  = $report.PesterRunnerSha256
        TestDependencies    = $dependencies
        Scopes              = $report.Scopes
        MetadataSteps       = $report.MetadataSteps
        LegacyIdempotent    = $report.LegacyIdempotent
        CanonicalNewWires   = $report.CanonicalNewWires
        CollisionRejected   = $report.CollisionRejected
        SourceControls      = $report.SourceControls
        NegativeCases       = $report.NegativeCases
        RealDocs            = $report.RealDocs
        FixtureContracts    = $report.FixtureContracts
        RegistryClean       = $true
        Offline             = $true
        FullPreCommitRun    = $false
        FullRegistryPrCheck = $false
        PublishedRelease    = $false
        LiveDeployment      = $false
    }
    $json = ConvertTo-Json -InputObject $qualification -Depth 10
    if ($ArtifactDirectory) {
        [System.IO.File]::WriteAllText((Join-Path $ArtifactDirectory 'qualification.json'), $json,
            [System.Text.UTF8Encoding]::new($false))
    }
    $json
}
finally {
    if (Test-Path -LiteralPath $tempRoot -PathType Container) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
