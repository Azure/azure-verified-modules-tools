function ConvertFrom-AvmBicepPolicyResult {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Records,

        [Parameter(Mandatory)]
        $Baseline,

        [Parameter(Mandatory)]
        [string] $StagePath,

        [Parameter(Mandatory)]
        [string] $SourcePath,

        [Parameter(Mandatory)]
        [string] $ModuleRoot
    )

    Set-StrictMode -Version 3.0
    $issues = [System.Collections.Generic.List[object]]::new()
    if ($Records.Count -eq 0) {
        $issues.Add((New-AvmBicepPolicyIssue -Root $ModuleRoot -Path $SourcePath `
                    -Baseline $Baseline.Name -Code 'avm.bicep.psrule-empty' `
                    -Message "PSRule baseline '$($Baseline.Name)' returned no rule results for this Bicep test."))
    }

    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase }
    else { [System.StringComparison]::Ordinal }
    $expanded = 0
    $processed = 0
    $inspected = 0
    $failures = [System.Collections.Generic.List[object]]::new()
    foreach ($record in $Records) {
        $properties = @($record.PSObject.Properties.Name)
        $missing = @('Source', 'RuleName', 'TargetType', 'Outcome', 'Error') |
            Where-Object { $properties -notcontains $_ }
        if ($missing) {
            break
        }
        $matchesSource = $false
        foreach ($source in @($record.Source)) {
            if ($null -ne $source -and
                $source.PSObject.Properties.Name -contains 'File' -and
                -not [string]::IsNullOrWhiteSpace([string]$source.File) -and
                [string]::Equals([System.IO.Path]::GetFullPath([string]$source.File),
                    [System.IO.Path]::GetFullPath($StagePath), $comparison)) {
                $matchesSource = $true
            }
        }
        if (-not $matchesSource -or
            [string]::IsNullOrWhiteSpace([string]$record.RuleName) -or
            -not $Baseline.RuleNames.Contains([string]$record.RuleName) -or
            [string]::IsNullOrWhiteSpace([string]$record.TargetType) -or
            [string]$record.Outcome -notin @('None', 'Pass', 'Fail') -or
            $null -ne $record.Error) {
            break
        }
        $targetType = [string]$record.TargetType
        if ($targetType -match '^[^./][^/]*/[^/]+') {
            $expanded++
        }
        $inspected++
        if ([string]$record.Outcome -in @('Pass', 'Fail')) {
            $processed++
        }
        if ([string]$record.Outcome -eq 'Fail') {
            $failures.Add($record)
        }
    }
    if ($inspected -ne $Records.Count) {
        $issues.Add((New-AvmBicepPolicyIssue -Root $ModuleRoot -Path $SourcePath `
                    -Baseline $Baseline.Name -Code 'avm.bicep.psrule-result' `
                    -Message "PSRule baseline '$($Baseline.Name)' returned malformed, unrelated, or erroneous rule results."))
    }
    elseif ($Records.Count -gt 0 -and $expanded -eq 0) {
        $issues.Add((New-AvmBicepPolicyIssue -Root $ModuleRoot -Path $SourcePath `
                    -Baseline $Baseline.Name -Code 'avm.bicep.psrule-expansion' `
                    -Message "PSRule baseline '$($Baseline.Name)' did not return expanded Azure resource targets for this Bicep test."))
    }

    return [pscustomobject]@{
        Issues          = $issues.ToArray()
        Failures        = $failures.ToArray()
        ExpandedRecords = $expanded
        ProcessedRules  = $processed
        Valid           = $issues.Count -eq 0
    }
}
