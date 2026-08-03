function Invoke-AvmTerraformCheckPolicy {
    <#
    .SYNOPSIS
        Evaluate Terraform examples against the pinned APRL and AVMSEC policies.

    .DESCRIPTION
        Implements the legacy AVM pr-check policy lifecycle without mutating the
        repository. The module is copied beneath the AVM cache, then every direct
        examples/* directory is evaluated independently:

          - examples carrying .e2eignore are skipped
          - pre.ps1 runs when present; pre.sh is rejected with migration guidance
          - .env is loaded into Terraform and Conftest subprocesses
          - terraform init, plan, and show produce a plan-JSON input
          - APRL and AVMSEC run separately with all namespaces enabled
          - the pinned AVMSEC exemptions and that example's local exceptions/
            directory are included in both evaluations
          - post.ps1 runs after the example; post.sh is rejected likewise

        The staging directory is deliberately beneath the policy bundle cache.
        Conftest 0.68.2 strips the drive letter from --policy paths on Windows;
        keeping the working tree and bundles on one volume preserves resolution.

        Conftest output is captured as JSON rather than streamed. The legacy
        command used --quiet; omitting that switch here has the same user-visible
        silence while retaining success records needed for the Evaluated count.

    .PARAMETER Context
        Terraform module context produced by Get-AvmModuleContext.

    .PARAMETER AllowPathFallback
        Allow Terraform and Conftest to resolve from PATH.

    .OUTPUTS
        A Terraform engine result with Status, Evaluated, and Issues.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Context,

        [switch] $AllowPathFallback
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Context.Ecosystem -ne 'terraform') {
        throw [System.ArgumentException]::new(
            "Invoke-AvmTerraformCheckPolicy requires a terraform context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $conftest = Resolve-AvmTool -Name 'conftest' -AllowPathFallback:$AllowPathFallback
    $terraform = Resolve-AvmTool -Name 'terraform' -AllowPathFallback:$AllowPathFallback
    $aprlAsset = Resolve-AvmPolicyBundle -Name 'avm-policy-aprl'
    $avmsecAsset = Resolve-AvmPolicyBundle -Name 'avm-policy-avmsec'

    $defaultExceptionSource = Join-Path $avmsecAsset.Path 'avm_exceptions.rego.bak'
    if (-not (Test-Path -LiteralPath $defaultExceptionSource -PathType Leaf)) {
        throw [AvmConfigurationException]::new(
            "The pinned AVMSEC bundle does not contain the default exemption policy: '$defaultExceptionSource'.")
    }

    $examplesRoot = Join-Path $Context.Root 'examples'
    $examplePaths = @()
    if (Test-Path -LiteralPath $examplesRoot -PathType Container) {
        $examplePaths = @(Get-ChildItem -LiteralPath $examplesRoot -Directory -ErrorAction Stop |
                ForEach-Object FullName)
        [System.Array]::Sort($examplePaths, [System.StringComparer]::Ordinal)
    }

    $activeExamples = @($examplePaths | Where-Object {
            -not (Test-Path -LiteralPath (Join-Path $_ '.e2eignore') -PathType Leaf)
        })
    if ($activeExamples.Count -eq 0) {
        return [pscustomobject][ordered]@{
            Engine     = 'terraform'
            Tool       = ('{0}/{1}' -f $conftest.Name, $conftest.Version)
            ToolPath   = $conftest.Path
            ToolSource = $conftest.Source
            Status     = 'skipped'
            Evaluated  = 0
            Issues     = @()
        }
    }

    $stageParent = Join-Path (Get-AvmFolder -Kind Cache) 'policy-stage'
    $stageRoot = Join-Path $stageParent ('avm-policy-' + [guid]::NewGuid().ToString('N'))
    $issues = [System.Collections.Generic.List[object]]::new()
    $evaluated = 0

    try {
        Copy-AvmTerraformModuleTree -SourceRoot $Context.Root -DestinationRoot $stageRoot

        $defaultExceptions = Join-Path `
            -Path $stageRoot `
            -ChildPath 'policy' `
            -AdditionalChildPath 'default_exceptions'
        $null = New-Item -ItemType Directory -Path $defaultExceptions -Force -ErrorAction Stop
        Copy-Item `
            -LiteralPath $defaultExceptionSource `
            -Destination (Join-Path $defaultExceptions 'avm_exceptions.rego') `
            -Force `
            -ErrorAction Stop

        foreach ($sourceExample in $activeExamples) {
            $relativeExample = [System.IO.Path]::GetRelativePath($Context.Root, $sourceExample)
            $stagedExample = Join-Path $stageRoot $relativeExample
            $exampleName = Split-Path -Path $sourceExample -Leaf
            $envVars = @{}

            try {
                foreach ($hookName in @('pre.sh', 'pre.ps1')) {
                    Invoke-AvmScriptHook `
                        -HookPath (Join-Path $stagedExample $hookName) `
                        -WorkingDirectory $stagedExample `
                        -Label ("policy {0} {1}" -f $exampleName, $hookName)
                }

                $envVars = ConvertFrom-AvmDotEnv -Path (Join-Path $stagedExample '.env')

                $initResult = Invoke-AvmProcess `
                    -FilePath $terraform.Path `
                    -ArgumentList @('init', '-input=false', '-no-color') `
                    -WorkingDirectory $stagedExample `
                    -EnvVars $envVars `
                    -Label ("terraform init ({0})" -f $exampleName)
                $null = $initResult

                $planResult = Invoke-AvmProcess `
                    -FilePath $terraform.Path `
                    -ArgumentList @('plan', '-out=tfplan', '-input=false', '-no-color') `
                    -WorkingDirectory $stagedExample `
                    -EnvVars $envVars `
                    -Label ("terraform plan ({0})" -f $exampleName)
                $null = $planResult

                $showResult = Invoke-AvmProcess `
                    -FilePath $terraform.Path `
                    -ArgumentList @('show', '-json', 'tfplan') `
                    -WorkingDirectory $stagedExample `
                    -EnvVars $envVars `
                    -Label ("terraform show ({0})" -f $exampleName)

                $planJsonPath = Join-Path $stagedExample 'tfplan.json'
                [System.IO.File]::WriteAllText(
                    $planJsonPath,
                    [string]$showResult.StdOut,
                    [System.Text.UTF8Encoding]::new($false))

                $localExceptions = Join-Path $stagedExample 'exceptions'
                $policyRuns = @(
                    [pscustomobject]@{ Name = 'APRL'; Path = $aprlAsset.Path }
                    [pscustomobject]@{ Name = 'AVMSEC'; Path = $avmsecAsset.Path }
                )

                foreach ($policyRun in $policyRuns) {
                    $arguments = [System.Collections.Generic.List[string]]::new()
                    $arguments.Add('test')
                    $arguments.Add('--all-namespaces')
                    $arguments.Add('--policy')
                    $arguments.Add([string]$policyRun.Path)
                    $arguments.Add('--policy')
                    $arguments.Add($defaultExceptions)
                    if (Test-Path -LiteralPath $localExceptions -PathType Container) {
                        $arguments.Add('--policy')
                        $arguments.Add($localExceptions)
                    }
                    $arguments.Add('--output')
                    $arguments.Add('json')
                    $arguments.Add('tfplan.json')

                    $policyResult = Invoke-AvmProcess `
                        -FilePath $conftest.Path `
                        -ArgumentList $arguments.ToArray() `
                        -WorkingDirectory $stagedExample `
                        -EnvVars $envVars `
                        -Label ("conftest {0} ({1})" -f $policyRun.Name, $exampleName) `
                        -IgnoreExitCode

                    $parsed = ConvertFrom-AvmPolicyResult `
                        -Result $policyResult `
                        -ExamplePath $relativeExample `
                        -PolicyName $policyRun.Name
                    $evaluated += $parsed.Evaluated
                    foreach ($issue in $parsed.Issues) {
                        $issues.Add($issue)
                    }
                }
            }
            finally {
                foreach ($hookName in @('post.sh', 'post.ps1')) {
                    Invoke-AvmScriptHook `
                        -HookPath (Join-Path $stagedExample $hookName) `
                        -WorkingDirectory $stagedExample `
                        -EnvVars $envVars `
                        -Label ("policy {0} {1}" -f $exampleName, $hookName)
                }
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $stageRoot) {
            Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $status = if (@($issues | Where-Object { $_.Severity -eq 'error' }).Count -gt 0) { 'fail' } else { 'pass' }
    return [pscustomobject][ordered]@{
        Engine     = 'terraform'
        Tool       = ('{0}/{1}' -f $conftest.Name, $conftest.Version)
        ToolPath   = $conftest.Path
        ToolSource = $conftest.Source
        Status     = $status
        Evaluated  = $evaluated
        Issues     = $issues.ToArray()
    }
}

function ConvertFrom-AvmPolicyResult {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Result,

        [Parameter(Mandatory)]
        [string] $ExamplePath,

        [Parameter(Mandatory)]
        [string] $PolicyName
    )

    if ($Result.ExitCode -notin @(0, 1)) {
        $detail = if ([string]::IsNullOrWhiteSpace($Result.StdErr)) {
            'conftest produced no diagnostic.'
        }
        else {
            $Result.StdErr.Trim()
        }
        throw [AvmProcessException]::new(
            "conftest $PolicyName exited with code $($Result.ExitCode): $detail")
    }

    $payload = if ($Result.StdOut) { $Result.StdOut.Trim() } else { '' }
    if ($Result.ExitCode -eq 1 -and [string]::IsNullOrWhiteSpace($payload)) {
        $detail = if ([string]::IsNullOrWhiteSpace($Result.StdErr)) {
            'conftest produced no result.'
        }
        else {
            $Result.StdErr.Trim()
        }
        throw [AvmProcessException]::new(
            "conftest $PolicyName exited before evaluating a policy: $detail")
    }

    $records = @()
    if (-not [string]::IsNullOrWhiteSpace($payload)) {
        try {
            $records = @($payload | ConvertFrom-Json -ErrorAction Stop)
        }
        catch {
            throw [AvmProcessException]::new(
                "Could not parse conftest $PolicyName JSON output: $($_.Exception.Message)")
        }
    }

    $issues = [System.Collections.Generic.List[object]]::new()
    $evaluated = 0
    $issueFile = [System.IO.Path]::Combine($ExamplePath, 'tfplan.json').Replace('\', '/')
    foreach ($record in $records) {
        if (-not $record) { continue }
        $namespace = if ($record.PSObject.Properties['namespace']) {
            [string]$record.namespace
        }
        else {
            $PolicyName.ToLowerInvariant()
        }

        if ($record.PSObject.Properties['successes']) {
            $evaluated += [int]$record.successes
        }
        foreach ($bucket in @('failures', 'warnings', 'exceptions')) {
            if ($record.PSObject.Properties[$bucket] -and $record.$bucket) {
                $evaluated += @($record.$bucket).Count
            }
        }

        foreach ($bucket in @(
                [pscustomobject]@{ Name = 'failures'; Severity = 'error' }
                [pscustomobject]@{ Name = 'warnings'; Severity = 'warning' }
            )) {
            if (-not $record.PSObject.Properties[$bucket.Name] -or -not $record.($bucket.Name)) {
                continue
            }
            foreach ($finding in @($record.($bucket.Name))) {
                $message = if ($finding.PSObject.Properties['msg']) { [string]$finding.msg } else { '' }
                $issues.Add([pscustomobject][ordered]@{
                        File     = $issueFile
                        Line     = 0
                        Column   = 0
                        Severity = $bucket.Severity
                        Code     = $namespace
                        Message  = $message
                    })
            }
        }
    }

    return [pscustomobject][ordered]@{
        Evaluated = $evaluated
        Issues    = $issues.ToArray()
    }
}
