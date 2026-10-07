function Get-AvmBicepLayoutInput {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        $Scope
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $items = @(Get-ChildItem -LiteralPath $Scope.Path -Force -ErrorAction Stop)
    $data = @{
        Scope     = $Scope
        IssuePath = Join-Path $Scope.Path 'main.bicep'
        Source    = @($items | Where-Object { $_.Name -ieq 'main.bicep' })
        Metadata  = @($items | Where-Object { $_.Name -ceq 'metadata.json' })
        Compiled  = @($items | Where-Object { $_.Name -ieq 'main.json' })
        Readme    = @($items | Where-Object { $_.Name -ieq 'README.md' })
        Version   = @($items | Where-Object { $_.Name -ieq 'version.json' })
        Tests     = @($items | Where-Object { $_.Name -ieq 'tests' })
        TestsPath = Join-Path $Scope.Path 'tests'
        E2e       = @()
        E2ePath   = Join-Path -Path $Scope.Path -ChildPath 'tests' -AdditionalChildPath 'e2e'
        Folders   = @()
    }
    if (-not $Scope.IsTopLevel -or $data.Tests.Count -ne 1 -or
        -not $data.Tests[0].PSIsContainer -or $data.Tests[0].Name -cne 'tests' -or
        ($data.Tests[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        return $data
    }
    $data.E2e = @(Get-ChildItem -LiteralPath $data.TestsPath -Force -ErrorAction Stop |
            Where-Object { $_.Name -ieq 'e2e' })
    if ($data.E2e.Count -ne 1 -or -not $data.E2e[0].PSIsContainer -or $data.E2e[0].Name -cne 'e2e' -or
        ($data.E2e[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        return $data
    }
    $data.Folders = @(foreach ($folder in @(Get-ChildItem -LiteralPath $data.E2ePath -Directory -Force -ErrorAction Stop |
                    Sort-Object Name -CaseSensitive)) {
            $files = @()
            if (-not ($folder.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                $files = @(Get-ChildItem -LiteralPath $folder.FullName -Force -ErrorAction Stop)
            }
            $ignore = @($files | Where-Object { $_.Name -ieq '.e2eignore' })
            $text = $null
            $readError = $null
            if ($ignore.Count -eq 1 -and -not $ignore[0].PSIsContainer -and $ignore[0].Name -ceq '.e2eignore' -and
                -not ($ignore[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                try {
                    $text = [System.IO.File]::ReadAllText($ignore[0].FullName, [System.Text.UTF8Encoding]::new($false, $true))
                }
                catch [System.IO.IOException], [System.UnauthorizedAccessException], [System.Text.DecoderFallbackException] {
                    $readError = $_.Exception.Message
                }
            }
            @{
                Folder      = $folder
                Main        = @($files | Where-Object { $_.Name -ieq 'main.test.bicep' })
                Ignore      = $ignore
                IgnoreText  = $text
                IgnoreError = $readError
                IssuePath   = $folder.FullName
            }
        })
    return $data
}
