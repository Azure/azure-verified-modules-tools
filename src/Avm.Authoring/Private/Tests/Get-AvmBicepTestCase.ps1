function Get-AvmBicepTestCase {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context,

        [switch] $Recurse
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $root = [System.IO.Path]::GetFullPath($Context.Root)
    foreach ($scope in @(Get-AvmBicepTestScope -Context $Context -Recurse:$Recurse)) {
        $tests = @(Get-ChildItem -LiteralPath $scope.Path -Directory -Force |
                Where-Object { $_.Name -ieq 'tests' })
        if ($tests.Count -eq 0) {
            continue
        }
        if ($tests.Count -ne 1 -or $tests[0].Name -cne 'tests' -or
            ($tests[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw [AvmConfigurationException]::new(
                "Expected an unlinked tests directory with exact casing in '$($scope.Path)'.")
        }
        $e2e = @(Get-ChildItem -LiteralPath $tests[0].FullName -Directory -Force |
                Where-Object { $_.Name -ieq 'e2e' })
        if ($e2e.Count -eq 0) {
            continue
        }
        if ($e2e.Count -ne 1 -or $e2e[0].Name -cne 'e2e' -or
            ($e2e[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw [AvmConfigurationException]::new(
                "Expected an unlinked tests/e2e directory with exact casing in '$($scope.Path)'.")
        }
        $links = @(Get-ChildItem -LiteralPath $e2e[0].FullName -Recurse -Directory -Force |
                Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint })
        if ($links.Count -gt 0) {
            throw [AvmConfigurationException]::new(
                "Bicep test cases cannot traverse linked directories: $($links[0].FullName)")
        }

        foreach ($file in @(Get-ChildItem -LiteralPath $e2e[0].FullName -Recurse -File -Force |
                    Where-Object { $_.Name -ieq 'main.test.bicep' } |
                    Sort-Object -Property FullName -CaseSensitive)) {
            if ($file.Name -cne 'main.test.bicep' -or
                ($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                throw [AvmConfigurationException]::new(
                    "Expected an unlinked main.test.bicep with exact casing: $($file.FullName)")
            }
            $markers = @(Get-ChildItem -LiteralPath $file.DirectoryName -Force |
                    Where-Object { $_.Name -ieq '.e2eignore' })
            if ($markers.Count -gt 0 -and
                ($markers.Count -ne 1 -or $markers[0].Name -cne '.e2eignore' -or
                $markers[0].PSIsContainer -or
                ($markers[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint))) {
                throw [AvmConfigurationException]::new(
                    "Expected an unlinked .e2eignore file with exact casing in '$($file.DirectoryName)'.")
            }

            [pscustomobject][ordered]@{
                Name              = $file.Directory.Name
                Path              = $file.FullName
                RelativePath      = [System.IO.Path]::GetRelativePath($root, $file.FullName).Replace('\', '/')
                RelativeDirectory = [System.IO.Path]::GetRelativePath($root, $file.DirectoryName).Replace('\', '/')
                Ignored           = $markers.Count -gt 0
            }
        }
    }
}
