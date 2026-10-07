# Logging helpers used by the repository sync pipeline.

. (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring' 'Private' 'Output' 'Write-AvmLog.ps1')

function Invoke-RepositorySyncLogGroup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [scriptblock] $Action
    )

    Enter-AvmLogGroup -Name $Name
    try {
        & $Action
    }
    finally {
        Exit-AvmLogGroup
    }
}

function Protect-RepositorySyncLogText {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()] [string] $Text)

    $credentials = [Environment]::GetEnvironmentVariables().GetEnumerator() |
        Where-Object { $_.Key -match '^(GH_TOKEN|GITHUB_TOKEN|ACTIONS_.*TOKEN|ARM_.*(SECRET|PASSWORD|TOKEN|KEY)|TF_TOKEN_.*)$' } |
        Sort-Object { ([string]$_.Value).Length } -Descending
    foreach ($credential in $credentials) {
        $value = [string]$credential.Value
        if (-not [string]::IsNullOrEmpty($value)) {
            $Text = $Text.Replace($value, '***', [StringComparison]::Ordinal)
        }
    }
    return $Text
}

function Add-IssueToLog {
    param(
        [string]$orgAndRepoName,
        [string]$type,
        [string]$message,
        [object]$data,
        [array]$issueLog,
        [ValidateSet("warning", "error")]
        [string]$severity = "error",
        [string]$issueLogFile = "issue.log"
    )

    $issueLogItem = @{
        orgAndRepoName = $orgAndRepoName
        type           = $type
        severity       = $severity
        message        = $message
        data           = $data
    }

    $issueLog += $issueLogItem

    $issueLogItemJson = ConvertTo-Json $issueLogItem -Depth 100
    Add-Content -Path $issueLogFile -Value $issueLogItemJson

    return $issueLog
}
