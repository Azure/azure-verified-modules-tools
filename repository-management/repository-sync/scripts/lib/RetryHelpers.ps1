# Retry wrappers used by the repository sync pipeline.
#
# All three functions return an array of `@{ success = $bool; output = ... }`
# hashtables, one per command. PowerShell unwraps single-element arrays, so
# single-command callers can access fields directly via `$result.success`
# without indexing into `[0]`.

function Get-GitHubTransientRetryPatterns {
    return @(
        "API rate limit exceeded",
        "tls: failed to verify certificate",
        "x509: certificate is not valid for any names",
        "x509: certificate signed by unknown authority",
        "self-signed certificate",
        "connection reset",
        "unexpected EOF"
    )
}

function Test-CommandResultsSucceeded {
    param([object[]]$results)

    if (!$results) {
        return $false
    }

    foreach ($result in $results) {
        if (!$result.success) {
            return $false
        }
    }

    return $true
}

function Invoke-TerraformWithRetry {
    param(
        [hashtable[]]$commands,
        [string]$workingDirectory,
        [string]$outputLog = "output.log",
        [string]$errorLog = "error.log",
        [int]$maxRetries = 50,
        [int]$retryDelayIncremental = 10,
        [string[]]$retryOn = @(
            "429 Too Many Requests",
            "500 Internal Server Error",
            "502 Bad Gateway",
            "503 Service Unavailable",
            "504 Gateway Timeout",
            "Client.Timeout exceeded while awaiting headers",
            "Error: Failed to install provider",
            "Error: Failed to query available provider packages",
            "failed to retrieve cryptographic signature for provider",
            "403 API rate limit",
            "tls: failed to verify certificate",
            "x509: certificate is not valid for any names",
            "x509: certificate signed by unknown authority",
            "self-signed certificate"
        ),
        [string]$stateStorageAccountName,
        [string]$stateContainerName,
        [string]$stateBlobName,
        [string]$stateSubscriptionId,
        [switch]$printOutput,
        [switch]$printOutputOnError,
        [switch]$returnOutputParsedFromJson
    )

    foreach ($command in $commands) {
        $command.Arguments = @("-chdir=$workingDirectory") + $command.Arguments
    }

    return Invoke-CommandWithRetry `
        -parentCommand "terraform" `
        -commands $commands `
        -outputLog $outputLog `
        -errorLog $errorLog `
        -maxRetries $maxRetries `
        -retryDelayIncremental $retryDelayIncremental `
        -retryOn $retryOn `
        -printOutput:$printOutput.IsPresent `
        -printOutputOnError:$printOutputOnError.IsPresent `
        -returnOutputParsedFromJson:$returnOutputParsedFromJson.IsPresent
}

function Test-RepositorySyncLockAcquisitionFailure {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string[]] $Text)

    $lines = @(Remove-AnsiEscapeCode -text (($Text -join "`n") -split '\r?\n') |
        ForEach-Object { ($_ -replace '^[\s\u2502]+', '').TrimEnd() })
    $headings = @($lines | Where-Object { $_ -cmatch '^(Error:|Error (acquiring|releasing) the state lock)' })
    return $headings.Count -eq 1 -and $headings[0] -cmatch '^(Error:\s*)?Error acquiring the state lock$'
}

function Invoke-RepositorySyncLockRead {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('az', 'gh')] [string] $Command,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [hashtable] $Environment = @{}
    )

    try {
        $result = Invoke-RepositorySyncProcess -Command $Command -Arguments $Arguments -EnvVars $Environment -TimeoutSec 60
    }
    catch [System.TimeoutException] {
        throw [System.TimeoutException]::new('State-lock inspection timed out; no release or Terraform retry is permitted.')
    }
    if ($result.ExitCode -ne 0) {
        $detail = Protect-RepositorySyncLogText -Text $result.StdErr -Environment $Environment
        throw [System.InvalidOperationException]::new("State-lock inspection failed using $Command (exit $($result.ExitCode)). $detail")
    }
    try {
        $value = ConvertFrom-Json -InputObject $result.StdOut -AsHashtable -Depth 30 -ErrorAction Stop
    }
    catch {
        throw [System.IO.InvalidDataException]::new('State-lock inspection returned invalid JSON; raw output is private.')
    }
    if ($value -isnot [System.Collections.IDictionary]) {
        throw [System.IO.InvalidDataException]::new('State-lock inspection must return one metadata object.')
    }
    return $value
}

function Assert-RepositorySyncNoCompetingWriter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoId,
        [Parameter(Mandatory)] [string] $Repository,
        [string] $LockOwner,
        [hashtable] $Environment = @{}
    )

    $tools = 'Azure/azure-verified-modules-tools'
    $workflow = '.github/workflows/repository-management-sync.yml'
    if ($env:GITHUB_ACTIONS -cne 'true' -or $env:GITHUB_REPOSITORY -cne $tools -or
        $env:GITHUB_REF -cne 'refs/heads/main' -or $env:GITHUB_WORKFLOW_REF -cne "$tools/$workflow@refs/heads/main" -or
        $env:GITHUB_RUN_ID -cnotmatch '^[1-9][0-9]*$' -or $env:GITHUB_RUN_ATTEMPT -cnotmatch '^[1-9][0-9]*$' -or
        [string]::IsNullOrWhiteSpace($env:RUNNER_NAME)) {
        throw [System.InvalidOperationException]::new('Automatic lock recovery requires the trusted Terraform Sync workflow on Tools main.')
    }
    if ([string]::IsNullOrWhiteSpace($env:ACTIONS_STATE_LOCK_TOKEN)) {
        throw [System.InvalidOperationException]::new('Automatic lock recovery requires the repository-scoped Actions read token.')
    }
    $readEnvironment = $Environment.Clone()
    $readEnvironment.GH_TOKEN = $env:ACTIONS_STATE_LOCK_TOKEN
    $readEnvironment.ACTIONS_STATE_LOCK_TOKEN = $null
    $api = @('api', '--hostname', 'github.com', '--method', 'GET')
    $run = Invoke-RepositorySyncLockRead -Command gh -Environment $readEnvironment `
        -Arguments ($api + "repos/$tools/actions/runs/$env:GITHUB_RUN_ID")
    if ([string]$run['id'] -cne $env:GITHUB_RUN_ID -or [string]$run['run_attempt'] -cne $env:GITHUB_RUN_ATTEMPT -or
        $run['status'] -cne 'in_progress' -or $run['path'] -cne $workflow -or $run['head_branch'] -cne 'main' -or
        $run['head_repository'] -isnot [System.Collections.IDictionary] -or $run['head_repository']['full_name'] -cne $tools -or
        [string]$run['workflow_id'] -cnotmatch '^[1-9][0-9]*$') {
        throw [System.InvalidOperationException]::new('GitHub did not verify the current trusted sync run and attempt.')
    }
    $active = Invoke-RepositorySyncLockRead -Command gh -Environment $readEnvironment `
        -Arguments ($api + "repos/$tools/actions/workflows/$($run['workflow_id'])/runs?status=in_progress&per_page=100")
    if ($active['total_count'] -ne 1 -or $active['workflow_runs'] -isnot [System.Collections.IList] -or
        $active['workflow_runs'].Count -ne 1 -or [string]$active['workflow_runs'][0]['id'] -cne $env:GITHUB_RUN_ID -or
        $active['workflow_runs'][0]['status'] -cne 'in_progress') {
        throw [System.InvalidOperationException]::new('Another active sync run or incomplete run evidence prevents automatic lock recovery.')
    }
    $jobs = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $expected = $null
    $page = 1
    do {
        $response = Invoke-RepositorySyncLockRead -Command gh -Environment $readEnvironment `
            -Arguments ($api + "repos/$tools/actions/runs/$env:GITHUB_RUN_ID/attempts/$env:GITHUB_RUN_ATTEMPT/jobs?per_page=100&page=$page")
        if ([string]$response['total_count'] -cnotmatch '^[1-9][0-9]*$' -or
            $response['jobs'] -isnot [System.Collections.IList] -or $response['jobs'].Count -eq 0 -or $response['jobs'].Count -gt 100 -or
            ($null -ne $expected -and $expected -ne $response['total_count'])) {
            throw [System.IO.InvalidDataException]::new('The current sync job inventory is incomplete or changed during inspection.')
        }
        $expected = $response['total_count']
        foreach ($job in $response['jobs']) {
            if ($job -isnot [System.Collections.IDictionary] -or [string]$job['id'] -cnotmatch '^[1-9][0-9]*$' -or
                -not $seen.Add([string]$job['id'])) {
                throw [System.IO.InvalidDataException]::new('The current sync job inventory is ambiguous.')
            }
            $jobs.Add($job)
        }
        $page++
    } while ($jobs.Count -lt $expected)
    $workerPattern = '^Sync (?<repository>terraform-(?:azure|azurerm|azapi)-' +
        [regex]::Escape($RepoId) + ')(?: / Prepare \k<repository>)?$'
    $repositoryName = $Repository.Split('/')[1]
    $workerNames = @("Sync $repositoryName", "Sync $repositoryName / Prepare $repositoryName")
    $matching = @($jobs | Where-Object {
        $_['status'] -ceq 'in_progress' -and $_['name'] -cmatch $workerPattern
    })
    if ($jobs.Count -ne $expected -or $matching.Count -ne 1 -or
        $matching[0]['name'] -cnotin $workerNames -or $matching[0]['runner_name'] -cne $env:RUNNER_NAME) {
        throw [System.InvalidOperationException]::new('An active competing state writer or unverified current worker prevents automatic lock recovery.')
    }
    if (-not [string]::IsNullOrWhiteSpace($LockOwner)) {
        $ownerHost = ($LockOwner -split '@')[-1]
        if (@($jobs | Where-Object { $_['status'] -ceq 'in_progress' -and $_['runner_name'] -ceq $ownerHost }).Count -gt 0) {
            throw [System.InvalidOperationException]::new('The observed lock owner matches an active Actions worker; automatic release is refused.')
        }
    }
}

function Get-RepositorySyncStateBlobLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Backend,
        [Parameter(Mandatory)] [string] $BlobName,
        [hashtable] $Environment = @{}
    )

    $snapshot = Invoke-RepositorySyncLockRead -Command az -Environment $Environment -Arguments @(
        'storage', 'blob', 'show', '--account-name', $Backend.StorageAccountName,
        '--container-name', $Backend.ContainerName, '--name', $BlobName,
        '--auth-mode', 'login', '--subscription', $Backend.SubscriptionId, '--only-show-errors', '--output', 'json',
        '--query', '{etag:properties.etag,leaseState:properties.lease.state,leaseStatus:properties.lease.status,lockInfo:metadata.terraformlockid}'
    )
    if ($snapshot['etag'] -isnot [string] -or $snapshot['etag'] -cnotmatch '^(?:"0x[0-9a-fA-F]+"|0x[0-9a-fA-F]+)$' -or
        $snapshot['leaseState'] -cnotin @('available', 'leased', 'expired', 'breaking', 'broken') -or
        $snapshot['leaseStatus'] -cnotin @('locked', 'unlocked') -or
        ($null -ne $snapshot['lockInfo'] -and $snapshot['lockInfo'] -isnot [string])) {
        throw [System.IO.InvalidDataException]::new('The selected state blob has incomplete lease metadata.')
    }
    $lockId = $null
    $lockOwner = ''
    if (-not [string]::IsNullOrEmpty($snapshot['lockInfo'])) {
        try {
            $json = [Text.UTF8Encoding]::new($false, $true).GetString([Convert]::FromBase64String($snapshot['lockInfo']))
            $info = ConvertFrom-Json -InputObject $json -AsHashtable -ErrorAction Stop
        }
        catch {
            throw [System.IO.InvalidDataException]::new('The selected state lock metadata is malformed; it cannot be released automatically.')
        }
        $parsedId = [guid]::Empty
        if ($info -isnot [System.Collections.IDictionary] -or $info['ID'] -isnot [string] -or
            -not [guid]::TryParseExact($info['ID'], 'D', [ref]$parsedId) -or $parsedId -eq [guid]::Empty -or
            $info['Path'] -cne "$($Backend.ContainerName)/$BlobName") {
            throw [System.InvalidOperationException]::new('The observed Terraform lock does not identify the exact selected state blob.')
        }
        $lockId = $parsedId.ToString()
        if ($info['Who'] -is [string]) { $lockOwner = $info['Who'] }
    }
    return @{
        ETag = $snapshot['etag']
        State = $snapshot['leaseState']
        Status = $snapshot['leaseStatus']
        Metadata = $snapshot['lockInfo']
        LockId = $lockId
        Owner = $lockOwner
    }
}

function Clear-TerraformStateLock {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]]$errorOutput,
        [string]$workingDirectory,
        [string]$storageAccountName,
        [string]$containerName,
        [string]$blobName,
        [string]$subscriptionId,
        [string]$tenantId,
        [string]$clientId,
        [string]$repository,
        [hashtable]$environment = @{}
    )

    if (-not (Test-RepositorySyncLockAcquisitionFailure -Text $errorOutput)) {
        throw [System.ArgumentException]::new('Lock recovery is permitted only for a native state-lock acquisition failure.')
    }
    $backend = Resolve-RepositorySyncStateConfiguration -Backend @{
        TenantId = $tenantId; SubscriptionId = $subscriptionId; ClientId = $clientId
        StorageAccountName = $storageAccountName; ContainerName = $containerName
    }
    if ($blobName -cnotmatch '^(avm-(res|ptn|utl)-[a-z0-9]+(?:-[a-z0-9]+)*)\.tfstate$') {
        throw [System.ArgumentException]::new('Lock recovery requires the exact canonical repository state blob.')
    }
    $repoId = $blobName.Substring(0, $blobName.Length - '.tfstate'.Length)
    if ($repository -cnotmatch ('^Azure/terraform-(azure|azurerm|azapi)-' + [regex]::Escape($repoId) + '$')) {
        throw [System.ArgumentException]::new('Lock recovery repository and state blob must identify the same module.')
    }
    if (-not $PSCmdlet.ShouldProcess("$storageAccountName/$containerName/$blobName", 'Attempt one automatic state-lock recovery')) {
        return $false
    }
    $environment = $environment.Clone()
    foreach ($name in (@([Environment]::GetEnvironmentVariables().Keys) + @($environment.Keys) |
        Where-Object { $_ -like 'AZURE_STORAGE_*' })) {
        $environment[$name] = $null
    }
    $dataRoot = Join-Path $workingDirectory '.terraform'
    if ($environment['TF_WORKSPACE'] -cne 'default' -or $environment['TF_DATA_DIR'] -cne $dataRoot) {
        throw [System.InvalidOperationException]::new('Lock recovery requires the initialized default workspace and its explicit data directory.')
    }
    try {
        $metadata = Get-Content -LiteralPath (Join-Path $dataRoot 'terraform.tfstate') -Raw -ErrorAction Stop |
            ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch {
        throw [System.IO.InvalidDataException]::new('Cannot verify initialized backend metadata for lock recovery; raw metadata is private.')
    }
    if ($metadata -isnot [System.Collections.IDictionary] -or
        $metadata['backend'] -isnot [System.Collections.IDictionary] -or $metadata['backend']['type'] -cne 'azurerm' -or
        $metadata['backend']['config'] -isnot [System.Collections.IDictionary]) {
        throw [System.InvalidOperationException]::new('Lock recovery requires the explicitly initialized Azure backend.')
    }
    $expected = @{
        tenant_id = $backend.TenantId; subscription_id = $backend.SubscriptionId; client_id = $backend.ClientId
        storage_account_name = $backend.StorageAccountName; container_name = $backend.ContainerName; key = $blobName
        use_azuread_auth = $true; use_oidc = $true; use_cli = $false; use_msi = $false; lookup_blob_endpoint = $false
    }
    foreach ($key in $expected.Keys) {
        if ([string]$metadata['backend']['config'][$key] -cne [string]$expected[$key]) {
            throw [System.InvalidOperationException]::new("Initialized backend '$key' does not match the selected recovery target.")
        }
    }
    Assert-RepositorySyncNoCompetingWriter -RepoId $repoId -Repository $repository -Environment $environment
    $account = Invoke-RepositorySyncLockRead -Command az -Environment $environment -Arguments @(
        'account', 'show', '--subscription', $backend.SubscriptionId, '--output', 'json', '--only-show-errors',
        '--query', '{id:id,tenantId:tenantId,user:user}'
    )
    if ($account['id'] -ine $backend.SubscriptionId -or $account['tenantId'] -ine $backend.TenantId -or
        $account['user'] -isnot [System.Collections.IDictionary] -or $account['user']['type'] -cne 'servicePrincipal' -or
        $account['user']['name'] -ine $backend.ClientId) {
        throw [System.InvalidOperationException]::new('Azure CLI must be authenticated as the selected state backend identity, not the provider or a user.')
    }
    $observed = Get-RepositorySyncStateBlobLock -Backend $backend -BlobName $blobName -Environment $environment
    if ($observed.Status -ceq 'unlocked' -and $observed.State -cin @('available', 'expired', 'broken')) {
        Write-Information 'The selected state lock is no longer held; retrying acquisition once.' -InformationAction Continue
        return $true
    }
    if ($observed.State -cne 'leased' -or $observed.Status -cne 'locked') {
        throw [System.InvalidOperationException]::new('The selected state lease is transitioning; it will not be changed automatically.')
    }
    $diagnostic = ConvertTo-FlatErrorText -text (Remove-AnsiEscapeCode -text $errorOutput)
    $reported = [regex]::Matches($diagnostic, '(?:^|\s)ID:\s*([0-9a-fA-F-]{36})(?=\s|$)')
    if ($reported.Count -gt 1 -or ($reported.Count -eq 1 -and $reported[0].Groups[1].Value -ine $observed.LockId)) {
        throw [System.InvalidOperationException]::new('The reported lock ID no longer matches the selected state lock.')
    }
    $reportedPaths = [regex]::Matches($diagnostic, '(?:^|\s)Path:\s*(\S+)')
    if ($reportedPaths.Count -gt 1 -or ($reportedPaths.Count -eq 1 -and $reportedPaths[0].Groups[1].Value -cne "$containerName/$blobName")) {
        throw [System.InvalidOperationException]::new('The reported lock path does not match the selected state blob.')
    }
    Assert-RepositorySyncNoCompetingWriter -RepoId $repoId -Repository $repository -LockOwner $observed.Owner -Environment $environment
    $current = Get-RepositorySyncStateBlobLock -Backend $backend -BlobName $blobName -Environment $environment
    foreach ($key in @('ETag', 'State', 'Status', 'Metadata')) {
        if ($observed[$key] -cne $current[$key]) {
            throw [System.InvalidOperationException]::new('The observed state lock or lease changed before release; recovery is refused.')
        }
    }
    Write-Warning "Attempting automatic recovery of the unverified lock on '$storageAccountName/$containerName/$blobName'; no active competing sync writer was observed."
    if ($observed.LockId) {
        $result = Invoke-RepositorySyncProcess -Command terraform -WorkingDirectory $workingDirectory -EnvVars $environment `
            -Arguments @('force-unlock', '-force', $observed.LockId) -TimeoutSec 60
        if ($result.ExitCode -ne 0) {
            $detail = Protect-RepositorySyncLogText -Text $result.StdErr -Environment $environment
            throw [System.InvalidOperationException]::new("Terraform force-unlock failed (exit $($result.ExitCode)); no lease-break fallback or command retry is permitted. $detail")
        }
    }
    else {
        $null = Clear-TerraformStateBlobLease -Backend $backend -BlobName $blobName -ETag $observed.ETag `
            -Environment $environment -Confirm:$false
    }
    $released = Get-RepositorySyncStateBlobLock -Backend $backend -BlobName $blobName -Environment $environment
    if ($released.Status -cne 'unlocked' -or $released.State -cnotin @('available', 'expired', 'broken')) {
        throw [System.InvalidOperationException]::new('The selected state lease is still held after recovery; Terraform will not be retried.')
    }
    Write-Information "Released the selected state lock on '$blobName'." -InformationAction Continue
    return $true
}

function Clear-TerraformStateBlobLease {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object] $Backend,
        [Parameter(Mandatory)] [string] $BlobName,
        [Parameter(Mandatory)] [ValidatePattern('^(?:"0x[0-9a-fA-F]+"|0x[0-9a-fA-F]+)$')] [string] $ETag,
        [hashtable] $Environment = @{}
    )

    if (-not $PSCmdlet.ShouldProcess("$($Backend.StorageAccountName)/$($Backend.ContainerName)/$BlobName", 'Break the unchanged state lease with missing lock metadata')) {
        return $false
    }
    $result = Invoke-RepositorySyncProcess -Command az -EnvVars $Environment -TimeoutSec 60 -Arguments @(
        'storage', 'blob', 'lease', 'break', '--account-name', $Backend.StorageAccountName,
        '--container-name', $Backend.ContainerName, '--blob-name', $BlobName, '--lease-break-period', '0',
        '--if-match', $ETag, '--auth-mode', 'login', '--subscription', $Backend.SubscriptionId, '--only-show-errors', '--output', 'none'
    )
    if ($result.ExitCode -ne 0) {
        $detail = Protect-RepositorySyncLogText -Text $result.StdErr -Environment $Environment
        throw [System.InvalidOperationException]::new("The conditional state lease break failed (exit $($result.ExitCode)); Terraform will not be retried. $detail")
    }
    return $true
}

function Invoke-GitHubCliWithRetry {
    param(
        [hashtable[]]$commands,
        [string]$outputLog = "output.log",
        [string]$errorLog = "error.log",
        [int]$maxRetries = 50,
        [int]$retryDelayIncremental = 10,
        [string[]]$retryOn = (Get-GitHubTransientRetryPatterns),
        [switch]$printOutput,
        [switch]$printOutputOnError,
        [switch]$returnOutput,
        [switch]$returnOutputParsedFromJson,
        [switch]$literalArguments,
        [string]$workingDirectory
    )

    return Invoke-CommandWithRetry `
        -parentCommand "gh" `
        -commands $commands `
        -outputLog $outputLog `
        -errorLog $errorLog `
        -maxRetries $maxRetries `
        -retryDelayIncremental $retryDelayIncremental `
        -retryOn $retryOn `
        -printOutput:$printOutput.IsPresent `
        -printOutputOnError:$printOutputOnError.IsPresent `
        -returnOutput:$returnOutput.IsPresent `
        -returnOutputParsedFromJson:$returnOutputParsedFromJson.IsPresent `
        -literalArguments:$literalArguments.IsPresent `
        -workingDirectory $workingDirectory
}

function Invoke-RepositorySyncProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Command,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [string] $WorkingDirectory,
        [hashtable] $EnvVars = @{},
        [ValidateRange(1, 3600)] [int] $TimeoutSec = 300,
        [scriptblock] $OnOutputLine
    )

    $module = Get-Module Avm.Authoring | Select-Object -First 1
    if (-not $module) {
        throw [System.InvalidOperationException]::new('Import Avm.Authoring before invoking repository-sync commands.')
    }
    $executable = (Get-Command -Name $Command -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $environment = $EnvVars.Clone()
    $environment.GH_HOST = 'github.com'
    $environment.GITHUB_TOKEN = $null
    $environment.GH_DEBUG = $null
    $environment.GH_PROMPT_DISABLED = '1'
    return & $module {
        param($Executable, $Arguments, $Directory, $Environment, $Timeout, $OutputHandler)
        $options = @{}
        if ($null -ne $OutputHandler) {
            $options.StreamOutput = $true
            $options.OnStdOutLine = $OutputHandler
            $options.OnStdErrLine = $OutputHandler
        }
        Invoke-AvmProcess -FilePath $Executable -ArgumentList $Arguments -WorkingDirectory $Directory `
            -TimeoutSec $Timeout -IgnoreExitCode -EnvVars $Environment @options
    } $executable $Arguments $WorkingDirectory $environment $TimeoutSec $OnOutputLine
}

function Invoke-RepositoryGitHub {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [switch] $AsJson,
        [int] $MaxRetries = 5
    )

    $result = Invoke-GitHubCliWithRetry -commands @(@{ Arguments = $Arguments }) `
        -literalArguments -maxRetries $MaxRetries -retryDelayIncremental 5 `
        -returnOutput:(!$AsJson) -returnOutputParsedFromJson:$AsJson
    if (-not $result.success) {
        $detail = if ($result.ContainsKey('error')) { $result.error } else { 'retry attempts exhausted' }
        throw [System.InvalidOperationException]::new("GitHub operation failed: $detail")
    }
    return $result.output
}

function Invoke-RepositoryGitHubApi {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Endpoint)

    return Invoke-RepositoryGitHub -AsJson -Arguments @(
        'api', '--hostname', 'github.com', '--method', 'GET',
        '--header', 'Accept: application/vnd.github+json',
        '--header', 'X-GitHub-Api-Version: 2022-11-28', $Endpoint
    )
}

function Invoke-RepositoryGit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [string] $WorkingDirectory,
        [int] $MaxRetries = 0
    )

    $arguments = @('-c', 'credential.helper=', '-c', 'credential.helper=!gh auth git-credential') + $Arguments
    $result = Invoke-CommandWithRetry -parentCommand git -commands @(@{ Arguments = $arguments }) `
        -literalArguments -workingDirectory $WorkingDirectory -maxRetries $MaxRetries `
        -retryOn (Get-GitHubTransientRetryPatterns) -retryDelayIncremental 5 -returnOutput
    if (-not $result.success) {
        $detail = if ($result.ContainsKey('error')) { $result.error } else { 'command failed' }
        throw [System.InvalidOperationException]::new("Git operation failed: $detail")
    }
    return $result.output
}

# Terraform colourises its diagnostics even when stdout and stderr are
# redirected to files, and it splits the escape codes around the `Error: `
# prefix, so a raw match on "Error: Failed to install provider" never fires.
function Remove-AnsiEscapeCode {
    param([string[]]$text)

    if (!$text) {
        return @()
    }

    return @($text | ForEach-Object { [regex]::Replace([string]$_, "\x1B\[[0-9;?]*[ -/]*[@-~]", "") })
}

# Terraform boxes its diagnostics behind a `│` gutter and hard-wraps the detail
# at roughly 78 columns, so a pattern that spans a wrap never matches a single
# line. Flattening to one whitespace-normalised string makes those matchable.
function ConvertTo-FlatErrorText {
    param([string[]]$text)

    if (!$text) {
        return ""
    }

    return (((($text -join " ") -replace "[\u2500-\u257F]", " ") -replace "\s+", " ")).Trim()
}

# Returns the text that matched the pattern, or $null when it does not match.
# Prefers the offending line so the retry message stays useful, and falls back
# to the flattened output for patterns that span a wrap.
function Get-ErrorOutputMatch {
    param(
        [string[]]$errorOutput,
        [string]$flattenedError,
        [string]$pattern
    )

    foreach ($line in $errorOutput) {
        if ($line -like "*$pattern*") {
            return $line
        }
    }

    if ($flattenedError -like "*$pattern*") {
        return $pattern
    }

    return $null
}

function Invoke-CommandWithRetry {
    param(
        $parentCommand,
        [hashtable[]]$commands,
        [string]$outputLog = "output.log",
        [string]$errorLog = "error.log",
        [int]$maxRetries = 10,
        [int]$retryDelayIncremental = 10,
        [string[]]$retryOn = @("API rate limit exceeded"),
        [hashtable[]]$recoveryActions = @(),
        [switch]$printOutput,
        [switch]$printOutputOnError,
        [switch]$returnOutput,
        [switch]$returnOutputParsedFromJson,
        [switch]$literalArguments,
        [string]$workingDirectory
    )

    $retryCount = 0
    $shouldRetry = $true

    $returnOutputs = @()

    while ($shouldRetry -and $retryCount -le $maxRetries) {
        $shouldRetry = $false

        foreach ($command in $commands) {
            $arguments = $command.Arguments

            $localLogPath = $outputLog
            if ($command.ContainsKey("OutputLog") -and $command.OutputLog) {
                $localLogPath = $command.OutputLog
            }

            Write-Host "Running $parentCommand with arguments: $($arguments -join ' ')"
            if ($literalArguments) {
                $process = Invoke-RepositorySyncProcess -Command $parentCommand -Arguments $arguments -WorkingDirectory $workingDirectory
                $standardOutput = [string]$process.StdOut
                $standardError = [string]$process.StdErr
            } else {
                $process = Start-Process `
                    -FilePath $parentCommand `
                    -ArgumentList $arguments `
                    -RedirectStandardOutput $localLogPath `
                    -RedirectStandardError $errorLog `
                    -PassThru `
                    -NoNewWindow `
                    -Wait
                $standardOutput = [string](Get-Content -Path $localLogPath -Raw)
                $standardError = [string](Get-Content -Path $errorLog -Raw)
            }

            if ($process.ExitCode -ne 0) {
                Write-Host "$parentCommand failed with exit code $($process.ExitCode)."

                $errorOutput = @(Remove-AnsiEscapeCode -text @($standardError -split '\r?\n'))
                $flattenedError = ConvertTo-FlatErrorText -text $errorOutput

                if ($retryOn -contains "*") {
                    $shouldRetry = $true
                } else {
                    foreach ($retryError in $retryOn) {
                        $matchedText = Get-ErrorOutputMatch -errorOutput $errorOutput -flattenedError $flattenedError -pattern $retryError
                        if ($matchedText) {
                            Write-Host "Retrying $parentCommand due to error: $matchedText"
                            $shouldRetry = $true
                            break
                        }
                    }
                }

                # Recovery actions handle failures that will never clear on
                # their own, such as a stale Terraform state lock. Retry only
                # when the action reports that it actually fixed the problem.
                if (!$shouldRetry) {
                    foreach ($recovery in $recoveryActions) {
                        $matchedPattern = $false
                        foreach ($pattern in @($recovery.Pattern)) {
                            if (Get-ErrorOutputMatch -errorOutput $errorOutput -flattenedError $flattenedError -pattern $pattern) {
                                $matchedPattern = $true
                                break
                            }
                        }
                        if (!$matchedPattern) {
                            continue
                        }

                        $maxRecoveryAttempts = 1
                        if ($recovery.ContainsKey("MaxAttempts") -and $recovery.MaxAttempts) {
                            $maxRecoveryAttempts = $recovery.MaxAttempts
                        }

                        $recoveryAttempts = 0
                        if ($recovery.ContainsKey("Attempts")) {
                            $recoveryAttempts = [int]$recovery.Attempts
                        }
                        if ($recoveryAttempts -ge $maxRecoveryAttempts) {
                            Write-Host "Recovery for '$($recovery.Name)' already attempted $recoveryAttempts time(s). Not retrying."
                            continue
                        }

                        $recovery.Attempts = $recoveryAttempts + 1
                        Write-Host "Attempting recovery for '$($recovery.Name)' (attempt $($recovery.Attempts) of $maxRecoveryAttempts)."

                        $recovered = $false
                        try {
                            $recovered = [bool](& $recovery.Action $errorOutput $recovery.Context)
                        } catch {
                            Write-Warning "Recovery for '$($recovery.Name)' threw an error: $_"
                        }

                        if ($recovered) {
                            $shouldRetry = $true
                            break
                        }
                    }
                }

                if ($shouldRetry) {
                    Write-Host "Retrying $parentCommand due to error:"
                    Write-Host $standardError
                    $retryCount++
                    break
                } else {
                    Write-Host "$parentCommand failed with exit code $($process.ExitCode). Check the logs for details."
                    if ($printOutputOnError) {
                        Write-Host "Output Log:"
                        Write-Host $standardOutput
                    }
                    Write-Host "Error Log:"
                    Write-Host $standardError
                    $returnOutputs += @{
                        success  = $false
                        exitCode = $process.ExitCode
                        error    = ($errorOutput -join [System.Environment]::NewLine)
                    }
                    return $returnOutputs
                }
            } else {
                if ($printOutput) {
                    Write-Host "Output Log:"
                    Write-Host $standardOutput
                }
                if ($returnOutputParsedFromJson) {
                    if ($literalArguments) {
                        if ([string]::IsNullOrWhiteSpace($standardOutput)) {
                            throw [System.IO.InvalidDataException]::new('GitHub returned empty JSON.')
                        }
                        $parsedOutput = ConvertFrom-Json -InputObject $standardOutput -NoEnumerate -ErrorAction Stop
                        if ($null -eq $parsedOutput) {
                            throw [System.IO.InvalidDataException]::new('GitHub returned null JSON.')
                        }
                    } else {
                        $parsedOutput = $standardOutput | ConvertFrom-Json
                    }
                    $returnOutputs += @{
                        success = $true
                        output  = $parsedOutput
                    }
                } elseif ($returnOutput) {
                    $returnOutputs += @{
                        success = $true
                        output  = $standardOutput.TrimEnd()
                    }
                } else {
                    $returnOutputs += @{
                        success = $true
                    }
                }
            }
        }
        if ($shouldRetry) {
            if ($retryCount -gt $maxRetries) {
                Write-Host "Max retries reached. Exiting."
                $returnOutputs = @( @{
                        success = $false
                    })
                if ($literalArguments) {
                    $returnOutputs[0].exitCode = $process.ExitCode
                    $returnOutputs[0].error = $standardError
                }
                return $returnOutputs
            }
            Write-Host "Retrying $parentCommand commands (attempt $retryCount of $maxRetries)..."
            $retryDelay = $retryDelayIncremental * $retryCount
            Write-Host "Waiting for $retryDelay seconds before retrying..."
            Start-Sleep -Seconds $retryDelay
        }
    }

    return $returnOutputs
}
