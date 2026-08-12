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
        [switch]$printOutput,
        [switch]$printOutputOnError,
        [switch]$returnOutputParsedFromJson
    )

    foreach ($command in $commands) {
        $command.Arguments = @("-chdir=$workingDirectory") + $command.Arguments
    }

    # The repository sync is the only writer of each repo's state and runs on a
    # 4 hourly schedule, so any lock we hit is left over from a cancelled or
    # crashed run rather than a concurrent one. Break it and retry.
    # State is passed through Context rather than a closure: GetNewClosure()
    # rebinds the script block to a dynamic module, which cannot resolve the
    # helper functions this file dot-sources into the caller's script scope.
    $recoveryActions = @(
        @{
            Name        = "terraform state lock"
            Pattern     = @("Error acquiring the state lock", "Error releasing the state lock")
            MaxAttempts = 3
            Context     = @{
                workingDirectory   = $workingDirectory
                storageAccountName = $stateStorageAccountName
                containerName      = $stateContainerName
                blobName           = $stateBlobName
            }
            Action      = {
                param([string[]]$errorOutput, [hashtable]$context)
                Clear-TerraformStateLock `
                    -errorOutput $errorOutput `
                    -workingDirectory $context.workingDirectory `
                    -storageAccountName $context.storageAccountName `
                    -containerName $context.containerName `
                    -blobName $context.blobName
            }
        }
    )

    return Invoke-CommandWithRetry `
        -parentCommand "terraform" `
        -commands $commands `
        -outputLog $outputLog `
        -errorLog $errorLog `
        -maxRetries $maxRetries `
        -retryDelayIncremental $retryDelayIncremental `
        -retryOn $retryOn `
        -recoveryActions $recoveryActions `
        -printOutput:$printOutput.IsPresent `
        -printOutputOnError:$printOutputOnError.IsPresent `
        -returnOutputParsedFromJson:$returnOutputParsedFromJson.IsPresent
}

# Clears the state lock left behind by a cancelled or crashed run. Prefers
# `terraform force-unlock`, which clears the lock metadata as well as the blob
# lease, and falls back to breaking the lease directly. The fallback matters
# because a killed run often leaves the lease held with an empty
# "terraformlockid" metadata value: there is then no ID for force-unlock to
# match, and breaking the lease is the only way to release the blob. Returns
# $true only when the lock was actually released, so the caller can fall
# through to the normal failure path when it cannot be broken.
function Clear-TerraformStateLock {
    param(
        [string[]]$errorOutput,
        [string]$workingDirectory,
        [string]$storageAccountName,
        [string]$containerName,
        [string]$blobName,
        [string]$outputLog = "force-unlock.log",
        [string]$errorLog = "force-unlock.error.log"
    )

    # Terraform colourises and box-draws this output, so match the GUID rather
    # than anchoring on the surrounding characters.
    $lockIdPattern = 'ID:\s*([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'

    $lockId = $null
    foreach ($line in $errorOutput) {
        $lockIdMatch = [regex]::Match($line, $lockIdPattern)
        if ($lockIdMatch.Success) {
            $lockId = $lockIdMatch.Groups[1].Value
            break
        }
    }

    if ($lockId) {
        Write-Host "Found stale Terraform state lock '$lockId'. Forcing unlock."

        $process = Start-Process `
            -FilePath "terraform" `
            -ArgumentList @("-chdir=$workingDirectory", "force-unlock", "-force", $lockId) `
            -RedirectStandardOutput $outputLog `
            -RedirectStandardError $errorLog `
            -PassThru `
            -NoNewWindow `
            -Wait

        if ($process.ExitCode -eq 0) {
            Write-Host "Released Terraform state lock '$lockId'."
            return $true
        }

        Write-Warning "terraform force-unlock failed with exit code $($process.ExitCode). Falling back to breaking the state blob lease."
        Get-Content -Path $errorLog | Write-Host
    }
    else {
        Write-Host "No Terraform state lock ID in the error output. Falling back to breaking the state blob lease."
    }

    return Clear-TerraformStateBlobLease `
        -storageAccountName $storageAccountName `
        -containerName $containerName `
        -blobName $blobName
}

# Breaks the Azure Storage blob lease that backs a Terraform state lock. Used
# when `terraform force-unlock` cannot help, either because the lock metadata
# is empty or because the lease no longer matches the one Terraform holds.
function Clear-TerraformStateBlobLease {
    param(
        [string]$storageAccountName,
        [string]$containerName,
        [string]$blobName,
        [string]$outputLog = "lease-break.log",
        [string]$errorLog = "lease-break.error.log"
    )

    if (!$storageAccountName -or !$containerName -or !$blobName) {
        Write-Warning "No state blob details were supplied, so the state lock cannot be broken. Leaving the lock in place."
        return $false
    }

    Write-Host "Breaking the lease on state blob '$blobName' in '$storageAccountName/$containerName'."

    $process = Start-Process `
        -FilePath "az" `
        -ArgumentList @(
            "storage", "blob", "lease", "break",
            "--account-name", $storageAccountName,
            "--container-name", $containerName,
            "--blob-name", $blobName,
            "--lease-break-period", "0",
            "--auth-mode", "login"
        ) `
        -RedirectStandardOutput $outputLog `
        -RedirectStandardError $errorLog `
        -PassThru `
        -NoNewWindow `
        -Wait

    if ($process.ExitCode -ne 0) {
        Write-Warning "Breaking the lease on state blob '$blobName' failed with exit code $($process.ExitCode)."
        Get-Content -Path $errorLog | Write-Host
        return $false
    }

    Write-Host "Broke the lease on state blob '$blobName'."
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
        [switch]$returnOutputParsedFromJson
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
        -returnOutputParsedFromJson:$returnOutputParsedFromJson.IsPresent
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
        [switch]$returnOutputParsedFromJson
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
            $process = Start-Process `
                -FilePath $parentCommand `
                -ArgumentList $arguments `
                -RedirectStandardOutput $localLogPath `
                -RedirectStandardError $errorLog `
                -PassThru `
                -NoNewWindow `
                -Wait

            if ($process.ExitCode -ne 0) {
                Write-Host "$parentCommand failed with exit code $($process.ExitCode)."

                $errorOutput = @(Remove-AnsiEscapeCode -text @(Get-Content -Path $errorLog))
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
                    Get-Content -Path $errorLog | Write-Host
                    $retryCount++
                    break
                } else {
                    Write-Host "$parentCommand failed with exit code $($process.ExitCode). Check the logs for details."
                    if ($printOutputOnError) {
                        Write-Host "Output Log:"
                        Get-Content -Path $localLogPath | Write-Host
                    }
                    Write-Host "Error Log:"
                    Get-Content -Path $errorLog | Write-Host
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
                    Get-Content -Path $localLogPath | Write-Host
                }
                if ($returnOutputParsedFromJson) {
                    $outputContent = Get-Content -Path $localLogPath -Raw
                    $parsedOutput = $outputContent | ConvertFrom-Json
                    $returnOutputs += @{
                        success = $true
                        output  = $parsedOutput
                    }
                } elseif ($returnOutput) {
                    $returnOutputs += @{
                        success = $true
                        output  = (Get-Content -Path $localLogPath -Raw).TrimEnd()
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
