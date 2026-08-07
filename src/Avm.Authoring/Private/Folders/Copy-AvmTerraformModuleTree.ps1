function Copy-AvmTerraformModuleTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $SourceRoot,

        [Parameter(Mandatory)]
        [string] $DestinationRoot
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $null = New-Item -ItemType Directory -Path $DestinationRoot -Force -ErrorAction Stop
    $files = @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -File -Force -ErrorAction Stop)
    Write-AvmLog ("module-tree: discovered {0} file(s) under {1}" -f $files.Count, $SourceRoot) -Level Verbose | Out-Null
    $copied = 0
    foreach ($file in $files) {
        $relative = [System.IO.Path]::GetRelativePath($SourceRoot, $file.FullName)
        $segments = $relative -split '[\\/]'
        if ($segments -contains '.git' -or $segments -contains '.terraform') { continue }
        if ($file.Name -eq '.terraform.lock.hcl' -or $file.Name -like '*.tfstate*') { continue }
        if ($file.Name -in @('tfplan', 'tfplan.json')) { continue }

        $destination = Join-Path $DestinationRoot $relative
        $parent = Split-Path -Path $destination -Parent
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop
        }
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force -ErrorAction Stop
        $copied++
    }
    Write-AvmLog ("module-tree: copied {0} file(s) to {1}" -f $copied, $DestinationRoot) -Level Verbose | Out-Null
}
