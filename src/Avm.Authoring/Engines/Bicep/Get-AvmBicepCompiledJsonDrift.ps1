function Get-AvmBicepCompiledJsonDrift {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $CompiledJson,

        [AllowNull()]
        [byte[]] $CurrentBytes
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($null -eq $CurrentBytes) {
        return 'missing'
    }

    $expected = [System.Text.UTF8Encoding]::new($false).GetBytes($CompiledJson)
    if (-not [System.Linq.Enumerable]::SequenceEqual([byte[]]$CurrentBytes, [byte[]]$expected)) {
        return 'stale'
    }

    return $null
}
