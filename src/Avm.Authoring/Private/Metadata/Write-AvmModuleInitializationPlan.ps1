function Write-AvmModuleInitializationPlan {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Plan
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ($Plan.Count -eq 0) {
        return $false
    }

    Test-AvmModuleInitializationPlan -Root $Root -Plan $Plan
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase }
    else { [System.StringComparison]::Ordinal }
    $rootPath = [System.IO.Path]::GetFullPath($Root)
    if (-not $PSCmdlet.ShouldProcess($rootPath, 'Write validated module initialization files')) {
        return $false
    }

    $createdDirectories = [System.Collections.Generic.List[string]]::new()
    $createdFiles = [System.Collections.Generic.List[object]]::new()
    $replacedFiles = [System.Collections.Generic.List[object]]::new()
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    try {
        foreach ($item in $Plan) {
            $target = [System.IO.Path]::GetFullPath([string]$item.Path)
            $parent = Split-Path -Path $target -Parent
            $existingDirectory = Get-AvmExistingDirectory -Path $parent
            $pending = [System.Collections.Generic.Stack[string]]::new()
            $directory = $parent
            while (-not [string]::Equals($directory, $existingDirectory, $comparison)) {
                $pending.Push($directory)
                $next = Split-Path -Path $directory -Parent
                if (-not $next -or [string]::Equals($directory, $next, $comparison)) {
                    throw [System.IO.IOException]::new("Cannot locate the existing parent of $target.")
                }
                $directory = $next
            }
            while ($pending.Count -gt 0) {
                $directory = $pending.Pop()
                if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
                    $null = New-Item -ItemType Directory -Path $directory -ErrorAction Stop
                    $createdDirectories.Add($directory)
                }
            }

            $originalBytes = $null
            $originalWriteTime = $null
            if ($null -ne $item.Original) {
                if ((Get-Content -LiteralPath $target -Raw) -cne $item.Original) {
                    throw [System.IO.IOException]::new("Source changed during initialization: $target")
                }
                $originalBytes = [System.IO.File]::ReadAllBytes($target)
                $originalWriteTime = [System.IO.File]::GetLastWriteTimeUtc($target)
            }
            $contentBytes = $utf8NoBom.GetBytes([string]$item.Content)
            $temporaryPath = Join-Path -Path $parent -ChildPath ('.avm-initialize-' + [guid]::NewGuid().ToString('N') + '.tmp')
            try {
                [System.IO.File]::WriteAllBytes($temporaryPath, $contentBytes)
                [System.IO.File]::Move($temporaryPath, $target, ($null -ne $item.Original))
                if ($null -eq $item.Original) {
                    $createdFiles.Add([pscustomobject]@{ Path = $target; Bytes = $contentBytes })
                }
                else {
                    $replacedFiles.Add([pscustomobject]@{
                            Path = $target; OriginalBytes = $originalBytes
                            OriginalWriteTime = $originalWriteTime; Bytes = $contentBytes
                        })
                }
            }
            finally {
                if ([System.IO.File]::Exists($temporaryPath)) {
                    [System.IO.File]::Delete($temporaryPath)
                }
            }
        }
    }
    catch {
        for ($i = $createdFiles.Count - 1; $i -ge 0; $i--) {
            $created = $createdFiles[$i]
            try {
                if ([System.IO.File]::Exists($created.Path)) {
                    $current = [System.IO.File]::ReadAllBytes($created.Path)
                    if ([System.Linq.Enumerable]::SequenceEqual([byte[]]$current, [byte[]]$created.Bytes)) {
                        [System.IO.File]::Delete($created.Path)
                    }
                    else {
                        Write-AvmLog "Cannot roll back '$($created.Path)': content changed after initialization." -Level Warning
                    }
                }
            }
            catch {
                Write-AvmLog "Cannot roll back '$($created.Path)': $($_.Exception.Message)" -Level Warning
            }
        }
        for ($i = $replacedFiles.Count - 1; $i -ge 0; $i--) {
            $replaced = $replacedFiles[$i]
            try {
                $current = [System.IO.File]::ReadAllBytes($replaced.Path)
                if ([System.Linq.Enumerable]::SequenceEqual([byte[]]$current, [byte[]]$replaced.Bytes)) {
                    [System.IO.File]::WriteAllBytes($replaced.Path, $replaced.OriginalBytes)
                    [System.IO.File]::SetLastWriteTimeUtc($replaced.Path, $replaced.OriginalWriteTime)
                }
                else {
                    Write-AvmLog "Cannot restore '$($replaced.Path)': content changed after initialization." -Level Warning
                }
            }
            catch {
                Write-AvmLog "Cannot restore '$($replaced.Path)': $($_.Exception.Message)" -Level Warning
            }
        }
        for ($i = $createdDirectories.Count - 1; $i -ge 0; $i--) {
            $directory = $createdDirectories[$i]
            try {
                if ([System.IO.Directory]::Exists($directory)) {
                    if (@(Get-ChildItem -LiteralPath $directory -Force).Count -eq 0) {
                        [System.IO.Directory]::Delete($directory)
                    }
                    else {
                        Write-AvmLog "Cannot roll back '$directory': directory is no longer empty." -Level Warning
                    }
                }
            }
            catch {
                Write-AvmLog "Cannot roll back '$directory': $($_.Exception.Message)" -Level Warning
            }
        }
        throw
    }
    return $true
}
