function Invoke-AvmTerraformPolicyExample {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Example,

        [Parameter(Mandatory)]
        $Options
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $envVars = @{}
    $primaryError = $null
    $issues = [System.Collections.Generic.List[object]]::new()
    $evaluated = 0

    try {
        Invoke-AvmScriptHook `
            -HookPath (Join-Path $Example.StagedPath 'pre.ps1') `
            -WorkingDirectory $Example.StagedPath `
            -Label ("policy {0} pre.ps1" -f $Example.Name)

        $envVars = ConvertFrom-AvmDotEnv -Path (Join-Path $Example.StagedPath '.env')

        # A real credential always wins. It is the only way examples whose
        # data sources read existing Azure resources can plan, so a trusted
        # run keeps exactly the behaviour and coverage it has today. The
        # synthetic credential is a fallback for contributors and forks, not
        # a replacement.
        if ($null -ne $Options.CredentialEnvVars -and
            -not (Test-AvmAzureCredentialAvailable -EnvVars $envVars)) {
            foreach ($name in $Options.CredentialEnvVars.Keys) {
                $envVars[$name] = $Options.CredentialEnvVars[$name]
            }
        }

        $terraformLock = Lock-AvmTerraformPluginCache `
            -WorkingDirectory $Example.StagedPath `
            -EnvVars $envVars
        try {
            $null = Invoke-AvmTerraformInit `
                -TerraformPath $Options.TerraformPath `
                -WorkingDirectory $Example.StagedPath `
                -EnvVars $envVars `
                -Label ("terraform init ({0})" -f $Example.Name) `
                -NoColor `
                -SkipPluginCacheLock

            $null = Invoke-AvmProcess `
                -FilePath $Options.TerraformPath `
                -ArgumentList @('plan', '-out=tfplan', '-input=false', '-no-color') `
                -WorkingDirectory $Example.StagedPath `
                -EnvVars $envVars `
                -Label ("terraform plan ({0})" -f $Example.Name)

            $showResult = Invoke-AvmProcess `
                -FilePath $Options.TerraformPath `
                -ArgumentList @('show', '-json', 'tfplan') `
                -WorkingDirectory $Example.StagedPath `
                -EnvVars $envVars `
                -Label ("terraform show ({0})" -f $Example.Name)
        }
        finally {
            if ($null -ne $terraformLock) {
                $terraformLock.Dispose()
            }
        }

        $planJsonPath = Join-Path $Example.StagedPath 'tfplan.json'
        [System.IO.File]::WriteAllText(
            $planJsonPath,
            [string]$showResult.StdOut,
            [System.Text.UTF8Encoding]::new($false))

        $localExceptions = Join-Path $Example.StagedPath 'exceptions'
        $policyRuns = @(
            [pscustomobject]@{ Name = 'APRL'; Path = $Options.AprlPath }
            [pscustomobject]@{ Name = 'AVMSEC'; Path = $Options.AvmsecPath }
        )

        foreach ($policyRun in $policyRuns) {
            $arguments = [System.Collections.Generic.List[string]]::new()
            $arguments.Add('test')
            $arguments.Add('--all-namespaces')
            $arguments.Add('--policy')
            $arguments.Add([string]$policyRun.Path)
            $arguments.Add('--policy')
            $arguments.Add($Options.DefaultExceptions)
            if (Test-Path -LiteralPath $localExceptions -PathType Container) {
                $arguments.Add('--policy')
                $arguments.Add($localExceptions)
            }
            $arguments.Add('--output')
            $arguments.Add('json')
            $arguments.Add('tfplan.json')

            $policyResult = Invoke-AvmProcess `
                -FilePath $Options.ConftestPath `
                -ArgumentList $arguments.ToArray() `
                -WorkingDirectory $Example.StagedPath `
                -EnvVars $envVars `
                -Label ("conftest {0} ({1})" -f $policyRun.Name, $Example.Name) `
                -IgnoreExitCode

            $parsed = ConvertFrom-AvmPolicyResult `
                -Result $policyResult `
                -ExamplePath $Example.RelativePath `
                -PolicyName $policyRun.Name
            $evaluated += $parsed.Evaluated
            foreach ($issue in $parsed.Issues) {
                $issues.Add($issue)
            }
        }
    }
    catch {
        $primaryError = $_
    }

    try {
        Invoke-AvmScriptHook `
            -HookPath (Join-Path $Example.StagedPath 'post.ps1') `
            -WorkingDirectory $Example.StagedPath `
            -EnvVars $envVars `
            -Label ("policy {0} post.ps1" -f $Example.Name)
    }
    catch {
        if ($null -eq $primaryError) {
            throw
        }
        Write-AvmLog `
            -Level Warning `
            -File (Join-Path $Example.RelativePath 'post.ps1') `
            -Message ("Policy post hook also failed; preserving the primary error: {0}" -f $_.Exception.Message)
    }

    if ($null -ne $primaryError) {
        throw $primaryError
    }

    return [pscustomobject]@{
        Evaluated = $evaluated
        Issues    = $issues.ToArray()
    }
}

function Get-AvmConftestOverrideWarning {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [string[]] $ExamplePath
    )

    $rootFull = (Resolve-Path -LiteralPath $Root).ProviderPath
    $warnings = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

    foreach ($example in $ExamplePath) {
        $exceptionsPath = Join-Path $example 'exceptions'
        if (-not (Test-Path -LiteralPath $exceptionsPath -PathType Container)) {
            continue
        }

        $exceptionFiles = @(
            Get-ChildItem `
                -LiteralPath $exceptionsPath `
                -Filter '*.rego' `
                -File `
                -Recurse `
                -ErrorAction SilentlyContinue |
                Sort-Object FullName
        )
        foreach ($exceptionFile in $exceptionFiles) {
            $file = [System.IO.Path]::GetRelativePath($rootFull, $exceptionFile.FullName).Replace('\', '/')
            $text = [System.IO.File]::ReadAllText($exceptionFile.FullName)
            $rules = @(
                @(
                    foreach ($exceptionMatch in [regex]::Matches($text, '(?ms)\bexception\s+contains\s+rules\s+if\s*\{(?<block>[^{}]*)\}')) {
                        foreach ($ruleListMatch in [regex]::Matches($exceptionMatch.Groups['block'].Value, '(?ms)\brules\s*(?::=|=)\s*\[(?<body>.*?)\]')) {
                            foreach ($ruleMatch in [regex]::Matches($ruleListMatch.Groups['body'].Value, '["''](?<rule>[^"'']+)["'']')) {
                                [string]$ruleMatch.Groups['rule'].Value
                            }
                        }
                    }
                ) | Select-Object -Unique
            )

            if ($rules.Count -gt 0) {
                foreach ($rule in $rules) {
                    $key = "$file`0$rule"
                    if (-not $seen.Add($key)) {
                        continue
                    }
                    $warnings.Add([pscustomobject][ordered]@{
                            File    = $file
                            Rule    = $rule
                            Message = ("Conftest override exempts rule '{0}'." -f $rule)
                        })
                }
            }
            elseif ($text -cmatch '\bexception\s+contains\s+rules\s+if\b') {
                $key = "$file`0"
                if ($seen.Add($key)) {
                    $warnings.Add([pscustomobject][ordered]@{
                            File    = $file
                            Rule    = ''
                            Message = 'Conftest override file found, but no exempted rules could be parsed.'
                        })
                }
            }
        }
    }

    return $warnings.ToArray()
}

function Invoke-AvmTerraformCheckPolicy {
    <#
    .SYNOPSIS
        Evaluate Terraform examples against the pinned APRL and AVMSEC policies.

    .DESCRIPTION
        Implements the legacy AVM pr-check policy lifecycle without mutating the
        repository. The module is copied beneath the AVM cache, then every direct
        examples/* directory is evaluated independently with bounded parallelism:

          - examples carrying .e2eignore are skipped
          - pre.ps1 runs when present; pre.sh is rejected with migration guidance
          - .env is loaded into Terraform and Conftest subprocesses
          - terraform init, plan, and show produce a plan-JSON input
          - when no real Azure credential is configured the plan runs against
            a synthetic loopback token and makes no Azure API call, so forks
            and credential-free contributors still get policy coverage; a
            real credential, when present, is always preferred (see
            Start-AvmFakeAzureCredential)
          - APRL and AVMSEC run separately with all namespaces enabled
          - the pinned AVMSEC exemptions and that example's local exceptions/
            directory are included in both evaluations
          - post.ps1 runs after the example; post.sh is rejected likewise

        The staging directory is deliberately beneath the policy bundle cache.
        Conftest strips the drive letter from --policy paths on Windows;
        keeping the working tree and bundles on one volume preserves resolution.

        Conftest output is captured as JSON rather than streamed. The legacy
        command used --quiet; omitting that switch here has the same user-visible
        silence while retaining success records needed for the Evaluated count.

    .PARAMETER Context
        Terraform module context produced by Get-AvmModuleContext.

    .PARAMETER AllowPathFallback
        Allow Terraform and Conftest to resolve from PATH.

    .PARAMETER ThrottleLimit
        Maximum number of independent examples to evaluate at once. Defaults to
        one for direct engine calls.

    .OUTPUTS
        A Terraform engine result with Status, Evaluated, and Issues.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Context,

        [switch] $AllowPathFallback,

        [ValidateRange(1, 32)]
        [int] $ThrottleLimit = 1
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

    foreach ($warning in (Get-AvmConftestOverrideWarning -Root $Context.Root -ExamplePath $activeExamples)) {
        Write-AvmLog `
            -Message $warning.Message `
            -Level Warning `
            -File $warning.File
    }

    $shellHooks = [System.Collections.Generic.List[string]]::new()
    foreach ($sourceExample in $activeExamples) {
        $exampleName = Split-Path -Path $sourceExample -Leaf
        foreach ($hookName in @('pre.sh', 'post.sh')) {
            if (Test-Path -LiteralPath (Join-Path $sourceExample $hookName) -PathType Leaf) {
                $shellHooks.Add(('examples/{0}/{1}' -f $exampleName, $hookName))
            }
        }
    }
    if ($shellHooks.Count -gt 0) {
        throw [AvmConfigurationException]::new(
            ("The terraform policy engine runs PowerShell hooks only. Refactor these shell hooks to '.ps1': {0}" -f ($shellHooks -join ', ')))
    }

    $stageParent = Join-Path (Get-AvmFolder -Kind Cache) 'policy-stage'
    $stageRoot = Join-Path $stageParent ('avm-policy-' + [guid]::NewGuid().ToString('N'))
    $issues = [System.Collections.Generic.List[object]]::new()
    $evaluated = 0
    $streamOutput = Test-AvmVerboseEnabled
    $effectiveThrottle = if ($streamOutput) { 1 } else { $ThrottleLimit }
    $fakeCredential = $null

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

        $examples = [System.Collections.Generic.List[object]]::new()
        for ($exampleIndex = 0; $exampleIndex -lt $activeExamples.Count; $exampleIndex++) {
            $sourceExample = $activeExamples[$exampleIndex]
            $relativeExample = [System.IO.Path]::GetRelativePath($Context.Root, $sourceExample)
            $stagedExample = Join-Path $stageRoot $relativeExample
            $exampleName = Split-Path -Path $sourceExample -Leaf
            Write-AvmLog `
                -Level Info `
                -Message ("policy: example {0}/{1} = {2}" -f ($exampleIndex + 1), $activeExamples.Count, $exampleName) |
                Out-Null
            $examples.Add([pscustomobject]@{
                    Name         = $exampleName
                    RelativePath = $relativeExample
                    StagedPath   = $stagedExample
                })
        }

        Write-AvmLog `
            -Level Verbose `
            -Message ("policy: processing examples with {0} worker(s)" -f $effectiveThrottle) |
            Out-Null
        $fakeCredential = Start-AvmFakeAzureCredential
        $options = [pscustomobject]@{
            TerraformPath     = $terraform.Path
            ConftestPath      = $conftest.Path
            AprlPath          = $aprlAsset.Path
            AvmsecPath        = $avmsecAsset.Path
            DefaultExceptions = $defaultExceptions
            CredentialEnvVars = $fakeCredential.EnvVars
        }
        $exampleResults = @(
            Invoke-AvmParallel `
                -InputObject $examples.ToArray() `
                -FunctionName 'Invoke-AvmTerraformPolicyExample' `
                -Argument $options `
                -ThrottleLimit $effectiveThrottle
        )
        foreach ($exampleResult in $exampleResults) {
            $evaluated += $exampleResult.Evaluated
            foreach ($issue in $exampleResult.Issues) {
                $issues.Add($issue)
            }
        }
    }
    finally {
        Stop-AvmFakeAzureCredential -Credential $fakeCredential
        if (Test-Path -LiteralPath $stageRoot) {
            Remove-Item `
                -LiteralPath $stageRoot `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue `
                -ProgressAction SilentlyContinue
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
        $summary = "conftest $PolicyName exited with code $($Result.ExitCode)."
        $message = Add-AvmProcessFailureDetail `
            -Message $summary `
            -StdOut $Result.StdOut `
            -StdErr $Result.StdErr
        if ($message -ceq $summary) {
            $message += [Environment]::NewLine + '  conftest produced no diagnostic.'
        }
        throw [AvmProcessException]::new(
            $message)
    }

    $payload = if ($Result.StdOut) { $Result.StdOut.Trim() } else { '' }
    if ($Result.ExitCode -eq 1 -and [string]::IsNullOrWhiteSpace($payload)) {
        $summary = "conftest $PolicyName exited before evaluating a policy."
        $message = Add-AvmProcessFailureDetail `
            -Message $summary `
            -StdOut $Result.StdOut `
            -StdErr $Result.StdErr
        if ($message -ceq $summary) {
            $message += [Environment]::NewLine + '  conftest produced no result.'
        }
        throw [AvmProcessException]::new(
            $message)
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
