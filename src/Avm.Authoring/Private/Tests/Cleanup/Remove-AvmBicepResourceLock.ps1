function Remove-AvmBicepResourceLock {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string] $ResourceId,

        [string] $Type = '',

        [ValidateRange(1, 100)]
        [int] $RetryLimit = 10,

        [ValidateRange(0, 300)]
        [int] $RetryInterval = 10
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $locks = @(Get-AvmBicepResourceLock -ResourceId $ResourceId -Type $Type)
    if ($locks.Count -eq 0) {
        return
    }
    if (-not $PSCmdlet.ShouldProcess($ResourceId, "Remove $($locks.Count) resource lock(s)")) {
        return
    }
    foreach ($lock in $locks) {
        $useRest = Get-AvmPropertyValue -InputObject $lock -Name 'UseRest' -NoEnumerate
        if ($useRest -eq $true) {
            $response = Invoke-AzRestMethod -Method DELETE -Path "$($lock.LockId)?api-version=2016-09-01" -ErrorAction Stop
            $status = Get-AvmPropertyValue -InputObject $response -Name 'StatusCode' -NoEnumerate
            if (($status -isnot [int] -and $status -isnot [System.Net.HttpStatusCode]) -or
                [int]$status -notin @(200, 202, 204, 404)) {
                throw [AvmProcessException]::new('Azure did not accept removal of the recorded resource lock.')
            }
        }
        else {
            $null = Remove-AzResourceLock -LockId $lock.LockId -Force -ErrorAction Stop
        }
    }
    for ($attempt = 0; $attempt -lt $RetryLimit; $attempt++) {
        $remaining = @(Get-AvmBicepResourceLock -ResourceId $ResourceId -Type $Type)
        if ($remaining.Count -eq 0) {
            return
        }
        if ($attempt + 1 -lt $RetryLimit) {
            Start-Sleep -Seconds $RetryInterval
        }
    }
    throw [AvmProcessException]::new("Resource locks remain on '$ResourceId' after $RetryLimit checks.")
}
