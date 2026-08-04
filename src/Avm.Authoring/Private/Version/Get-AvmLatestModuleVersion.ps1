function Get-AvmLatestModuleVersion {
    [CmdletBinding()]
    [OutputType([version])]
    param()

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($script:AvmModuleVersionCheckCompleted) {
        return $script:AvmLatestModuleVersion
    }

    $resources = @(
        Find-PSResource `
            -Name 'Avm.Authoring' `
            -Repository 'PSGallery' `
            -ErrorAction Stop |
            Where-Object { $null -ne $_ }
    )
    if ($resources.Count -eq 0) {
        throw [AvmGalleryLookupException]::new(
            'Find-PSResource returned no Avm.Authoring package from PSGallery.')
    }

    $matchingResource = $resources |
        Where-Object {
            $nameProperty = $_.PSObject.Properties['Name']
            $nameProperty -and [string]$nameProperty.Value -ceq 'Avm.Authoring'
        } |
        Select-Object -First 1
    if ($null -eq $matchingResource) {
        throw [AvmGalleryLookupException]::new(
            'Find-PSResource did not return the requested Avm.Authoring package from PSGallery.')
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
        $script:AvmLatestModuleVersion = [version]$latestVersionText
    }
    catch {
        throw [AvmGalleryLookupException]::new(
            'Find-PSResource returned an invalid Avm.Authoring version.',
            $_.Exception)
    }

    $script:AvmModuleVersionCheckCompleted = $true
    return $script:AvmLatestModuleVersion
}
