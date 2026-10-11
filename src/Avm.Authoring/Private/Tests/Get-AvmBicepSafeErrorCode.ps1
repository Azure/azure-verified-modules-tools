function Get-AvmBicepSafeErrorCode {
    <#
    .SYNOPSIS
        Return the distinct Azure error codes in an error record, without messages or parameters.

    .DESCRIPTION
        Walks the structured error response breadth-first through error, details and innererror
        nodes. Only values shaped like Azure error identifiers are returned, so
        free-form text that might contain secrets is never surfaced.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord,

        [ValidateRange(1, 100)]
        [int] $Limit = 10
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $codes = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $pending = [System.Collections.Generic.Queue[object]]::new()
    $pending.Enqueue((Get-AvmBicepErrorResponse -ErrorRecord $ErrorRecord))
    for ($visited = 0; $pending.Count -gt 0 -and $codes.Count -lt $Limit -and $visited -lt 1000; $visited++) {
        $node = $pending.Dequeue()
        if ($null -eq $node -or $node -is [string] -or $node -is [System.ValueType]) { continue }
        if ($node -is [System.Collections.IEnumerable] -and $node -isnot [System.Collections.IDictionary]) {
            foreach ($child in $node) { $pending.Enqueue($child) }
            continue
        }
        if ($node -is [System.Collections.IDictionary]) {
            # Parsed JSON keys are case-sensitive; Azure uses both code and Code.
            $map = @{}
            foreach ($key in $node.Keys) { $map[[string]$key] = $node[$key] }
            $node = $map
        }
        $code = Get-AvmPropertyValue -InputObject $node -Name 'Code'
        if ($code -is [string] -and $code -cmatch '\A[A-Za-z][A-Za-z0-9._-]{0,127}\z' -and $seen.Add($code)) {
            $codes.Add($code)
        }
        foreach ($name in @('Error', 'Details', 'InnerError')) {
            $pending.Enqueue((Get-AvmPropertyValue -InputObject $node -Name $name))
        }
    }
    return $codes.ToArray()
}