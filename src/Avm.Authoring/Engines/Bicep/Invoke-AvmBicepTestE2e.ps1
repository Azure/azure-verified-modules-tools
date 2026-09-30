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
        Engine         = 'bicep'
        Tool           = 'az'
        ToolPath       = $null
        ToolSource     = 'PATH'
        Status         = 'skipped'
        FilesProcessed = 0
        IgnoredFiles   = $ignored
        RunsTotal      = 0
        RunsPassed     = 0
        RunsFailed     = 0
        RunsSkipped    = 0
        CleanupPending = @()
        WhatIfChanges  = @()
        Issues         = @()
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
    if ([string]::IsNullOrWhiteSpace($ResourceGroupPrefix) -or
        $ResourceGroupPrefix.Length -gt 57 -or
        $ResourceGroupPrefix -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') {
        throw [AvmConfigurationException]::new(
            'Bicep e2e requires a safe -ResourceGroupPrefix (1-57 letters, digits, underscores, dots or hyphens).')
    }
    if (-not $PSCmdlet.ShouldProcess(
            "$($cases.Count) Bicep example(s) in subscription $SubscriptionId",
            'Create isolated resource groups, deploy tests and delete the groups')) {
        $empty.RunsSkipped = $cases.Count
        return [pscustomobject]$empty
    }

    $bicep = Resolve-AvmTool -Name 'bicep' -AllowPathFallback:$AllowPathFallback
    $az = Get-Command -Name 'az' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $az) {
        throw [AvmConfigurationException]::new('Azure CLI (az) is required for Bicep e2e tests.')
    }
    $tokenMap = Get-AvmBicepTestTokenMap -Root $Context.Root `
        -SubscriptionId $SubscriptionId -TokenFile $TokenFile -Tokens $Tokens
    $runDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) `
        -ChildPath ('avm-bicep-e2e-{0}' -f [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $runDirectory -ErrorAction Stop
    $compiled = [System.Collections.Generic.List[object]]::new()
    $issues = [System.Collections.Generic.List[object]]::new()
    $changes = [System.Collections.Generic.List[object]]::new()
    $pending = [System.Collections.Generic.List[string]]::new()
    $passed = 0
    $failed = 0
    $attempted = 0
    $stopForCleanup = $false
    try {
        $parameterPath = New-AvmBicepTestParameterFile -Root $Context.Root `
            -DestinationPath (Join-Path $runDirectory 'parameters.json') `
            -Tokens $tokenMap -ParameterFile $ParameterFile -Parameters $Parameters -Confirm:$false
        for ($index = 0; $index -lt $cases.Count; $index++) {
            $path = Join-Path $runDirectory ('{0}.json' -f $index)
            $template = New-AvmBicepTestTemplate -SourcePath $cases[$index].Path `
                -DestinationPath $path -BicepPath $bicep.Path -Tokens $tokenMap -Confirm:$false
            if ($template.Scope -ne 'group') {
                throw [AvmConfigurationException]::new(
                    "Bicep e2e test '$($cases[$index].RelativePath)' targets '$($template.Scope)'. Only resource-group templates have guaranteed cleanup; use avm test integration for this scope.")
            }
            Assert-AvmBicepTestIsolation -Template $template.Template `
                -SourcePath $cases[$index].RelativePath
            $compiled.Add([pscustomobject]@{
                    Case         = $cases[$index]
                    TemplatePath = $path
                })
        }

        foreach ($item in $compiled) {
            if ($stopForCleanup) {
                break
            }
            $runId = [guid]::NewGuid().ToString('N')
            $groupName = '{0}-{1}' -f $ResourceGroupPrefix, $runId
            $deploymentName = 'avm-e2e-{0}' -f $runId
            $attemptedGroupCreation = $false
            $groupCreateSucceeded = $false
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
                $groupCreateSucceeded = $true
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
                    $previewChanges = @(Read-AvmBicepWhatIfChange `
                            -Output ([string]$preview.StdOut) -File $item.Case.RelativePath)
                }
                catch [AvmProcessException] {
                    Add-AvmBicepTestIssue -Issues $issues -File $item.Case.RelativePath `
                        -Code 'what-if-invalid' -Message $_.Exception.Message
                    $failed++
                    continue
                }
                $resourcePrefix = '/subscriptions/{0}/resourceGroups/{1}/' -f $SubscriptionId, $groupName
                $unsafeChange = @($previewChanges | Where-Object {
                        $_.ChangeType -cne 'Create' -or
                        -not $_.ResourceId.StartsWith(
                            $resourcePrefix, [System.StringComparison]::OrdinalIgnoreCase)
                    })
                if ($previewChanges.Count -eq 0 -or $unsafeChange.Count -gt 0) {
                    Add-AvmBicepTestIssue -Issues $issues -File $item.Case.RelativePath `
                        -Code 'what-if-unsafe' -Message "ARM what-if for '$groupName' was empty or predicted changes outside the new group or other than Create; deployment was refused."
                    $failed++
                    continue
                }
                foreach ($change in $previewChanges) {
                    $changes.Add($change)
                }
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
                            -ExpectCreated:$groupCreateSucceeded
                    }
                    catch [AvmProcessException] {
                        $cleanup = [pscustomobject]@{ Cleaned = $false; Message = $_.Exception.Message }
                    }
                    catch [System.TimeoutException] {
                        $cleanup = [pscustomobject]@{ Cleaned = $false; Message = $_.Exception.Message }
                    }
                    if (-not $cleanup.Cleaned) {
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
        Engine         = 'bicep'
        Tool           = 'az'
        ToolPath       = $az.Source
        ToolSource     = 'PATH'
        BicepTool      = "bicep/$($bicep.Version)"
        Status         = if ($failed -gt 0 -or $pending.Count -gt 0) { 'fail' } elseif ($passed -gt 0) { 'pass' } else { 'skipped' }
        FilesProcessed = $attempted
        IgnoredFiles   = $ignored
        RunsTotal      = $attempted
        RunsPassed     = $passed
        RunsFailed     = $failed
        RunsSkipped    = $cases.Count - $attempted
        CleanupPending = $pending.ToArray()
        WhatIfChanges  = $changes.ToArray()
        Issues         = $issues.ToArray()
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
        [string] $Message
    )

    $Issues.Add([pscustomobject][ordered]@{
            File     = $File
            Line     = 0
            Column   = 0
            Severity = 'error'
            Code     = "avm.bicep.e2e-$Code"
            Message  = $Message
        })
}
