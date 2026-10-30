function Test-AvmReleaseState {
    <#
    .SYNOPSIS
        Find damage in a release state document.

    .DESCRIPTION
        Checks a parsed state.json document against schema version 1 and the rules that keep it consistent. Damage includes:

        - A missing or unsupported schema version.
        - Missing, unknown, or wrongly typed properties.
        - Malformed timestamps, versions, labels, or commit SHAs.
        - A pull request listed twice, or listed as both pending and publishing.
        - A pull request whose trigger fields contradict its kind.
        - A hold that started after its latest update.
        - A repository other than the expected one.

        Damaged state must stop publication. The caller never repairs it silently.

    .PARAMETER State
        The parsed state document.

    .PARAMETER Repository
        The expected repository as 'owner/name'. When set, the state must name the same repository.

    .EXAMPLE
        Test-AvmReleaseState -State (New-AvmReleaseState -Repository 'Azure/terraform-azurerm-avm-res-example')

        Returns no issues.

    .OUTPUTS
        String. One message for each problem found.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $State,

        [string] $Repository
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $policy = Get-AvmReleasePolicy
    $issues = [System.Collections.Generic.List[string]]::new()

    if ($State -isnot [System.Collections.IDictionary]) {
        return '$: release state must be a JSON object.'
    }
    if (@($State.Keys) -cnotcontains 'schemaVersion') {
        return '$.schemaVersion: is missing.'
    }
    $schemaVersion = $State['schemaVersion']
    if ($schemaVersion -isnot [int] -and $schemaVersion -isnot [long]) {
        return '$.schemaVersion: must be a positive integer.'
    }
    if ($schemaVersion -ne $policy.SchemaVersion) {
        return "`$.schemaVersion: version '$schemaVersion' is not supported. Expected $($policy.SchemaVersion)."
    }

    Test-AvmReleaseShape -Value $State -Schema (Get-AvmReleaseSchema -Kind State) -Path '$' -Issues $issues
    if ($issues.Count -gt 0) {
        return $issues.ToArray()
    }

    if (-not [string]::IsNullOrWhiteSpace($Repository) -and $State['repository'] -ne $Repository) {
        $issues.Add("`$.repository: state belongs to '$($State['repository'])', not '$Repository'.")
    }

    $pendingNumbers = [System.Collections.Generic.HashSet[long]]::new()
    $pullRequests = @($State['pending']['pullRequests'])
    for ($index = 0; $index -lt $pullRequests.Count; $index++) {
        $pr = $pullRequests[$index]
        $path = "`$.pending.pullRequests[$index]"
        if (-not $pendingNumbers.Add([long]$pr['number'])) {
            $issues.Add("${path}.number: pull request #$($pr['number']) is listed more than once.")
        }
        if ($pr['triggersRelease']) {
            if ($null -eq $pr['triggeredAt'] -or $null -eq $pr['triggeredBy']) {
                $issues.Add("${path}: a release-triggering pull request needs triggeredAt and triggeredBy.")
            }
        }
        elseif ($null -ne $pr['triggeredAt'] -or $null -ne $pr['triggeredBy'] -or $null -ne $pr['optIn']) {
            $issues.Add("${path}: a pull request that does not trigger a release cannot have trigger details.")
        }
        if ($pr['triggeredBy'] -eq 'opt-in' -and $null -eq $pr['optIn']) {
            $issues.Add("${path}.optIn: an opt-in trigger needs the opt-in details.")
        }
        if ($pr['triggeredBy'] -eq 'merge' -and $null -ne $pr['optIn']) {
            $issues.Add("${path}.optIn: a merge trigger cannot have opt-in details.")
        }
        if ($pr['kind'] -eq 'Human' -and ($pr['triggersRelease'] -ne $true -or $pr['triggeredBy'] -ne 'merge')) {
            $issues.Add("${path}: a human-authored pull request must trigger a release at merge.")
        }
        if ($pr['kind'] -eq 'Automation' -and $pr['triggeredBy'] -eq 'merge') {
            $issues.Add("${path}: a repo-sync pull request can trigger a release only through an opt-in.")
        }
        if ($pr['formattingOnly'] -and -not $pr['moduleCodeChanged']) {
            $issues.Add("${path}.formattingOnly: a formatting-only change must change module code.")
        }
        if ($null -ne $pr['triggeredAt'] -and $pr['triggeredAt'] -lt $pr['mergedAt']) {
            $issues.Add("${path}.triggeredAt: a pull request cannot trigger a release before it merges.")
        }
    }

    $hold = $State['hold']
    if ($null -ne $hold -and $hold['since'] -gt $hold['placedAt']) {
        $issues.Add('$.hold.since: the hold cannot start after its latest update.')
    }

    $publication = $State['publication']
    if ($null -ne $publication) {
        $publishing = [System.Collections.Generic.HashSet[long]]::new()
        $entries = @($publication['pullRequests'])
        for ($index = 0; $index -lt $entries.Count; $index++) {
            $number = [long]$entries[$index]['number']
            if (-not $publishing.Add($number)) {
                $issues.Add("`$.publication.pullRequests[$index].number: pull request #$number is listed more than once.")
            }
            if ($pendingNumbers.Contains($number)) {
                $issues.Add("`$.publication.pullRequests[$index].number: pull request #$number is both pending and publishing.")
            }
        }
        if ($publication['version'] -eq $publication['previousVersion']) {
            $issues.Add('$.publication.version: the new version must differ from the previous version.')
        }
    }

    return $issues.ToArray()
}
