function Invoke-AvmBicepTestE2e {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context,

        [switch] $AllowPathFallback,
        [AllowEmptyCollection()]
        [string[]] $Example = @(),
        [switch] $List,
        [switch] $Recurse,
        [string] $SubscriptionId,
        [string] $TenantId,
        [string] $ManagementGroupId,
        [string] $Location,
        [string] $ResourceLocation,
        [string] $ResourceGroupPrefix,
        [string] $TokenFile,
        [System.Collections.IDictionary] $Tokens = @{},
        [string] $ParameterFile,
        [System.Collections.IDictionary] $Parameters = @{},
        [switch] $UseCiInputs,
        [string] $TestSubscriptionIds,
        [ValidateRange(0, [int]::MaxValue)]
        [int] $SubscriptionSelectionSeed = 0,
        [ValidateRange(0, [int]::MaxValue)]
        [int] $SubscriptionJobIndex = 0,
        [ValidateSet('All', 'Deploy', 'Complete')]
        [string] $Phase = 'All',
        [string] $CleanupStatePath,
        [switch] $KeepResources,
        [ValidateRange(1, 3)]
        [int] $DeploymentRetryLimit = 3,
        [ValidateRange(1, 3)]
        [int] $ValidationRetryLimit = 3
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Context.Ecosystem -ne 'bicep') {
        throw [System.ArgumentException]::new('Bicep end-to-end tests require a Bicep module context.')
    }
    $discovered = @(Get-AvmBicepTestCase -Context $Context -Recurse:($Recurse -or $Phase -eq 'Complete'))
    if ($List) {
        $names = @($discovered | Where-Object { -not $_.Ignored } | ForEach-Object { $_.RelativeDirectory })
        return ConvertTo-Json -InputObject $names -Compress
    }
    $state = $null
    if ($Phase -eq 'Complete') {
        if ([string]::IsNullOrWhiteSpace($CleanupStatePath)) {
            throw [AvmConfigurationException]::new('Bicep completion requires -CleanupStatePath.')
        }
        $state = Read-AvmBicepCleanupState -Path $CleanupStatePath
        if (-not $state.Contains('case')) {
            throw [AvmConfigurationException]::new('This cleanup state has no case to complete. Use avm test cleanup instead.')
        }
        $cases = @($discovered | Where-Object { $_.RelativePath -ceq $state['case']['path'] -and -not $_.Ignored })
        if ($cases.Count -ne 1) {
            throw [AvmConfigurationException]::new('The saved case is missing or ignored in this checkout. Use avm test cleanup without running source.')
        }
        if ($Example.Count -gt 0 -or $UseCiInputs -or $Tokens.psbase.Count -gt 0 -or $Parameters.psbase.Count -gt 0 -or
            $TokenFile -or $ParameterFile -or $TestSubscriptionIds -or $ResourceLocation -or $ResourceGroupPrefix -or $ManagementGroupId) {
            throw [AvmConfigurationException]::new('Complete selects its case and deployment inputs from state; do not supply deployment-only options.')
        }
        if ($Location -and ($Location -replace '\s', '').ToLowerInvariant() -cne $state['case']['metadataLocation']) {
            throw [AvmConfigurationException]::new('The completion location must match the saved deployment location.')
        }
        $Location = $state['case']['metadataLocation']
    }
    else {
        $cases = @(Select-AvmBicepTestCase -Cases $discovered -Example $Example)
    }
    $result = [ordered]@{
        Engine = 'bicep'; Tool = 'Az.Resources'; ToolPath = $null; ToolSource = 'PowerShell module'
        BicepTool = $null; Phase = $Phase; Status = 'skipped'; FilesProcessed = 0
        IgnoredFiles = @($discovered | Where-Object Ignored).Count
        RunsTotal = 0; RunsPassed = 0; RunsFailed = 0; RunsSkipped = $cases.Count
        AssertionResults = @(); PostResults = @(); CleanupPending = @(); CleanupStatePaths = @()
        CleanupDeferred = $false; WhatIfChanges = @(); Issues = @()
    }
    if ($cases.Count -eq 0) {
        Write-AvmLog -Level Warning -Message 'No runnable Bicep tests/e2e examples found.'
        return [pscustomobject]$result
    }
    if ($CleanupStatePath -and $cases.Count -ne 1) {
        throw [AvmConfigurationException]::new('An explicit -CleanupStatePath requires exactly one selected Bicep case.')
    }
    if ($ParameterFile -and $Parameters.psbase.Count -gt 0) {
        throw [AvmConfigurationException]::new('Use either -ParameterFile or -Parameters, not both.')
    }
    $ci = Get-AvmBicepWorkflowEnvironment -Enabled:$UseCiInputs
    if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
        $SubscriptionId = $ci.SubscriptionId
        if ([string]::IsNullOrEmpty($TestSubscriptionIds)) { $TestSubscriptionIds = $ci.PoolJson }
    }
    if ([string]::IsNullOrWhiteSpace($TenantId)) { $TenantId = $ci.TenantId }
    $tenant = [guid]::Empty
    if (-not [guid]::TryParseExact($TenantId, 'D', [ref]$tenant) -or $tenant -eq [guid]::Empty) {
        throw [AvmConfigurationException]::new('Bicep e2e requires an explicit, nonempty GUID -TenantId.')
    }
    $selection = Select-AvmBicepWorkflowSubscription -PoolJson $TestSubscriptionIds `
        -FallbackSubscriptionId $SubscriptionId -RandomSeed $SubscriptionSelectionSeed -CaseIndex $SubscriptionJobIndex
    if ($null -ne $state -and ($state['subscriptionId'] -ine $selection.SubscriptionId -or $state['tenantId'] -ine $TenantId)) {
        throw [AvmConfigurationException]::new('Completion state does not match the explicitly selected subscription and tenant.')
    }
    $Location = ($Location -replace '\s', '').ToLowerInvariant()
    if ($Location -cnotmatch '^[a-z0-9]+$') {
        throw [AvmConfigurationException]::new('Bicep e2e requires an explicit Azure -Location for deployment metadata.')
    }
    if ($ResourceGroupPrefix -and ($ResourceGroupPrefix -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,56}$' -or
            $ResourceGroupPrefix.EndsWith('.'))) {
        throw [AvmConfigurationException]::new('Bicep e2e requires a safe -ResourceGroupPrefix of at most 57 characters.')
    }
    if ($ManagementGroupId -and ($ManagementGroupId -cnotmatch '^[A-Za-z0-9_().-]{1,90}$' -or
            $ManagementGroupId.EndsWith('.') -or $ManagementGroupId -in @('.', '..'))) {
        throw [AvmConfigurationException]::new('Bicep e2e -ManagementGroupId must be a safe group name, not an ARM resource ID.')
    }
    $requiredFeatures = if ($Phase -eq 'Complete') { @() } else { @(Get-AvmContextRequiredFeature -Context $Context) }
    if (-not $PSCmdlet.ShouldProcess(
            "$($cases.Count) Bicep case(s) in the explicitly selected test targets", "Run Bicep e2e phase $Phase")) {
        return [pscustomobject]$result
    }
    Assert-AvmBicepAzureDependency
    $az = Get-Command -Name az -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $repoRoot = Get-AvmBicepTestRepositoryRoot -Context $Context
    if ($Phase -eq 'Complete') {
        $item = [pscustomobject]@{
            Case = $cases[0]; Scope = $state['case']['scope']
            AssertionFiles = [string[]]@(Get-AvmBicepE2eAssertionFile -CasePath $cases[0].Path)
        }
        $runs = @(Complete-AvmBicepTestCase -Item $item -StatePath $CleanupStatePath `
                -SubscriptionId $selection.SubscriptionId -TenantId $tenant -RepositoryRoot $repoRoot `
                -AzPath $az.Source -KeepResources:$KeepResources -Confirm:$false)
    }
    else {
        $bicep = Resolve-AvmTool -Name bicep -ModuleRoot $Context.Root -AllowPathFallback:$AllowPathFallback
        $result.BicepTool = "bicep/$($bicep.Version)"
        $runDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('avm-bicep-e2e-{0}' -f [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $runDirectory -ErrorAction Stop
        if (-not $IsWindows) {
            [System.IO.File]::SetUnixFileMode($runDirectory,
                [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite -bor [System.IO.UnixFileMode]::UserExecute)
        }
        $prepared = [System.Collections.Generic.List[object]]::new()
        $runs = [System.Collections.Generic.List[object]]::new()
        try {
            for ($index = 0; $index -lt $cases.Count; $index++) {
                $case = $cases[$index]
                $subscription = Select-AvmBicepWorkflowSubscription -PoolJson $TestSubscriptionIds `
                    -FallbackSubscriptionId $SubscriptionId -RandomSeed $SubscriptionSelectionSeed `
                    -CaseIndex ($SubscriptionJobIndex + $index)
                $runId = [guid]::NewGuid().ToString('N')
                $tokenMap = Get-AvmBicepTestTokenMap -Root $Context.Root -SubscriptionId $subscription.SubscriptionId `
                    -TenantId $TenantId -ManagementGroupId $ManagementGroupId -RunId $runId `
                    -TokenFile $TokenFile -Tokens $Tokens -DefaultTokens $ci.Tokens
                $tokenLocation = if ($tokenMap.ContainsKey('resourceLocation')) { $tokenMap['resourceLocation'] } else { '' }
                $null = $tokenMap.Remove('resourceLocation')
                $templatePath = Join-Path $runDirectory ("$index.json")
                $template = New-AvmBicepTestTemplate -SourcePath $case.Path -DestinationPath $templatePath `
                    -BicepPath $bicep.Path -Tokens $tokenMap -DeferResourceLocation -Confirm:$false
                if ($template.Scope -eq 'group' -and [string]::IsNullOrWhiteSpace($ResourceGroupPrefix)) {
                    throw [AvmConfigurationException]::new('Resource-group Bicep e2e cases require -ResourceGroupPrefix.')
                }
                if ($template.Scope -eq 'mg' -and [string]::IsNullOrWhiteSpace($ManagementGroupId)) {
                    throw [AvmConfigurationException]::new('Management-group Bicep e2e cases require -ManagementGroupId.')
                }
                $parameterPath = New-AvmBicepTestParameterFile -Root $Context.Root `
                    -DestinationPath (Join-Path $runDirectory ("$index-parameters.json")) -Tokens $tokenMap `
                    -ParameterFile $ParameterFile -DeferResourceLocation -Confirm:$false
                $nativeParameters = Get-AvmBicepNativeParameter -ParameterPath $parameterPath -Parameters $Parameters
                $references = @{}
                foreach ($key in @($nativeParameters.psbase.Keys)) {
                    if ($nativeParameters[$key] -is [hashtable] -and $nativeParameters[$key].ContainsKey('reference')) {
                        $references[$key] = $nativeParameters[$key]
                        $nativeParameters.Remove($key)
                    }
                }
                $resourceType = ''
                $metadataPath = Join-Path $case.ModuleRoot 'metadata.json'
                if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
                    $metadata = ConvertFrom-AvmMetadataJson -Json (Read-AvmMetadataJson -Path $metadataPath)
                    if (Test-AvmMetadataResourceType -CanonicalType ([string]$metadata['canonicalType'])) {
                        $resourceType = $metadata['canonicalType']
                    }
                    elseif ($metadata['canonicalType'] -cne 'helper' -and
                        (Get-AvmMetadataModuleType -Context $Context -Path $case.ModuleRoot -Metadata $metadata) -eq 'resource') {
                        throw [AvmConfigurationException]::new("Resource module metadata has an invalid canonicalType: $metadataPath")
                    }
                }
                $prepared.Add([pscustomobject]@{
                        Case = $case; Scope = $template.Scope; SubscriptionId = $subscription.SubscriptionId
                        RunId = $runId; TemplatePath = $templatePath; Template = $template.Template
                        TemplateContent = [System.IO.File]::ReadAllText($templatePath)
                        Parameters = $nativeParameters; ReferenceParameters = $references; RequiredFeatures = $requiredFeatures
                        Tokens = $tokenMap; TokenResourceLocation = $tokenLocation; ResourceType = $resourceType
                        SourceHash      = Get-AvmBicepTestSourceHash -Case $case
                        AssertionFiles  = [string[]]@(Get-AvmBicepE2eAssertionFile -CasePath $case.Path)
                    })
            }
            $featureSubscriptions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($item in $prepared) {
                if ($featureSubscriptions.Contains($item.SubscriptionId)) { $item.RequiredFeatures = @() }
                $run = Invoke-AvmBicepNativeTestCase -Item $item -TenantId $tenant -Location $Location `
                    -RepositoryRoot $repoRoot -AzPath $az.Source -CiInput $ci -ManagementGroupId $ManagementGroupId `
                    -ResourceGroupPrefix $ResourceGroupPrefix -ResourceLocation $ResourceLocation -StatePath $CleanupStatePath `
                    -Phase $Phase -DeploymentRetryLimit $DeploymentRetryLimit -ValidationRetryLimit $ValidationRetryLimit `
                    -KeepResources:$KeepResources -Confirm:$false
                $runs.Add($run)
                if (-not @($run.Issues | Where-Object Code -EQ 'avm.bicep.e2e-feature-registration-failed')) {
                    $null = $featureSubscriptions.Add($item.SubscriptionId)
                }
                if ($run.CleanupPending.Count -gt 0) { break }
            }
        }
        finally {
            foreach ($file in @(Get-ChildItem -LiteralPath $runDirectory -File -Force)) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            }
            Remove-Item -LiteralPath $runDirectory -Force -ErrorAction Stop
        }
    }
    $result.FilesProcessed = $runs.Count
    $result.RunsTotal = $runs.Count
    $result.RunsPassed = @($runs | Where-Object Status -EQ 'pass').Count
    $result.RunsFailed = @($runs | Where-Object Status -EQ 'fail').Count
    $result.RunsSkipped = $cases.Count - $runs.Count
    $result.AssertionResults = @($runs | ForEach-Object { $_.AssertionResults })
    $result.PostResults = @($runs | ForEach-Object { $_.PostResults })
    $result.CleanupPending = @($runs | ForEach-Object { $_.CleanupPending } | Select-Object -Unique)
    $result.CleanupStatePaths = @($runs | ForEach-Object { $_.StatePath })
    $result.CleanupDeferred = @($runs | Where-Object CleanupDeferred).Count -gt 0
    $result.Issues = @($runs | ForEach-Object { $_.Issues })
    $result.Status = if ($result.RunsFailed -gt 0 -or $result.CleanupPending.Count -gt 0) { 'fail' } else { 'pass' }
    return [pscustomobject]$result
}
