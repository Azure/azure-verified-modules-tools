function Test-AvmReleaseRecord {
    <#
    .SYNOPSIS
        Find damage in a release record document.

    .DESCRIPTION
        Checks a parsed releases/vX.Y.Z.json document against avm-release-record.schema.json with Test-AvmReleaseDocument, then against the rules that keep it consistent. A release record is written once at the publication cutoff and never changes afterwards. Damage includes a missing or unsupported schema version, anything the JSON Schema rejects, a version equal to the previous version, a pull request listed twice, and a release-triggering pull request without a version label.

    .PARAMETER Record
        The parsed release record.

    .EXAMPLE
        Test-AvmReleaseRecord -Record $record

        Returns no issues for a valid record.

    .OUTPUTS
        String. One message for each problem found.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $Record
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $policy = Get-AvmReleasePolicy
    $issues = [System.Collections.Generic.List[string]]::new()

    if ($Record -isnot [System.Collections.IDictionary]) {
        return '$: release record must be a JSON object.'
    }
    if (@($Record.Keys) -cnotcontains 'schemaVersion') {
        return '$.schemaVersion: is missing.'
    }
    $schemaVersion = $Record['schemaVersion']
    if ($schemaVersion -isnot [int] -and $schemaVersion -isnot [long]) {
        return '$.schemaVersion: must be a positive integer.'
    }
    if ($schemaVersion -ne $policy.SchemaVersion) {
        return "`$.schemaVersion: version '$schemaVersion' is not supported. Expected $($policy.SchemaVersion)."
    }

    $issues.AddRange([string[]]@(Test-AvmReleaseDocument -Document $Record -Kind Record))
    if ($issues.Count -gt 0) {
        return $issues.ToArray()
    }

    if ($Record['version'] -eq $Record['previousVersion']) {
        $issues.Add('$.version: the new version must differ from the previous version.')
    }

    $numbers = [System.Collections.Generic.HashSet[long]]::new()
    $entries = @($Record['pullRequests'])
    if ($entries.Count -eq 0) {
        $issues.Add('$.pullRequests: a release must include at least one pull request.')
    }
    for ($index = 0; $index -lt $entries.Count; $index++) {
        $entry = $entries[$index]
        if (-not $numbers.Add([long]$entry['number'])) {
            $issues.Add("`$.pullRequests[$index].number: pull request #$($entry['number']) is listed more than once.")
        }
        if ($entry['triggersRelease'] -and $null -eq $entry['versionLabel']) {
            $issues.Add("`$.pullRequests[$index].versionLabel: a release-triggering pull request needs its accepted version label.")
        }
    }

    return $issues.ToArray()
}
