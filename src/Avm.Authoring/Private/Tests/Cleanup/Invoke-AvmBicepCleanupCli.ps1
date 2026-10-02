function Invoke-AvmBicepCleanupCli {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [string[]] $ArgumentList,

        [switch] $IgnoreExitCode,

        [switch] $AllowNotFound
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $az = Get-Command -Name 'az' -CommandType Application -ErrorAction Stop |
        Select-Object -First 1
    $context = Get-AzContext -ErrorAction Stop
    $subscription = Get-AvmPropertyValue -InputObject $context -Name 'Subscription'
    $subscriptionId = [string](Get-AvmPropertyValue -InputObject $subscription -Name 'Id')
    if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
        throw [AvmConfigurationException]::new('Azure cleanup requires a selected subscription.')
    }
    if (($ArgumentList -contains 'delete' -or $ArgumentList -contains 'purge') -and
        -not $PSCmdlet.ShouldProcess(($ArgumentList -join ' '), 'Run Azure cleanup command')) {
        return
    }
    $tenantId = Get-AvmPropertyValue -InputObject (
        Get-AvmPropertyValue -InputObject $context -Name 'Tenant') -Name 'Id'
    Assert-AvmBicepAzureIdentity -AzPath $az.Source -SubscriptionId $subscriptionId -TenantId $tenantId
    $result = Invoke-AvmProcess -FilePath $az.Source -ArgumentList (
        $ArgumentList + @('--subscription', $subscriptionId, '--output', 'json')
    ) -IgnoreExitCode
    if ($IgnoreExitCode) {
        return $result
    }
    if ($result.ExitCode -ne 0) {
        $missing = [string]$result.StdErr -match '(?m)^(?:ERROR:\s*)?\((?:ResourceNotFound|ResourceGroupNotFound|ParentResourceNotFound|NotFound)\)'
        if ($AllowNotFound -and $missing) {
            return $null
        }
        throw [AvmProcessException]::new((Add-AvmProcessFailureDetail `
                    -Message "Azure cleanup command failed (exit $($result.ExitCode))." `
                    -StdErr $result.StdErr -StdOut $result.StdOut))
    }
    if ($ArgumentList -contains 'show' -or $ArgumentList -contains 'list') {
        if ([string]::IsNullOrWhiteSpace([string]$result.StdOut) -or
            -not (Test-Json -Json $result.StdOut -ErrorAction SilentlyContinue)) {
            throw [AvmProcessException]::new('Azure cleanup lookup returned invalid JSON.')
        }
        $document = $result.StdOut | ConvertFrom-Json -AsHashtable -NoEnumerate -ErrorAction Stop
        if (($ArgumentList -contains 'show' -and $document -isnot [System.Collections.IDictionary]) -or
            ($ArgumentList -contains 'list' -and $document -isnot [array])) {
            throw [AvmProcessException]::new('Azure cleanup lookup returned an unexpected JSON shape.')
        }
    }
    return $result.StdOut
}
