function Get-AvmBicepTestScope {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context,

        [switch] $Recurse
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Context.Ecosystem -ne 'bicep') {
        throw [System.ArgumentException]::new('Bicep test scopes require a Bicep module context.')
    }

    $root = [System.IO.Path]::GetFullPath($Context.Root)
    foreach ($scope in @(Get-AvmMetadataScope -Context $Context)) {
        if (-not $Recurse -and $scope.ChildModule -and $scope.Path -cne $root) {
            continue
        }
        $sources = @(Get-ChildItem -LiteralPath $scope.Path -Force |
                Where-Object { $_.Name -ieq 'main.bicep' })
        if ($sources.Count -eq 0) {
            continue
        }
        if ($sources.Count -ne 1 -or $sources[0].PSIsContainer -or
            $sources[0].Name -cne 'main.bicep' -or
            ($sources[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw [AvmConfigurationException]::new(
                "Expected a regular main.bicep with exact casing in '$($scope.Path)'.")
        }

        [pscustomobject]@{
            Path = $scope.Path
            Rel  = [System.IO.Path]::GetRelativePath($root, $scope.Path).Replace('\', '/')
        }
    }
}
