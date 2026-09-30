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

        [string] $ResourceGroupPrefix,

        [string] $TokenFile,

        [System.Collections.IDictionary] $Tokens = @{},

        [string] $ParameterFile,

        [System.Collections.IDictionary] $Parameters = @{}
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Context.Ecosystem -ne 'bicep') {
        throw [System.ArgumentException]::new('Bicep end-to-end tests require a Bicep module context.')
    }
    $discovered = @(Get-AvmBicepTestCase -Context $Context -Recurse:$Recurse)
    if ($List) {
        $names = @($discovered | Where-Object { -not $_.Ignored } |
                ForEach-Object { $_.RelativeDirectory })
        return ('[{0}]' -f (($names | ForEach-Object {
                        ConvertTo-Json -InputObject $_ -Compress
                    }) -join ','))
    }

    $cases = @(Select-AvmBicepTestCase -Cases $discovered -Example $Example)
    $ignored = @($discovered | Where-Object { $_.Ignored }).Count
    $empty = [ordered]@{
        Engine           = 'bicep'
        Tool             = 'az'
        ToolPath         = $null
        ToolSource       = 'PATH'
        Status           = 'skipped'
        FilesProcessed   = 0
        IgnoredFiles     = $ignored
        RunsTotal        = 0
        RunsPassed       = 0
        RunsFailed       = 0
        RunsSkipped      = 0
        AssertionResults = @()
        CleanupPending   = @()
        WhatIfChanges    = @()
        Issues           = @()
    }
    if ($cases.Count -eq 0) {
        Write-AvmLog 'no runnable Bicep tests/e2e examples found' -Level Warning
        return [pscustomobject]$empty
    }

    $subscription = [guid]::Empty
    if (-not [guid]::TryParse($SubscriptionId, [ref]$subscription) -or
        $subscription -eq [guid]::Empty) {
        throw [AvmConfigurationException]::new(
            'Bicep e2e requires an explicit, nonempty GUID -SubscriptionId.')
    }
    $SubscriptionId = $subscription.ToString('D')
    if ([string]::IsNullOrWhiteSpace($Location)) {
        throw [AvmConfigurationException]::new('Bicep e2e requires an explicit -Location.')
    }
    $prefixTooLong = -not [string]::IsNullOrWhiteSpace($ResourceGroupPrefix) -and $ResourceGroupPrefix.Length -gt 57
    $prefixHasInvalidCharacters = $ResourceGroupPrefix -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$'
    if (-not [string]::IsNullOrWhiteSpace($ResourceGroupPrefix) -and
        ($prefixTooLong -or $prefixHasInvalidCharacters)) {
        throw [AvmConfigurationException]::new(
            'Bicep e2e requires a safe -ResourceGroupPrefix (1-57 letters, digits, underscores, dots or hyphens).')
    }
    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
        $tenant = [guid]::Empty
        if (-not [guid]::TryParse($TenantId, [ref]$tenant) -or $tenant -eq [guid]::Empty) {
            throw [AvmConfigurationException]::new(
                'Bicep higher-scope e2e requires an explicit, nonempty GUID -TenantId.')
        }
        $TenantId = $tenant.ToString('D')
    }
    $groupHasInvalidCharacters = $ManagementGroupId -cnotmatch '^[A-Za-z0-9_().-]{1,90}$'
    $groupHasInvalidSuffix = -not [string]::IsNullOrWhiteSpace($ManagementGroupId) -and $ManagementGroupId.EndsWith('.')
    if (-not [string]::IsNullOrWhiteSpace($ManagementGroupId) -and
        ($groupHasInvalidCharacters -or $groupHasInvalidSuffix)) {
        throw [AvmConfigurationException]::new(
            'Bicep e2e -ManagementGroupId must be a safe group name, not an ARM resource ID.')
    }
    if (-not $PSCmdlet.ShouldProcess(
            "$($cases.Count) Bicep example(s) in subscription $SubscriptionId",
            'Deploy Bicep tests and remove only verified test resources')) {
        $empty.RunsSkipped = $cases.Count
        return [pscustomobject]$empty
    }

    $bicep = Resolve-AvmTool -Name 'bicep' -AllowPathFallback:$AllowPathFallback
    $az = Get-Command -Name 'az' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $az) {
        throw [AvmConfigurationException]::new('Azure CLI (az) is required for Bicep e2e tests.')
    }
    $repoRoot = Get-AvmBicepTestRepositoryRoot -Context $Context
    $tokenMap = Get-AvmBicepTestTokenMap -Root $Context.Root `
        -SubscriptionId $SubscriptionId -TokenFile $TokenFile -Tokens $Tokens
    $runDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) `
        -ChildPath ('avm-bicep-e2e-{0}' -f [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $runDirectory -ErrorAction Stop
    $compiled = [System.Collections.Generic.List[object]]::new()
    $issues = [System.Collections.Generic.List[object]]::new()
    $changes = [System.Collections.Generic.List[object]]::new()
    $pending = [System.Collections.Generic.List[string]]::new()
    $assertions = [System.Collections.Generic.List[object]]::new()
    $passed = 0
    $failed = 0
    $attempted = 0
    $stopForCleanup = $false
    try {
        $parameterPath = $null
        for ($index = 0; $index -lt $cases.Count; $index++) {
            $path = Join-Path $runDirectory ('{0}.json' -f $index)
            $caseRunId = [guid]::NewGuid().ToString('N')
            $scopedTokens = if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
                Get-AvmBicepTestTokenMap -Root $Context.Root `
                    -SubscriptionId $SubscriptionId -TenantId $TenantId `
                    -ManagementGroupId $ManagementGroupId -RunId $caseRunId `
                    -TokenFile $TokenFile -Tokens $Tokens
            }
            else {
                $null
            }
            $template = New-AvmBicepTestTemplate -SourcePath $cases[$index].Path `
                -DestinationPath $path -BicepPath $bicep.Path -Tokens $tokenMap `
                -ScopedTokens $scopedTokens -RequireScopedTokens `
                -OwnedGroupRunId $caseRunId -SourceRoot $Context.Root -Confirm:$false
            $caseParameterPath = $null
            if ($template.Scope -eq 'group') {
                Assert-AvmBicepTestIsolation -Template $template.Template `
                    -SourcePath $cases[$index].RelativePath
            }
            else {
                if ($template.Scope -eq 'mg' -and
                    [string]::IsNullOrWhiteSpace($ManagementGroupId)) {
                    throw [AvmConfigurationException]::new(
                        "Bicep e2e test '$($cases[$index].RelativePath)' requires -ManagementGroupId.")
                }
                Assert-AvmBicepScopedTestIsolation -Template $template.Template `
                    -Scope $template.Scope -SourcePath $cases[$index].RelativePath `
                    -OwnedGroupRunId $caseRunId
                if ($template.HasGroupDeployment) {
                    throw [AvmConfigurationException]::new(
                        "Bicep e2e test '$($cases[$index].RelativePath)' deploys into a resource group from subscription scope; Create is refused until crash recovery and owned teardown are implemented.")
                }
                $caseParameterPath = New-AvmBicepTestParameterFile -Root $Context.Root `
                    -DestinationPath (Join-Path $runDirectory ('{0}-parameters.json' -f $index)) `
                    -Tokens $scopedTokens -ParameterFile $ParameterFile `
                    -Parameters $Parameters -Confirm:$false
            }
            $assertionFiles = @(Get-AvmBicepE2eAssertionFile -CasePath $cases[$index].Path)
            $compiled.Add([pscustomobject]@{
                    Case           = $cases[$index]
                    Scope          = $template.Scope
                    RunId          = $caseRunId
                    DeploymentName = 'avm-e2e-{0}' -f $caseRunId
                    TemplatePath   = $path
                    Template       = $template.Template
                    ParameterPath  = $caseParameterPath
                    AssertionFiles = [string[]]$assertionFiles
                })
        }
        if (@($compiled | Where-Object { $_.Scope -eq 'group' }).Count -gt 0) {
            if ([string]::IsNullOrWhiteSpace($ResourceGroupPrefix)) {
                throw [AvmConfigurationException]::new(
                    'Resource-group Bicep e2e tests require a safe -ResourceGroupPrefix.')
            }
            $parameterPath = New-AvmBicepTestParameterFile -Root $Context.Root `
                -DestinationPath (Join-Path $runDirectory 'parameters.json') `
                -Tokens $tokenMap -ParameterFile $ParameterFile `
                -Parameters $Parameters -Confirm:$false
        }

        foreach ($item in $compiled) {
            if ($stopForCleanup) {
                break
            }
            if ($item.Scope -ne 'group') {
                $run = Invoke-AvmBicepScopedTestE2eCase -Item $item `
                    -AzPath $az.Source -SubscriptionId $SubscriptionId -TenantId $TenantId `
                    -ManagementGroupId $ManagementGroupId -Location $Location `
                    -RepositoryRoot $repoRoot -WorkingDirectory $Context.Root -Confirm:$false
                $attempted += $run.Attempted
                if ($run.Passed) {
                    $passed++
                }
                if ($run.Failed) {
                    $failed++
                }
                foreach ($entry in $run.AssertionResults) {
                    $assertions.Add($entry)
                }
                foreach ($entry in $run.WhatIfChanges) {
                    $changes.Add($entry)
                }
                foreach ($entry in $run.Issues) {
                    $issues.Add($entry)
                }
                foreach ($id in $run.CleanupPending) {
                    $pending.Add($id)
                }
                if ($run.CleanupPending.Count -gt 0) {
                    $stopForCleanup = $true
                }
                continue
            }
            $runId = [guid]::NewGuid().ToString('N')
            $groupName = '{0}-{1}' -f $ResourceGroupPrefix, $runId
            $deploymentName = 'avm-e2e-{0}' -f $runId
            $attemptedGroupCreation = $false
            $deploymentAttempted = $false
            $previewPlan = $null
            $casePassed = $false
            $armInput = @{
                AzPath            = $az.Source
                TemplatePath      = $item.TemplatePath
                Scope             = 'group'
                SubscriptionId    = $SubscriptionId
                DeploymentName    = $deploymentName
                WorkingDirectory  = $Context.Root
                ResourceGroupName = $groupName
                ParameterPath     = $parameterPath
            }
            try {
                if (Test-AvmBicepResourceGroup -AzPath $az.Source `
                        -SubscriptionId $SubscriptionId -ResourceGroupName $groupName `
                        -WorkingDirectory $Context.Root) {
                    throw [AvmConfigurationException]::new(
                        "Refusing to use existing resource group '$groupName' for Bicep e2e.")
                }
                $attemptedGroupCreation = $true
                $attempted++
                $created = Invoke-AvmProcess -FilePath $az.Source -ArgumentList @(
                    'group', 'create', '--name', $groupName, '--location', $Location,
                    '--subscription', $SubscriptionId, '--tags', ('avm-e2e-run-id=' + $runId),
                    '--output', 'json'
                ) -WorkingDirectory $Context.Root -IgnoreExitCode
                if ($created.ExitCode -ne 0) {
                    Add-AvmBicepTestIssue -Issues $issues -File $item.Case.RelativePath `
                        -Code 'group-create-failed' -Message (Add-AvmProcessFailureDetail `
                            -Message "Failed to create disposable group '$groupName' (exit $($created.ExitCode))." `
                            -StdErr $created.StdErr)
                    $failed++
                    continue
                }
                if (-not (Test-Json -Json ([string]$created.StdOut) -ErrorAction SilentlyContinue)) {
                    Add-AvmBicepTestIssue -Issues $issues -File $item.Case.RelativePath `
                        -Code 'group-create-invalid' -Message "Cannot verify newly created group '$groupName': Azure CLI returned invalid JSON."
                    $failed++
                    continue
                }
                $group = [string]$created.StdOut | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                $expectedId = '/subscriptions/{0}/resourceGroups/{1}' -f $SubscriptionId, $groupName
                if ($group -isnot [System.Collections.IDictionary] -or
                    -not [string]::Equals([string]$group['id'], $expectedId, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $group['tags'] -isnot [System.Collections.IDictionary] -or
                    $group['tags']['avm-e2e-run-id'] -cne $runId) {
                    Add-AvmBicepTestIssue -Issues $issues -File $item.Case.RelativePath `
                        -Code 'group-create-unverified' -Message "Cannot verify ownership of newly created group '$groupName'."
                    $failed++
                    continue
                }

                $validated = Invoke-AvmBicepArmOperation @armInput -Operation Validate
                if ($validated.ExitCode -ne 0) {
                    Add-AvmBicepTestIssue -Issues $issues -File $item.Case.RelativePath `
                        -Code 'validate-failed' -Message (Add-AvmProcessFailureDetail `
                            -Message "ARM validate failed in '$groupName' (exit $($validated.ExitCode))." `
                            -StdErr $validated.StdErr)
                    $failed++
                    continue
                }
                $preview = Invoke-AvmBicepArmOperation @armInput -Operation WhatIf
                if ($preview.ExitCode -ne 0) {
                    Add-AvmBicepTestIssue -Issues $issues -File $item.Case.RelativePath `
                        -Code 'what-if-failed' -Message (Add-AvmProcessFailureDetail `
                            -Message "ARM what-if failed in '$groupName' (exit $($preview.ExitCode))." `
                            -StdErr $preview.StdErr)
                    $failed++
                    continue
                }
                try {
                    $previewPlan = Read-AvmBicepTestGroupWhatIf `
                        -Output ([string]$preview.StdOut) -File $item.Case.RelativePath `
                        -Template $item.Template -SubscriptionId $SubscriptionId `
                        -ResourceGroupName $groupName -RunId $runId
                }
                catch [AvmProcessException] {
                    Add-AvmBicepTestIssue -Issues $issues -File $item.Case.RelativePath `
                        -Code 'what-if-invalid' -Message $_.Exception.Message
                    $failed++
                    continue
                }
                catch [AvmConfigurationException] {
                    Add-AvmBicepTestIssue -Issues $issues -File $item.Case.RelativePath `
                        -Code 'what-if-unsafe' -Message $_.Exception.Message
                    $failed++
                    continue
                }
                foreach ($change in $previewPlan.Changes) {
                    $changes.Add($change)
                }
                $deploymentAttempted = $true
                $deployed = Invoke-AvmBicepArmOperation @armInput -Operation Create
                if ($deployed.ExitCode -ne 0) {
                    Add-AvmBicepTestIssue -Issues $issues -File $item.Case.RelativePath `
                        -Code 'deployment-failed' -Message (Add-AvmProcessFailureDetail `
                            -Message "ARM deployment failed in '$groupName' (exit $($deployed.ExitCode))." `
                            -StdErr $deployed.StdErr)
                    $failed++
                    continue
                }
                try {
                    Assert-AvmBicepDeploymentSucceeded -Output ([string]$deployed.StdOut) `
                        -SubscriptionId $SubscriptionId -ResourceGroupName $groupName `
                        -DeploymentName $deploymentName
                }
                catch [AvmProcessException] {
                    Add-AvmBicepTestIssue -Issues $issues -File $item.Case.RelativePath `
                        -Code 'deployment-unverified' -Message $_.Exception.Message
                    $failed++
                    continue
                }
                $assertionResult = Invoke-AvmBicepTestE2eAssertion -Item $item `
                    -DeploymentName $deploymentName -DeploymentOutput ([string]$deployed.StdOut) `
                    -RepositoryRoot $repoRoot -Issues $issues
                $assertions.Add($assertionResult)
                if ($assertionResult.Status -eq 'fail') {
                    $failed++
                    continue
                }
                $passed++
                $casePassed = $true
            }
            catch [AvmProcessException] {
                if (-not $attemptedGroupCreation) {
                    throw
                }
                Add-AvmBicepTestIssue -Issues $issues -File $item.Case.RelativePath `
                    -Code 'process-failed' -Message "Bicep e2e operation failed in '$groupName': $($_.Exception.Message)"
                $failed++
            }
            catch [System.TimeoutException] {
                if (-not $attemptedGroupCreation) {
                    throw
                }
                Add-AvmBicepTestIssue -Issues $issues -File $item.Case.RelativePath `
                    -Code 'process-timeout' -Message "Bicep e2e operation timed out in '$groupName': $($_.Exception.Message)"
                $failed++
            }
            finally {
                if ($attemptedGroupCreation) {
                    try {
                        $cleanup = Remove-AvmBicepTestResourceGroup -AzPath $az.Source `
                            -SubscriptionId $SubscriptionId -ResourceGroupName $groupName `
                            -RunId $runId -WorkingDirectory $Context.Root `
                            -ExpectCreated -Plan $previewPlan -DeploymentName $deploymentName `
                            -DeploymentAttempted:$deploymentAttempted
                    }
                    catch [AvmProcessException] {
                        $cleanup = [pscustomobject]@{
                            Cleaned = $false; Pending = @(); Message = $_.Exception.Message
                        }
                    }
                    catch [System.TimeoutException] {
                        $cleanup = [pscustomobject]@{
                            Cleaned = $false; Pending = @(); Message = $_.Exception.Message
                        }
                    }
                    if (-not $cleanup.Cleaned) {
                        foreach ($id in $cleanup.Pending) {
                            if (-not $pending.Contains($id)) {
                                $pending.Add($id)
                            }
                        }
                        $pending.Add($groupName)
                        $stopForCleanup = $true
                        $message = "$($cleanup.Message) Resource group '$groupName' may require manual cleanup."
                        Add-AvmBicepTestIssue -Issues $issues -File $item.Case.RelativePath `
                            -Code 'cleanup-failed' -Message $message
                        Write-AvmLog $message -Level Error
                        if ($casePassed) {
                            $passed--
                            $failed++
                        }
                    }
                }
            }
        }
    }
    finally {
        foreach ($item in @(Get-ChildItem -LiteralPath $runDirectory -File -Force)) {
            Remove-Item -LiteralPath $item.FullName -Force
        }
        Remove-Item -LiteralPath $runDirectory -Force
    }

    return [pscustomobject][ordered]@{
        Engine           = 'bicep'
        Tool             = 'az'
        ToolPath         = $az.Source
        ToolSource       = 'PATH'
        BicepTool        = "bicep/$($bicep.Version)"
        Status           = if ($failed -gt 0 -or $pending.Count -gt 0) { 'fail' } elseif ($passed -gt 0) { 'pass' } else { 'skipped' }
        FilesProcessed   = $attempted
        IgnoredFiles     = $ignored
        RunsTotal        = $attempted
        RunsPassed       = $passed
        RunsFailed       = $failed
        RunsSkipped      = $cases.Count - $attempted
        AssertionResults = $assertions.ToArray()
        CleanupPending   = $pending.ToArray()
        WhatIfChanges    = $changes.ToArray()
        Issues           = $issues.ToArray()
    }
}

function Add-AvmBicepTestIssue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]] $Issues,

        [Parameter(Mandatory)]
        [string] $File,

        [Parameter(Mandatory)]
        [string] $Code,

        [Parameter(Mandatory)]
        [string] $Message,

        [int] $Line = 0
    )

    $Issues.Add([pscustomobject][ordered]@{
            File     = $File
            Line     = $Line
            Column   = 0
            Severity = 'error'
            Code     = "avm.bicep.e2e-$Code"
            Message  = $Message
        })
}
