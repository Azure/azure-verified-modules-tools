. (Join-Path $PSScriptRoot 'RepositoryFileSync.ps1')

function Set-RepositorySyncCandidatePhase {
    param(
        [Parameter(Mandatory)] [string]$Directory,
        [Parameter(Mandatory)] [string]$Repository,
        [Parameter(Mandatory)] [ValidateSet('initializing', 'skipped')] [string]$Phase,
        [Parameter(Mandatory)] [bool]$PlanOnly
    )

    $null = New-Item -ItemType Directory -Path $Directory -Force
    $candidate = [ordered]@{
        schemaVersion = 1
        repository    = $Repository
        phase         = $Phase
        hasChanges    = $false
        planOnly      = $PlanOnly
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $Directory 'candidate.json'),
        (ConvertTo-Json -InputObject $candidate -Depth 5) + "`n",
        [System.Text.UTF8Encoding]::new($false))
}

function Read-RepositorySyncCandidate {
    param(
        [Parameter(Mandatory)] [string]$Directory,
        [Parameter(Mandatory)] [string]$Repository
    )

    $candidate = Get-Content -LiteralPath (Join-Path $Directory 'candidate.json') -Raw -ErrorAction Stop |
        ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $required = @('schemaVersion', 'repository', 'phase', 'hasChanges', 'planOnly')
    if ($candidate -isnot [System.Collections.IDictionary] -or
        @($required | Where-Object { -not $candidate.Contains($_) }).Count -gt 0) {
        throw [System.IO.InvalidDataException]::new('The repository-sync candidate manifest is incomplete.')
    }
    if ($candidate.schemaVersion -ne 1 -or $candidate.repository -cne $Repository -or
        $candidate.hasChanges -isnot [bool] -or $candidate.planOnly -isnot [bool]) {
        throw [System.IO.InvalidDataException]::new('The repository-sync candidate manifest is invalid or belongs to a different repository.')
    }
    if ($candidate.phase -ceq 'initializing') {
        throw [System.InvalidOperationException]::new("Candidate preparation did not finish for $Repository.")
    }
    if ($candidate.phase -ceq 'skipped') {
        if ($candidate.hasChanges) {
            throw [System.IO.InvalidDataException]::new('A skipped candidate cannot contain changes.')
        }
        return $candidate
    }
    if ($candidate.phase -cne 'prepared' -or
        -not $candidate.Contains('defaultBranch') -or -not $candidate.Contains('baseSha') -or
        $candidate.defaultBranch -cnotmatch '^[A-Za-z0-9._/-]+$' -or
        $candidate.baseSha -cnotmatch '^[0-9a-f]{40}$') {
        throw [System.IO.InvalidDataException]::new('The prepared candidate has an invalid branch or base revision.')
    }
    if ($candidate.hasChanges) {
        $requiredChanges = @('headSha', 'treeSha', 'changedPaths', 'authoringSource', 'authoringVersion')
        if (@($requiredChanges | Where-Object { -not $candidate.Contains($_) }).Count -gt 0 -or
            $candidate.headSha -cnotmatch '^[0-9a-f]{40}$' -or
            $candidate.treeSha -cnotmatch '^[0-9a-f]{40}$' -or
            $candidate.changedPaths -isnot [array] -or $candidate.changedPaths.Count -eq 0 -or
            $candidate.authoringSource -cnotin @('checkout', 'gallery') -or
            $candidate.authoringVersion -cnotmatch '^\d+\.\d+\.\d+$' -or
            ($candidate.authoringSource -ceq 'checkout' -and -not $candidate.planOnly)) {
            throw [System.IO.InvalidDataException]::new('The changed repository-sync candidate is incomplete.')
        }
        foreach ($path in $candidate.changedPaths) {
            if ($path -isnot [string] -or $path -cmatch '(^/|\\|(^|/)\.\.?(/|$)|(^|/)\.git(/|$)|[\r\n])') {
                throw [System.IO.InvalidDataException]::new('The candidate contains an unsafe changed path.')
            }
        }
        foreach ($file in @('candidate.tar', 'candidate.patch')) {
            $artifact = Get-Item -LiteralPath (Join-Path $Directory $file) -ErrorAction Stop
            if ($artifact.PSIsContainer -or $artifact.Length -eq 0) {
                throw [System.IO.InvalidDataException]::new("The candidate artifact '$file' is empty or invalid.")
            }
        }
    }
    return $candidate
}

function ConvertTo-RepositorySyncTestSettings {
    param([Parameter(Mandatory)] [System.Collections.IDictionary]$Settings)

    $ids = @($Settings['tenant_id'], $Settings['client_id'])
    foreach ($value in $ids) {
        $id = [guid]::Empty
        if ($value -isnot [string] -or -not [guid]::TryParseExact($value, 'D', [ref]$id) -or $id -eq [guid]::Empty) {
            throw [System.IO.InvalidDataException]::new('The candidate test identity must have a valid tenant and client ID.')
        }
    }
    $subscriptions = @($Settings['test_subscription_ids'])
    if ($subscriptions.Count -eq 0) {
        throw [System.IO.InvalidDataException]::new('The candidate has no configured non-production test subscriptions.')
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $validated = @(
        foreach ($subscription in $subscriptions) {
            $id = [guid]::Empty
            if ($subscription -isnot [System.Collections.IDictionary] -or
                $subscription['id'] -isnot [string] -or
                -not [guid]::TryParseExact($subscription['id'], 'D', [ref]$id) -or
                $id -eq [guid]::Empty -or -not $seen.Add($id.ToString()) -or
                [string]::IsNullOrWhiteSpace([string]$subscription['name'])) {
                throw [System.IO.InvalidDataException]::new('The candidate test subscription list has an invalid or duplicate entry.')
            }
            [ordered]@{ id = $id.ToString(); name = [string]$subscription['name'] }
        }
    )
    return [ordered]@{
        tenantId      = ([guid]$Settings['tenant_id']).ToString()
        clientId      = ([guid]$Settings['client_id']).ToString()
        subscriptions = $validated
    }
}

function Save-RepositorySyncCandidateTestSettings {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary]$Plan,
        [Parameter(Mandatory)] [string]$Directory
    )

    $plannedValues = if ($Plan.Contains('planned_values')) { $Plan['planned_values'] } else { $null }
    $outputs = if ($plannedValues -is [System.Collections.IDictionary] -and $plannedValues.Contains('outputs')) {
        $plannedValues['outputs']
    } else {
        $null
    }
    $settings = if ($outputs -and $outputs.Contains('test_settings')) {
        $outputs['test_settings']['value']
    } else {
        $null
    }
    if ($settings -isnot [System.Collections.IDictionary]) {
        throw [System.IO.InvalidDataException]::new(
            'The Terraform plan has no effective test_settings output. Roll out the module-identity federation prerequisite first.')
    }
    $validated = ConvertTo-RepositorySyncTestSettings -Settings $settings
    [System.IO.File]::WriteAllText(
        (Join-Path $Directory 'test-settings.json'),
        (ConvertTo-Json -InputObject $validated -Depth 6) + "`n",
        [System.Text.UTF8Encoding]::new($false))
}

function Read-RepositorySyncTestSettings {
    param([Parameter(Mandatory)] [string]$Directory)

    $settings = Get-Content -LiteralPath (Join-Path $Directory 'test-settings.json') -Raw -ErrorAction Stop |
        ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($settings -isnot [System.Collections.IDictionary]) {
        throw [System.IO.InvalidDataException]::new('The candidate test settings artifact is invalid.')
    }
    return ConvertTo-RepositorySyncTestSettings -Settings @{
        tenant_id             = $settings.tenantId
        client_id             = $settings.clientId
        test_subscription_ids = $settings.subscriptions
    }
}

function Save-RepositorySyncValidationReceipt {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary]$Candidate,
        [Parameter(Mandatory)] [string]$Directory
    )

    $null = New-Item -ItemType Directory -Path $Directory -Force
    $receipt = [ordered]@{
        schemaVersion = 1
        repository    = $Candidate.repository
        phase         = $Candidate.phase
        baseSha       = if ($Candidate.phase -ceq 'prepared') { $Candidate.baseSha } else { $null }
        hasChanges    = $Candidate.hasChanges
        treeSha       = if ($Candidate.hasChanges) { $Candidate.treeSha } else { $null }
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $Directory 'validation.json'),
        (ConvertTo-Json -InputObject $receipt -Depth 5) + "`n",
        [System.Text.UTF8Encoding]::new($false))
}

function Assert-RepositorySyncValidationReceipt {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary]$Candidate,
        [Parameter(Mandatory)] [string]$Directory
    )

    $receipt = Get-Content -LiteralPath (Join-Path $Directory 'validation.json') -Raw -ErrorAction Stop |
        ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $required = @('schemaVersion', 'repository', 'phase', 'baseSha', 'hasChanges', 'treeSha')
    if ($receipt -isnot [System.Collections.IDictionary] -or
        @($required | Where-Object { -not $receipt.Contains($_) }).Count -gt 0) {
        throw [System.IO.InvalidDataException]::new('The validation receipt does not match the staged candidate.')
    }
    if ($receipt.schemaVersion -ne 1 -or $receipt.repository -cne $Candidate.repository -or
        $receipt.phase -cne $Candidate.phase -or
        ($Candidate.phase -ceq 'prepared' -and $receipt.baseSha -cne $Candidate.baseSha) -or
        $receipt.hasChanges -isnot [bool] -or $receipt.hasChanges -ne $Candidate.hasChanges -or
        ($Candidate.hasChanges -and $receipt.treeSha -cne $Candidate.treeSha)) {
        throw [System.IO.InvalidDataException]::new('The validation receipt does not match the staged candidate.')
    }
}

function Format-RepositorySyncCandidateCheckResult {
    param(
        [Parameter(Mandatory)] [ValidateSet('pr-check', 'unit')] [string]$Check,
        [Parameter(Mandatory)] [object]$Result
    )

    if ($Result.Status -ceq 'pass') {
        return @()
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Candidate ${Check}: $($Result.Status)")
    $steps = $Result.PSObject.Properties['Steps']
    $details = @(if ($Check -eq 'pr-check') {
        if ($null -ne $steps) {
            $steps.Value | Where-Object { $null -ne $_ -and $_.Status -in @('fail', 'error') }
        }
    }
    else {
        $Result
    })

    if ($details.Count -eq 0) {
        $lines.Add('  No failing steps were returned.')
    }
    foreach ($detail in $details) {
        $label = if ($Check -eq 'pr-check') { [string]$detail.Step } else { 'unit tests' }
        $lines.Add("  ${label}: $($detail.Status)")
        $errorProperty = $detail.PSObject.Properties['Error']
        $hasError = $null -ne $errorProperty -and -not [string]::IsNullOrWhiteSpace([string]$errorProperty.Value)
        if ($hasError) {
            $lines.Add('    ' + ([string]$errorProperty.Value -replace '[\r\n\t]+', ' ').Trim())
        }

        $nested = $detail.PSObject.Properties['Result']
        $checkResult = if ($Check -eq 'pr-check') {
            if ($null -ne $nested) { $nested.Value } else { $null }
        }
        else {
            $detail
        }
        if ($null -eq $checkResult) {
            if (-not $hasError) {
                $lines.Add('    No structured diagnostics were returned.')
            }
            continue
        }
        $runs = $checkResult.PSObject.Properties['RunsTotal']
        if ($null -ne $runs) {
            $lines.Add("    $($runs.Value) test run(s); $($checkResult.RunsFailed) failed.")
        }
        $issueProperty = $checkResult.PSObject.Properties['Issues']
        $issues = @(if ($null -ne $issueProperty) {
            $issueProperty.Value | Where-Object { $null -ne $_ }
        })
        $blocking = @($issues | Where-Object {
                $severity = $_.PSObject.Properties['Severity']
                $null -ne $severity -and $severity.Value -in @('error', 'warning')
            })
        if ($label -eq 'lint' -and $blocking.Count -gt 0) {
            $issues = $blocking
        }
        foreach ($issue in $issues) {
            $severity = if ($issue.PSObject.Properties['Severity']) { [string]$issue.Severity } else { 'issue' }
            $file = if ($issue.PSObject.Properties['File']) { [string]$issue.File } else { '' }
            $line = if ($issue.PSObject.Properties['Line'] -and [int]$issue.Line -gt 0) { ":$($issue.Line)" } else { '' }
            $position = if ($file) { "${file}${line}: " } else { '' }
            $code = if ($issue.PSObject.Properties['Code'] -and $issue.Code) { "[$($issue.Code)] " } else { '' }
            $message = if ($issue.PSObject.Properties['Message']) { [string]$issue.Message } else { [string]$issue }
            $lines.Add("    ${position}[${severity}] ${code}$(($message -replace '[\r\n\t]+', ' ').Trim())")
        }
        if ($issues.Count -eq 0 -and -not $hasError) {
            $lines.Add($(if ($Check -eq 'unit' -and $Result.Status -ceq 'skipped') {
                        '    No unit tests found; unit validation is skipped.'
                    }
                    else {
                        '    No structured diagnostics were returned.'
                    }))
        }
    }

    return $lines.ToArray()
}

function Get-RepositorySyncCandidateRepoId {
    param([Parameter(Mandatory)] [string]$Repository)

    if ($Repository -cnotmatch '^[A-Za-z0-9_.-]+/terraform-(?:azure|azapi|azurerm)-(?<id>avm-(?:res|ptn|utl)-[a-z0-9-]+)$') {
        throw [System.IO.InvalidDataException]::new('The candidate repository has no valid AVM Terraform module ID.')
    }
    return $Matches['id']
}

function Initialize-RepositorySyncCandidateIndex {
    param([Parameter(Mandatory)] [string]$Root)

    $infoDirectory = Join-Path $Root '.git' 'info'
    $null = New-Item -ItemType Directory -Path $infoDirectory -Force
    $attributesPath = Join-Path $infoDirectory 'attributes'
    $hadAttributes = Test-Path -LiteralPath $attributesPath -PathType Leaf
    $originalAttributes = $null
    if ($hadAttributes) {
        $originalAttributes = [System.IO.File]::ReadAllBytes($attributesPath)
    }
    try {
        [System.IO.File]::WriteAllText(
            $attributesPath,
            "* -text -filter -ident -working-tree-encoding`n",
            [System.Text.UTF8Encoding]::new($false))
        $null = Invoke-RepositoryGit -WorkingDirectory $Root -Arguments @('add', '--all', '--force')
        return Invoke-RepositoryGit -WorkingDirectory $Root -Arguments @('write-tree')
    }
    finally {
        if ($hadAttributes) {
            [System.IO.File]::WriteAllBytes($attributesPath, $originalAttributes)
        } elseif (Test-Path -LiteralPath $attributesPath -PathType Leaf) {
            Remove-Item -LiteralPath $attributesPath -Force -ErrorAction Stop
        }
    }
}

function Invoke-RepositorySyncCandidateValidation {
    param(
        [Parameter(Mandatory)] [string]$Repository,
        [Parameter(Mandatory)] [string]$CandidateDirectory,
        [Parameter(Mandatory)] [string]$ReceiptDirectory,
        [Parameter(Mandatory)] [string]$CheckoutModulePath
    )

    $candidate = Read-RepositorySyncCandidate -Directory $CandidateDirectory -Repository $Repository
    if ($candidate.phase -ceq 'skipped') {
        Save-RepositorySyncValidationReceipt -Candidate $candidate -Directory $ReceiptDirectory
        return 'Skipped'
    }
    if (-not $candidate.hasChanges) {
        Save-RepositorySyncValidationReceipt -Candidate $candidate -Directory $ReceiptDirectory
        return 'NoChange'
    }
    $settings = Read-RepositorySyncTestSettings -Directory $CandidateDirectory
    $subscription = $settings.subscriptions | Get-Random
    if ($candidate.authoringSource -ceq 'checkout') {
        Import-Module -Name $CheckoutModulePath -Force -ErrorAction Stop
    } else {
        Import-Module -Name Avm.Authoring -RequiredVersion ([version]$candidate.authoringVersion) -Force -ErrorAction Stop
    }
    $active = (Get-Command -Name Invoke-AvmPrCheck -CommandType Function -ErrorAction Stop).Module
    if ($active.Version.ToString() -cne $candidate.authoringVersion) {
        throw [System.InvalidOperationException]::new('The validation job loaded a different Avm.Authoring version than candidate preparation.')
    }
    $workspace = Join-Path ([System.IO.Path]::GetTempPath()) ('avm-candidate-validation-' + [guid]::NewGuid().ToString('N'))
    $root = Join-Path $workspace 'repository'
    $repositoryUrl = "https://github.com/$Repository.git"
    $null = New-Item -ItemType Directory -Path $root -Force
    $environmentNames = @(
        'ARM_CLIENT_ID', 'ARM_TENANT_ID', 'ARM_SUBSCRIPTION_ID', 'ARM_USE_OIDC', 'ARM_USE_CLI', 'ARM_USE_MSI',
        'GH_TOKEN', 'AVM_MANAGED_FILES_REPO_ID', 'AVM_MANAGED_FILES_CONFIG_LOCAL_PATH'
    )
    $previousEnvironment = @{}
    foreach ($name in $environmentNames) {
        $previousEnvironment[$name] = [System.Environment]::GetEnvironmentVariable($name, 'Process')
    }
    try {
        $archivePath = Join-Path $CandidateDirectory 'candidate.tar'
        $archive = Invoke-RepositorySyncProcess -Command 'tar' -Arguments @('-xf', $archivePath, '-C', $root) -TimeoutSec 600
        if ($archive.ExitCode -ne 0) {
            throw [System.IO.InvalidDataException]::new("Failed to unpack the staged candidate: $($archive.StdErr)")
        }
        $null = Invoke-RepositoryGit -WorkingDirectory $workspace -Arguments @('init', '--quiet', '-b', 'main', $root)
        $null = Invoke-RepositoryGit -WorkingDirectory $root -Arguments @('remote', 'add', 'origin', $repositoryUrl)
        $null = Invoke-RepositoryGit -WorkingDirectory $root -Arguments @('config', '--local', 'core.autocrlf', 'false')
        $null = Invoke-RepositoryGit -WorkingDirectory $root -Arguments @('config', '--local', 'core.hooksPath', (Join-Path $workspace 'disabled-hooks'))
        $tree = Initialize-RepositorySyncCandidateIndex -Root $root
        if ($tree -cne $candidate.treeSha) {
            throw [System.IO.InvalidDataException]::new('The unpacked candidate does not match the prepared Git tree.')
        }
        $null = Invoke-RepositoryGit -WorkingDirectory $root -Arguments @(
            '-c', 'user.name=AVM candidate validation', '-c', 'user.email=avm-validation@users.noreply.github.com',
            'commit', '--quiet', '-m', 'Validate staged candidate')
        $env:ARM_CLIENT_ID = $settings.clientId
        $env:ARM_TENANT_ID = $settings.tenantId
        $env:ARM_SUBSCRIPTION_ID = $subscription.id
        $env:ARM_USE_OIDC = 'true'
        $env:ARM_USE_CLI = 'false'
        $env:ARM_USE_MSI = 'false'
        $env:GH_TOKEN = $null
        $env:AVM_MANAGED_FILES_REPO_ID = Get-RepositorySyncCandidateRepoId -Repository $Repository
        $env:AVM_MANAGED_FILES_CONFIG_LOCAL_PATH = (Resolve-Path -LiteralPath (
                Join-Path $PSScriptRoot '..' '..' '..' 'repository-config') -ErrorAction Stop).Path
        Write-Host "Validating $Repository in test subscription '$($subscription.name)'."
        $prCheck = Invoke-AvmPrCheck -Path $root -Ecosystem terraform -SkipModuleVersionCheck
        $unitRoot = Join-Path $workspace 'unit'
        $null = Invoke-RepositoryGit -WorkingDirectory $workspace -Arguments @('clone', '--quiet', $root, $unitRoot)
        $null = Invoke-RepositoryGit -WorkingDirectory $unitRoot -Arguments @('remote', 'set-url', 'origin', $repositoryUrl)
        if ((Invoke-RepositoryGit -WorkingDirectory $unitRoot -Arguments @('rev-parse', 'HEAD^{tree}')) -cne $candidate.treeSha) {
            throw [System.IO.InvalidDataException]::new('The unit-test checkout differs from the validated candidate.')
        }
        $unitTests = Invoke-AvmTestUnit -Path $unitRoot -Ecosystem terraform -SkipModuleVersionCheck
        foreach ($line in (Format-RepositorySyncCandidateCheckResult -Check 'pr-check' -Result $prCheck)) {
            Write-Host $line
        }
        foreach ($line in (Format-RepositorySyncCandidateCheckResult -Check 'unit' -Result $unitTests)) {
            Write-Host $line
        }
        if ($prCheck.Status -cne 'pass' -or $unitTests.Status -cnotin @('pass', 'skipped')) {
            $failedSteps = @($prCheck.Steps | Where-Object Status -in @('fail', 'error') | ForEach-Object {
                    "$($_.Step): $($_.Status)"
                })
            throw [System.InvalidOperationException]::new(
                "Candidate checks failed for ${Repository}: pr-check=$($prCheck.Status) ($($failedSteps -join ', ')); unit=$($unitTests.Status).")
        }
        if (-not [string]::IsNullOrWhiteSpace((Invoke-RepositoryGit -WorkingDirectory $root -Arguments @('status', '--porcelain'))) -or
            (Invoke-RepositoryGit -WorkingDirectory $root -Arguments @('rev-parse', 'HEAD^{tree}')) -cne $candidate.treeSha) {
            throw [System.InvalidOperationException]::new('Candidate checks changed the prepared file tree.')
        }
        Save-RepositorySyncValidationReceipt -Candidate $candidate -Directory $ReceiptDirectory
        return 'Passed'
    }
    finally {
        foreach ($name in $environmentNames) {
            [System.Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
        }
        if (Test-Path -LiteralPath $workspace -PathType Container) {
            Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction Stop
        }
    }
}

function Invoke-RepositorySyncCandidatePublication {
    param(
        [Parameter(Mandatory)] [string]$Repository,
        [Parameter(Mandatory)] [string]$CandidateDirectory,
        [Parameter(Mandatory)] [string]$ReceiptDirectory
    )

    $candidate = Read-RepositorySyncCandidate -Directory $CandidateDirectory -Repository $Repository
    Assert-RepositorySyncValidationReceipt -Candidate $candidate -Directory $ReceiptDirectory
    if ($candidate.phase -ceq 'skipped') {
        return @{ Status = 'Skipped'; HasChanges = $false }
    }
    if ($candidate.planOnly) {
        throw [System.InvalidOperationException]::new('Plan-only candidates cannot be published.')
    }
    if (-not $candidate.hasChanges) {
        return @{ Status = 'NoChange'; HasChanges = $false }
    }
    $patchPath = Join-Path $CandidateDirectory 'candidate.patch'
    $published = Invoke-RepositoryFileSync -Repository $Repository -DefaultBranch $candidate.defaultBranch `
        -ExpectedBaseSha $candidate.baseSha -State @{ Candidate = $candidate; PatchPath = $patchPath } `
        -Prepare {
            param($context)
            if ($context.BaseSha -cne $context.State.Candidate.baseSha) {
                throw [System.InvalidOperationException]::new('The target branch moved since candidate validation; run repository sync again.')
            }
            $null = Invoke-RepositoryGit -WorkingDirectory $context.Root -Arguments @('apply', '--index', '--binary', '--', $context.State.PatchPath)
            $tree = Invoke-RepositoryGit -WorkingDirectory $context.Root -Arguments @('write-tree')
            if ($tree -cne $context.State.Candidate.treeSha) {
                throw [System.IO.InvalidDataException]::new('The prepared patch does not produce the validated Git tree.')
            }
            $paths = Invoke-RepositoryGit -WorkingDirectory $context.Root -Arguments @('diff', '--cached', '--no-renames', '--name-only', '-z')
            Assert-RepositorySyncFileScope -Paths @($paths.Split([char]0, [System.StringSplitOptions]::RemoveEmptyEntries)) `
                -AllowedPaths @() -ExpectedPaths $context.State.Candidate.changedPaths
        }
    if (-not $published.HasChanges -or $published.Status -cne 'Merged') {
        throw [System.InvalidOperationException]::new('The validated candidate was not published and merged.')
    }
    return $published
}
