function Get-AvmBicepExceptionTypeChain {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [System.Management.Automation.ErrorRecord] $ErrorRecord,
        [AllowEmptyCollection()] [string[]] $SensitiveValues = @()
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $pending = [System.Collections.Generic.Stack[System.Exception]]::new()
    $pending.Push($ErrorRecord.Exception)
    $visited = [System.Collections.Generic.HashSet[System.Exception]]::new()
    $types = [System.Collections.Generic.List[string]]::new()
    $limit = 6
    $truncated = $false

    while ($pending.Count -gt 0 -and $types.Count -lt $limit) {
        $exception = $pending.Pop()
        while ($null -ne $exception -and $visited.Add($exception)) {
            if ($types.Count -ge $limit) {
                $truncated = $true
                break
            }
            $typeName = $exception.GetType().FullName
            if ([string]::IsNullOrEmpty($typeName)) { $typeName = $exception.GetType().Name }
            $types.Add($typeName)
            if ($exception -is [System.AggregateException]) {
                foreach ($innerException in $exception.InnerExceptions) {
                    if ($null -ne $innerException) { $pending.Push($innerException) }
                }
                break
            }
            $innerException = $exception.InnerException
            if ($exception -is [System.Management.Automation.RuntimeException]) {
                $recordException = $exception.ErrorRecord.Exception
                if ($null -eq $innerException) {
                    $innerException = $recordException
                }
                elseif ($null -ne $recordException -and
                    -not [object]::ReferenceEquals($recordException, $exception) -and
                    -not [object]::ReferenceEquals($recordException, $innerException)) {
                    $pending.Push($recordException)
                }
            }
            $exception = $innerException
        }
    }

    if ($types.Count -eq $limit -and $pending.Count -gt 0) { $truncated = $true }
    $text = $types -join ' -> '
    if ($truncated) { $text += ' -> [truncated]' }
    return Protect-AvmBicepDiagnosticText -Text $text -SensitiveValues $SensitiveValues
}
