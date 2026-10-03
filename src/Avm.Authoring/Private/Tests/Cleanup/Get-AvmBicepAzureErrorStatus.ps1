function Get-AvmBicepAzureErrorStatus {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    Set-StrictMode -Version 3.0
    $visited = [System.Collections.Generic.HashSet[System.Exception]]::new()
    $exception = $ErrorRecord.Exception
    while ($null -ne $exception -and $visited.Add($exception)) {
        $sources = [System.Collections.Generic.List[object]]::new()
        $sources.Add($exception)
        $response = $exception.PSObject.Properties['Response']
        if ($null -ne $response -and $null -ne $response.Value) {
            $sources.Add($response.Value)
        }
        foreach ($source in $sources) {
            foreach ($name in @('StatusCode', 'HttpStatus')) {
                $property = $source.PSObject.Properties[$name]
                if ($null -ne $property -and $null -ne $property.Value) {
                    $status = $property.Value -as [System.Net.HttpStatusCode]
                    if ($null -ne $status) {
                        return [int]$status
                    }
                }
            }
        }
        $inner = $exception.InnerException
        if ($null -eq $inner -and
            $exception -is [System.Management.Automation.RuntimeException]) {
            $inner = $exception.ErrorRecord.Exception
        }
        $exception = $inner
    }
    return 0
}
