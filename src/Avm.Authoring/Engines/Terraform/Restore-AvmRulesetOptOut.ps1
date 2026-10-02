function Restore-AvmRulesetOptOut {
    <#
    .SYNOPSIS
        Restore a global-rulesets-opt-out value that an interrupted avm init left changed.
    .DESCRIPTION
        Reads the record written before avm init set the property to true. The
        recorded value is restored only while the property is still true and
        repository sync does not manage the repository. A record for a deleted
        repository of the same name is discarded. The record is removed
        afterwards. Returns Status 'none' when no record exists, 'restored',
        'unchanged', 'stale', or 'planned'.
    .PARAMETER Repository
        Repository as owner/name.
    .PARAMETER RepositoryId
        The repository's GitHub ID.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Repository,

        [Parameter(Mandatory)]
        [long] $RepositoryId
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $path = Get-AvmRulesetOptOutRecordPath -Repository $Repository
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ Status = 'none'; Value = $null }
    }
    $record = $null
    try {
        $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    }
    catch {
        Write-AvmLog ('init: ruleset opt-out record is not JSON: {0}' -f $_.Exception.Message) -Level Verbose | Out-Null
    }
    if ($record -isnot [System.Collections.IDictionary] -or [string]$record['repository'] -cne $Repository -or
        $record['repositoryId'] -isnot [long] -or -not $record.Contains('value') -or
        ($null -ne $record['value'] -and ($record['value'] -isnot [string] -or $record['value'] -cnotin @('true', 'false')))) {
        throw [System.IO.InvalidDataException]::new(
            "The ruleset opt-out record '$path' is invalid. Check global-rulesets-opt-out on $Repository, then delete the record.")
    }

    $value = $record['value']
    $status = if ($record['repositoryId'] -ne $RepositoryId) {
        'stale'
    }
    elseif ((Get-AvmRepositoryRulesetOptOut -Repository $Repository) -cne 'true' -or
        (Test-AvmRepositorySyncManaged -Repository $Repository)) {
        'unchanged'
    }
    else {
        'restored'
    }
    $description = if ($null -eq $value) { 'unset' } else { $value }
    $action = if ($status -eq 'restored') { "Restore global-rulesets-opt-out to $description" } else { 'Remove the ruleset opt-out record' }
    if (-not $PSCmdlet.ShouldProcess($Repository, $action)) {
        return [pscustomobject]@{ Status = 'planned'; Value = $value }
    }
    if ($status -eq 'restored') {
        Set-AvmRepositoryRulesetOptOut -Repository $Repository -Value $value -Confirm:$false
    }
    Remove-Item -LiteralPath $path -Force
    return [pscustomobject]@{ Status = $status; Value = $value }
}
