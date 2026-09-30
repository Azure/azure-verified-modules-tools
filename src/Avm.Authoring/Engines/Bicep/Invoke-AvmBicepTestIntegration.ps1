function Invoke-AvmBicepTestIntegration {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context,

        [switch] $AllowPathFallback,

        [string] $SubscriptionId,

        [string] $ResourceGroupName,

        [string] $ManagementGroupId,

        [string] $Location,

        [string] $TokenFile,

        [System.Collections.IDictionary] $Tokens = @{},

        [string] $ParameterFile,

        [System.Collections.IDictionary] $Parameters = @{},

        [AllowEmptyCollection()]
        [string[]] $Example = @(),

        [switch] $Recurse,

        [ValidateSet('Both', 'Validate', 'WhatIf')]
        [string] $Operation = 'Both'
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Context.Ecosystem -ne 'bicep') {
        throw [System.ArgumentException]::new('Bicep ARM validation requires a Bicep module context.')
    }

    $discovered = @(Get-AvmBicepTestCase -Context $Context -Recurse:$Recurse)
    $cases = @(Select-AvmBicepTestCase -Cases $discovered -Example $Example)
    $ignored = @($discovered | Where-Object { $_.Ignored }).Count
    if ($cases.Count -eq 0) {
        Write-AvmLog 'no runnable Bicep tests/e2e examples found' -Level Warning
        return [pscustomobject][ordered]@{
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
            WhatIfChanges  = @()
            Issues         = @()
        }
    }

    $subscription = [guid]::Empty
    if (-not [guid]::TryParse($SubscriptionId, [ref]$subscription) -or
        $subscription -eq [guid]::Empty) {
        throw [AvmConfigurationException]::new(
            'Bicep ARM validation requires an explicit, nonempty GUID -SubscriptionId.')
    }
    $SubscriptionId = $subscription.ToString('D')
    $bicep = Resolve-AvmTool -Name 'bicep' -AllowPathFallback:$AllowPathFallback
    $az = Get-Command -Name 'az' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $az) {
        throw [AvmConfigurationException]::new('Azure CLI (az) is required for Bicep ARM tests.')
    }
    $tokensByName = Get-AvmBicepTestTokenMap -Root $Context.Root `
        -SubscriptionId $SubscriptionId -ManagementGroupId $ManagementGroupId `
        -TokenFile $TokenFile -Tokens $Tokens
    $steps = if ($Operation -eq 'Both') { @('Validate', 'WhatIf') } else { @($Operation) }
    $runDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) `
        -ChildPath ('avm-bicep-arm-{0}' -f [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $runDirectory -ErrorAction Stop
    $compiled = [System.Collections.Generic.List[object]]::new()
    $issues = [System.Collections.Generic.List[object]]::new()
    $changes = [System.Collections.Generic.List[object]]::new()
    $passed = 0
    $failed = 0
    $skipped = 0
    try {
        $parameterPath = New-AvmBicepTestParameterFile -Root $Context.Root `
            -DestinationPath (Join-Path $runDirectory 'parameters.json') `
            -Tokens $tokensByName -ParameterFile $ParameterFile -Parameters $Parameters
        for ($index = 0; $index -lt $cases.Count; $index++) {
            $file = Join-Path $runDirectory ('{0}.json' -f $index)
            $template = New-AvmBicepTestTemplate -SourcePath $cases[$index].Path `
                -DestinationPath $file -BicepPath $bicep.Path -Tokens $tokensByName
            if ($template.Scope -eq 'group' -and [string]::IsNullOrWhiteSpace($ResourceGroupName)) {
                throw [AvmConfigurationException]::new(
                    "Bicep test '$($cases[$index].RelativePath)' requires -ResourceGroupName.")
            }
            if ($template.Scope -ne 'group' -and [string]::IsNullOrWhiteSpace($Location)) {
                throw [AvmConfigurationException]::new(
                    "Bicep test '$($cases[$index].RelativePath)' requires -Location.")
            }
            if ($template.Scope -eq 'mg' -and [string]::IsNullOrWhiteSpace($ManagementGroupId)) {
                throw [AvmConfigurationException]::new(
                    "Bicep test '$($cases[$index].RelativePath)' requires -ManagementGroupId.")
            }
            $compiled.Add([pscustomobject]@{
                    Case           = $cases[$index]
                    Scope          = $template.Scope
                    TemplatePath   = $file
                    DeploymentName = 'avm-test-{0}' -f [guid]::NewGuid().ToString('N')
                })
        }

        if (@($compiled | Where-Object { $_.Scope -eq 'group' }).Count -gt 0) {
            $exists = Invoke-AvmProcess -FilePath $az.Source -ArgumentList @(
                'group', 'exists', '--name', $ResourceGroupName,
                '--subscription', $SubscriptionId, '--output', 'tsv'
            ) -WorkingDirectory $Context.Root -IgnoreExitCode
            if ($exists.ExitCode -ne 0) {
                $message = Add-AvmProcessFailureDetail `
                    -Message "Could not check whether resource group '$ResourceGroupName' exists." `
                    -StdErr $exists.StdErr
                throw [AvmProcessException]::new($message)
            }
            $groupExists = $exists.StdOut.Trim()
            if ($groupExists -cnotin @('true', 'false')) {
                throw [AvmProcessException]::new(
                    "Azure CLI returned an invalid resource-group existence result for '$ResourceGroupName'.")
            }
            if ($groupExists -ceq 'false') {
                throw [AvmConfigurationException]::new(
                    "Resource group '$ResourceGroupName' must already exist for Bicep ARM validation; this tier never creates it.")
            }
        }

        foreach ($item in $compiled) {
            foreach ($step in $steps) {
                $result = Invoke-AvmBicepArmOperation -AzPath $az.Source `
                    -TemplatePath $item.TemplatePath -Scope $item.Scope -Operation $step `
                    -SubscriptionId $SubscriptionId -DeploymentName $item.DeploymentName `
                    -WorkingDirectory $Context.Root -ResourceGroupName $ResourceGroupName `
                    -ManagementGroupId $ManagementGroupId -Location $Location `
                    -ParameterPath $parameterPath
                if ($result.ExitCode -ne 0) {
                    $failed++
                    $skipped += $steps.Count - [array]::IndexOf($steps, $step) - 1
                    $issues.Add([pscustomobject][ordered]@{
                            File     = $item.Case.RelativePath
                            Line     = 0
                            Column   = 0
                            Severity = 'error'
                            Code     = "avm.bicep.arm-$($step.ToLowerInvariant())-failed"
                            Message  = Add-AvmProcessFailureDetail `
                                -Message "ARM $step failed (exit $($result.ExitCode))." -StdErr $result.StdErr
                        })
                    break
                }
                if ($step -eq 'WhatIf') {
                    $plan = [string]$result.StdOut | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                    if ($plan -isnot [System.Collections.IDictionary] -or
                        $plan['changes'] -isnot [array]) {
                        throw [AvmProcessException]::new(
                            "ARM what-if for '$($item.Case.RelativePath)' returned no JSON changes array.")
                    }
                    foreach ($change in $plan['changes']) {
                        if ($change -isnot [System.Collections.IDictionary] -or
                            [string]::IsNullOrWhiteSpace([string]$change['resourceId']) -or
                            [string]::IsNullOrWhiteSpace([string]$change['changeType'])) {
                            throw [AvmProcessException]::new(
                                "ARM what-if for '$($item.Case.RelativePath)' returned an invalid change.")
                        }
                        $changes.Add([pscustomobject][ordered]@{
                                File       = $item.Case.RelativePath
                                ResourceId = [string]$change['resourceId']
                                ChangeType = [string]$change['changeType']
                            })
                    }
                }
                $passed++
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
        Status         = if ($failed -gt 0) { 'fail' } else { 'pass' }
        FilesProcessed = $cases.Count
        IgnoredFiles   = $ignored
        RunsTotal      = $passed + $failed
        RunsPassed     = $passed
        RunsFailed     = $failed
        RunsSkipped    = $skipped
        WhatIfChanges  = $changes.ToArray()
        Issues         = $issues.ToArray()
    }
}
