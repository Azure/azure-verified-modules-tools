function Get-AvmLatestModuleVersion {
    [CmdletBinding()]
    [OutputType([version], [pscustomobject])]
    param(
        [switch] $Refresh,
        [switch] $IncludeRepository
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Refresh -and $script:AvmModuleVersionCheckCompleted) {
        Write-AvmLog (
            'module version lookup: refresh requested; discarding cached latest version {0}' -f
            $script:AvmLatestModuleVersion) -Level Verbose
        $script:AvmLatestModuleVersion = $null
        $script:AvmLatestModuleRelease = $null
        $script:AvmModuleVersionCheckCompleted = $false
    }

    if ($script:AvmModuleVersionCheckCompleted) {
        Write-AvmLog (
            'module version lookup: reusing cached latest version {0}' -f
            $script:AvmLatestModuleVersion) -Level Verbose
        if ($IncludeRepository) { return $script:AvmLatestModuleRelease }
        return $script:AvmLatestModuleVersion
    }

    Write-AvmLog 'module version lookup: querying configured PowerShell repositories for Avm.Authoring' -Level Verbose
    # The check is advisory and runs for every top-level command, so it uses the
    # smaller retry budget to keep offline runs responsive.
    $releases = @(Invoke-AvmPSRepositoryOperation -All -Action {
            param($RepositoryName)
            $resources = @(
                Invoke-AvmRetry -RetryActivity 'PowerShell repository version lookup' `
                    -RetryMaxAttempts (Get-AvmNetworkRetryPolicy).AdvisoryMaxAttempts -RetryQuiet `
                    -RetryAction {
                    Find-PSResource `
                        -Name 'Avm.Authoring' `
                        -Repository $RepositoryName `
                        -ErrorAction Stop
                } |
                    Where-Object { $null -ne $_ }
            )
            if ($resources.Count -eq 0) {
                throw [AvmGalleryLookupException]::new(
                    "Find-PSResource returned no Avm.Authoring package from repository '$RepositoryName'.")
            }

            $matchingResource = $resources |
                Where-Object {
                    $nameProperty = $_.PSObject.Properties['Name']
                    $nameProperty -and [string]$nameProperty.Value -ceq 'Avm.Authoring'
                } |
                Select-Object -First 1
            if ($null -eq $matchingResource) {
                throw [AvmGalleryLookupException]::new(
                    "Find-PSResource did not return the requested Avm.Authoring package from repository '$RepositoryName'.")
            }

            $versionProperty = $matchingResource.PSObject.Properties['Version']
            $latestVersionText = if ($versionProperty) {
                [string]$versionProperty.Value
            }
            else {
                ''
            }
            if ([string]::IsNullOrWhiteSpace($latestVersionText)) {
                throw [AvmGalleryLookupException]::new(
                    'The Avm.Authoring package returned by Find-PSResource did not contain a version.')
            }

            try {
                $version = [version]$latestVersionText
            }
            catch {
                throw [AvmGalleryLookupException]::new(
                    'Find-PSResource returned an invalid Avm.Authoring version.',
                    $_.Exception)
            }
            [pscustomobject]@{
                Version    = $version
                Repository = $RepositoryName
            }
        })

    $script:AvmLatestModuleVersion = ($releases.Version | Sort-Object -Descending | Select-Object -First 1)
    $script:AvmLatestModuleRelease = [pscustomobject]@{
        Version      = $script:AvmLatestModuleVersion
        Repositories = @($releases | Where-Object { $_.Version -eq $script:AvmLatestModuleVersion } |
                ForEach-Object Repository)
    }

    $script:AvmModuleVersionCheckCompleted = $true
    Write-AvmLog (
        'module version lookup: discovered latest configured repository version {0}' -f
        $script:AvmLatestModuleVersion) -Level Verbose
    if ($IncludeRepository) { return $script:AvmLatestModuleRelease }
    return $script:AvmLatestModuleVersion
}
