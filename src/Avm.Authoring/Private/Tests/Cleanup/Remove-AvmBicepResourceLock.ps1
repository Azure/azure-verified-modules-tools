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
        $null = Remove-AzResourceLock -LockId $lock.LockId -Force -ErrorAction Stop
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
