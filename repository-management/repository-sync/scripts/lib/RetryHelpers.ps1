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

function Invoke-RepositorySyncLockRead {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('az')] [string] $Command,
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
        '--query', '{etag:properties.etag,leaseState:properties.lease.state,leaseStatus:properties.lease.status}'
    )
    if ($snapshot['etag'] -isnot [string] -or $snapshot['etag'] -cnotmatch '^(?:"0x[0-9a-fA-F]+"|0x[0-9a-fA-F]+)$' -or
        $snapshot['leaseState'] -cnotin @('available', 'leased', 'expired', 'breaking', 'broken') -or
        $snapshot['leaseStatus'] -cnotin @('locked', 'unlocked')) {
        throw [System.IO.InvalidDataException]::new('The selected state blob has incomplete lease metadata.')
    }
    return @{
        ETag = $snapshot['etag']
        State = $snapshot['leaseState']
        Status = $snapshot['leaseStatus']
    }
}

function Clear-TerraformStateLock {
    [CmdletBinding(SupportsShouldProcess)]
    param(
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
    if (-not $PSCmdlet.ShouldProcess("$storageAccountName/$containerName/$blobName", 'Inspect the selected state blob and clear a held lease once')) {
        return $false
    }
    $tools = 'Azure/azure-verified-modules-tools'
    $workflow = '.github/workflows/repository-management-sync.yml'
    if ($env:GITHUB_ACTIONS -cne 'true' -or $env:GITHUB_REPOSITORY -cne $tools -or
        $env:GITHUB_REF -cnotmatch '\Arefs/heads/.+\z' -or
        $env:GITHUB_WORKFLOW_REF -cne "$tools/$workflow@$env:GITHUB_REF" -or $env:REPO_ID -cne $repoId) {
        throw [System.InvalidOperationException]::new('State-lock preflight requires the serialized Terraform Sync job for the selected repository on a Tools branch.')
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
    $account = Invoke-RepositorySyncLockRead -Command az -Environment $environment -Arguments @(
        'account', 'show', '--subscription', $backend.SubscriptionId, '--output', 'json', '--only-show-errors',
        '--query', '{id:id,tenantId:tenantId,user:user}'
    )
    if ($account['id'] -ine $backend.SubscriptionId -or $account['tenantId'] -ine $backend.TenantId -or
        $account['user'] -isnot [System.Collections.IDictionary] -or $account['user']['type'] -cne 'servicePrincipal' -or
        $account['user']['name'] -ine $backend.ClientId) {
        throw [System.InvalidOperationException]::new('Azure CLI must be authenticated as the selected state backend identity, not the provider or a user.')
    }
    $exists = Invoke-RepositorySyncLockRead -Command az -Environment $environment -Arguments @(
        'storage', 'blob', 'exists', '--account-name', $backend.StorageAccountName,
        '--container-name', $backend.ContainerName, '--name', $blobName,
        '--auth-mode', 'login', '--subscription', $backend.SubscriptionId, '--only-show-errors', '--output', 'json'
    )
    if ($exists['exists'] -isnot [bool]) {
        throw [System.IO.InvalidDataException]::new('The selected state blob existence check did not return a boolean.')
    }
    if (-not $exists['exists']) {
        Write-Information "The selected state blob '$blobName' has not been created; no lease needs clearing." -InformationAction Continue
        return $true
    }
    $observed = Get-RepositorySyncStateBlobLock -Backend $backend -BlobName $blobName -Environment $environment
    if ($observed.Status -ceq 'unlocked' -and $observed.State -cin @('available', 'expired', 'broken')) {
        Write-Information "The selected state blob '$blobName' is unlocked." -InformationAction Continue
        return $true
    }
    if ($observed.State -cnotin @('leased', 'breaking') -or $observed.Status -cne 'locked') {
        throw [System.InvalidOperationException]::new('The selected state lease has inconsistent properties; it will not be changed automatically.')
    }
    Write-Warning "Clearing the held lease on '$storageAccountName/$containerName/$blobName' before Terraform."
    $null = Clear-TerraformStateBlobLease -Backend $backend -BlobName $blobName -ETag $observed.ETag `
        -Environment $environment -Confirm:$false
    $released = Get-RepositorySyncStateBlobLock -Backend $backend -BlobName $blobName -Environment $environment
    if ($released.Status -cne 'unlocked' -or $released.State -cnotin @('available', 'expired', 'broken')) {
        throw [System.InvalidOperationException]::new('The selected state lease is still held after release; Terraform will not be started.')
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

    if (-not $PSCmdlet.ShouldProcess("$($Backend.StorageAccountName)/$($Backend.ContainerName)/$BlobName", 'Break the selected state lease once')) {
        return $false
    }
    $result = Invoke-RepositorySyncProcess -Command az -EnvVars $Environment -TimeoutSec 60 -Arguments @(
        'storage', 'blob', 'lease', 'break', '--account-name', $Backend.StorageAccountName,
        '--container-name', $Backend.ContainerName, '--blob-name', $BlobName, '--lease-break-period', '0',
        '--if-match', $ETag, '--auth-mode', 'login', '--subscription', $Backend.SubscriptionId, '--only-show-errors', '--output', 'none'
    )
    if ($result.ExitCode -ne 0) {
        $detail = Protect-RepositorySyncLogText -Text $result.StdErr -Environment $Environment
        throw [System.InvalidOperationException]::new("The conditional state lease break failed (exit $($result.ExitCode)); Terraform will not be started. $detail")
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
