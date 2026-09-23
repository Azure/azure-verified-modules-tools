Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/AvmPreCommit.ps1")

function Assert-Throws {
    param(
        [scriptblock]$Action,
        [string]$MessagePattern,
        [string]$ExpectedMessage,
        [string]$MessageNotPattern
    )

    try {
        & $Action
    } catch {
        $message = $_.Exception.Message
        if ($ExpectedMessage -and $message -cne $ExpectedMessage) {
            throw "Expected error '$ExpectedMessage', got '$message'."
        }
        if ($MessagePattern -and $message -notlike $MessagePattern) {
            throw "Expected error matching '$MessagePattern', got '$message'."
        }
        if ($MessageNotPattern -and $message -like $MessageNotPattern) {
            throw "Expected error not matching '$MessageNotPattern', got '$message'."
        }
        return
    }

    throw "Expected an error matching '$MessagePattern'."
}

function Assert-Equal {
    param(
        [object]$Actual,
        [object]$Expected,
        [string]$Description
    )

    if ($Actual -ne $Expected) {
        throw "Expected $Description to be '$Expected', got '$Actual'."
    }
}

Assert-AvmPreCommitResult -preCommitResult ([pscustomobject]@{
    Status = "pass"
    Steps = @()
})

Assert-Throws `
    -ExpectedMessage "avm pre-commit returned status 'fail'. Failed steps: transform: fail - Mapotf failed.." `
    -MessageNotPattern "*Issues:*" `
    -Action {
    Assert-AvmPreCommitResult -preCommitResult ([pscustomobject]@{
        Status = "fail"
        Steps = @(
            [pscustomobject]@{
                Step = "transform"
                Status = "fail"
                Error = "Mapotf failed."
            }
        )
    })
}

Assert-Throws `
    -MessagePattern "avm pre-commit returned status 'fail'.*check convention: fail - Issues: Required file '_header.md' does not exist. | Required directory 'tests' must contain at least 1 immediate child item; found 0.*" `
    -Action {
    Assert-AvmPreCommitResult -preCommitResult ([pscustomobject]@{
        Status = "fail"
        Steps = @(
            [pscustomobject]@{
                Step = "check convention"
                Status = "fail"
                Error = $null
                Result = [pscustomobject]@{
                    Issues = @(
                        [pscustomobject]@{
                            Message = "Required file '_header.md' does not exist."
                        }
                        [pscustomobject]@{
                            Message = "Required directory 'tests' must contain at least 1 immediate child item; found 0."
                        }
                    )
                }
            }
        )
    })
}

Assert-Throws -MessagePattern "avm pre-commit returned status 'missing'.*" -Action {
    Assert-AvmPreCommitResult -preCommitResult $null
}

$metadataTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "avm-metadata-conflict-test-$([guid]::NewGuid().ToString('n'))"
try {
    $null = New-Item -ItemType Directory -Path $metadataTestRoot -Force
    $metadataPath = Join-Path $metadataTestRoot ".avm"
    Set-Content -LiteralPath $metadataPath -Value "legacy metadata" -NoNewline

    $removed = Remove-AvmMetadataFileConflict `
        -repoRoot $metadataTestRoot `
        -orgAndRepoName "Azure/test-repo" `
        -modeTag "[PLAN]"
    Assert-Equal -Actual $removed -Expected $true -Description "legacy .avm file removal"
    Assert-Equal -Actual (Test-Path -LiteralPath $metadataPath) -Expected $false -Description "legacy .avm file existence"

    $null = New-Item -ItemType Directory -Path $metadataPath
    $removed = Remove-AvmMetadataFileConflict `
        -repoRoot $metadataTestRoot `
        -orgAndRepoName "Azure/test-repo" `
        -modeTag "[PLAN]"
    Assert-Equal -Actual $removed -Expected $false -Description ".avm directory removal"
    Assert-Equal -Actual (Test-Path -LiteralPath $metadataPath -PathType Container) -Expected $true -Description ".avm directory existence"
} finally {
    Remove-Item -LiteralPath $metadataTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$script:moduleImportCount = 0
$script:moduleUpdateCount = 0
$script:preCommitInvocationCount = 0
$script:preCommitErrorCodes = @()
$script:moduleUpdateParameters = @{}

function Import-Module {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Name,
        [switch]$Force
    )

    $script:moduleImportCount++
}

function Update-PSResource {
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$Scope,
        [switch]$TrustRepository
    )

    $script:moduleUpdateCount++
    $script:moduleUpdateParameters = @{} + $PSBoundParameters
}

$script:preCommitParameters = @{}

function Invoke-AvmPreCommit {
    param(
        [string]$Ecosystem,
        [string]$RepoId,
        [string]$ConfigLocalPath,
        [switch]$Upgrade
    )

    $script:preCommitInvocationCount++
    $script:preCommitParameters = @{} + $PSBoundParameters
    if ($script:preCommitInvocationCount -le $script:preCommitErrorCodes.Count) {
        $exception = [System.InvalidOperationException]::new("A newer version of Avm.Authoring is required.")
        $exception | Add-Member -NotePropertyName Code -NotePropertyValue $script:preCommitErrorCodes[$script:preCommitInvocationCount - 1]
        throw $exception
    }

    return [pscustomobject]@{
        Status = "pass"
        Steps = @()
    }
}

$script:retryParameters = @{
    repoId              = "avm-res-test"
    repositoryConfigDir = "../repository-config"
}

try {
    $script:preCommitErrorCodes = @("AVM1050")
    $result = Invoke-AvmPreCommitWithUpgradeRetry @script:retryParameters

    Assert-Equal -Actual $result.Status -Expected "pass" -Description "pre-commit status after upgrade"
    Assert-Equal -Actual $script:preCommitParameters.Ecosystem -Expected "terraform" -Description "forwarded ecosystem"
    Assert-Equal -Actual $script:preCommitParameters.RepoId -Expected $script:retryParameters.repoId -Description "forwarded repo id"
    Assert-Equal -Actual $script:preCommitParameters.ContainsKey("ManagedFilesLocalPath") -Expected $false -Description "managed files local path not forwarded"
    Assert-Equal -Actual $script:preCommitParameters.ContainsKey("Upgrade") -Expected $false -Description "upgrade switch not forwarded by default"
    Assert-Equal -Actual $script:preCommitParameters.ConfigLocalPath -Expected $script:retryParameters.repositoryConfigDir -Description "forwarded repository config path"
    Assert-Equal -Actual $script:preCommitInvocationCount -Expected 2 -Description "pre-commit invocation count"
    Assert-Equal -Actual $script:moduleImportCount -Expected 2 -Description "module import count"
    Assert-Equal -Actual $script:moduleUpdateCount -Expected 1 -Description "module update count"
    Assert-Equal -Actual $script:moduleUpdateParameters.Name -Expected "Avm.Authoring" -Description "updated module name"
    Assert-Equal -Actual $script:moduleUpdateParameters.Scope -Expected "CurrentUser" -Description "module update scope"
    Assert-Equal -Actual $script:moduleUpdateParameters.TrustRepository.IsPresent -Expected $true -Description "trusted repository switch"

    $script:moduleImportCount = 0
    $script:moduleUpdateCount = 0
    $script:preCommitInvocationCount = 0
    $script:preCommitErrorCodes = @("AVM9999")

    Assert-Throws `
        -ExpectedMessage "A newer version of Avm.Authoring is required." `
        -Action {
        Invoke-AvmPreCommitWithUpgradeRetry @script:retryParameters
    }

    Assert-Equal -Actual $script:preCommitInvocationCount -Expected 1 -Description "unrelated error invocation count"
    Assert-Equal -Actual $script:moduleImportCount -Expected 1 -Description "unrelated error import count"
    Assert-Equal -Actual $script:moduleUpdateCount -Expected 0 -Description "unrelated error update count"

    $script:moduleImportCount = 0
    $script:moduleUpdateCount = 0
    $script:preCommitInvocationCount = 0
    $script:preCommitErrorCodes = @("AVM1050", "AVM1050")

    Assert-Throws `
        -ExpectedMessage "A newer version of Avm.Authoring is required." `
        -Action {
        Invoke-AvmPreCommitWithUpgradeRetry @script:retryParameters
    }

    Assert-Equal -Actual $script:preCommitInvocationCount -Expected 2 -Description "retry failure invocation count"
    Assert-Equal -Actual $script:moduleImportCount -Expected 2 -Description "retry failure import count"
    Assert-Equal -Actual $script:moduleUpdateCount -Expected 1 -Description "retry failure update count"

    $script:moduleImportCount = 0
    $script:moduleUpdateCount = 0
    $script:preCommitInvocationCount = 0
    $script:preCommitErrorCodes = @()

    $null = Invoke-AvmPreCommitWithUpgradeRetry @script:retryParameters -upgradeManagedFiles $true

    Assert-Equal -Actual $script:preCommitParameters.ContainsKey("Upgrade") -Expected $true -Description "upgrade switch forwarded when requested"
    Assert-Equal -Actual $script:preCommitParameters.Upgrade -Expected $true -Description "forwarded upgrade switch value"
} finally {
    Remove-Item Function:Import-Module
    Remove-Item Function:Update-PSResource
    Remove-Item Function:Invoke-AvmPreCommit
}

Write-Host "Avm pre-commit result tests passed."
