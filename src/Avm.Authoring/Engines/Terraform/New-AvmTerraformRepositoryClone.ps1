function New-AvmTerraformRepositoryClone {
    <#
    .SYNOPSIS
        Clone a published module repository into the local folder given to avm init.
    .DESCRIPTION
        An existing clone of the repository with a checked-out commit is kept.
        Otherwise the repository is cloned beside the folder first. The folder
        is replaced only when it is missing, empty, or holds just a
        metadata.json identical to the one on main, checked again after the
        clone; that file is moved aside and compared there, and put back if
        it differs or the clone cannot be moved into place. Any other content
        is left untouched. Returns Status 'pass', 'skipped', or 'planned' with
        a Detail message.
    .PARAMETER Path
        Local folder for the repository.
    .PARAMETER Repository
        Repository as owner/name.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Repository
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $url = "https://github.com/$Repository"
    $result = { param($Status, $Detail) [pscustomobject]@{ Status = $Status; Detail = $Detail } }
    $otherFiles = "$Path holds other files; clone $url to start work"
    $otherMetadata = "$Path holds a metadata.json that differs from main; clone $url to start work"
    $isMetadataOnly = {
        param($items)
        $items.Count -eq 1 -and -not $items[0].PSIsContainer -and $items[0].Name -ceq 'metadata.json'
    }

    if (Test-Path -LiteralPath (Join-Path -Path $Path -ChildPath '.git')) {
        $origin = (Invoke-AvmGit -ArgumentList @('config', '--get', 'remote.origin.url') -WorkingDirectory $Path `
                -IgnoreExitCode).StdOut.Trim().TrimEnd('/')
        if ($origin -notin @("$url.git", $url, "git@github.com:$Repository.git")) {
            return (& $result 'skipped' "$Path is not a clone of $url")
        }
        if ((Invoke-AvmGit -ArgumentList @('rev-parse', '--verify', '--quiet', 'HEAD') -WorkingDirectory $Path `
                    -IgnoreExitCode).ExitCode -ne 0) {
            return (& $result 'skipped' "$Path has no commits yet; pull main into it")
        }
        return (& $result 'pass' "existing clone at $Path")
    }
    $entries = @(if (Test-Path -LiteralPath $Path) { Get-ChildItem -LiteralPath $Path -Force })
    if ($entries.Count -gt 0 -and -not (& $isMetadataOnly $entries)) {
        return (& $result 'skipped' $otherFiles)
    }
    if (-not $PSCmdlet.ShouldProcess($Path, "Clone $url")) {
        return (& $result 'planned' "clone to $Path")
    }

    $parent = Split-Path -Path $Path -Parent
    $name = Split-Path -Path $Path -Leaf
    $null = New-Item -ItemType Directory -Path $parent -Force
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $staging = Join-Path -Path $parent -ChildPath ".$name.avm-clone-$suffix"
    $backup = Join-Path -Path $parent -ChildPath ".$name.avm-metadata-$suffix.json"
    try {
        $null = Invoke-AvmGit -ArgumentList @('clone', '--quiet', "$url.git", $staging) -WorkingDirectory $parent -UseGitHubCredential -RetryNetworkFailure
        $entries = @(if (Test-Path -LiteralPath $Path) { Get-ChildItem -LiteralPath $Path -Force })
        if ($entries.Count -gt 0 -and -not (& $isMetadataOnly $entries)) {
            return (& $result 'skipped' $otherFiles)
        }
        $movedBackup = $false
        try {
            if ($entries.Count -gt 0) {
                $published = (Invoke-AvmGit -ArgumentList @('show', 'HEAD:metadata.json') -WorkingDirectory $staging).StdOut
                # Compare after moving the file aside, so a concurrent edit cannot be lost.
                [System.IO.File]::Move($entries[0].FullName, $backup)
                $movedBackup = $true
                if ([System.IO.File]::ReadAllText($backup) -cne $published) {
                    [System.IO.File]::Move($backup, $entries[0].FullName)
                    $movedBackup = $false
                    return (& $result 'skipped' $otherMetadata)
                }
            }
            if (Test-Path -LiteralPath $Path) {
                [System.IO.Directory]::Delete($Path)
            }
            [System.IO.Directory]::Move($staging, $Path)
        }
        catch {
            if ($movedBackup -and (Test-Path -LiteralPath $backup)) {
                $null = New-Item -ItemType Directory -Path $Path -Force
                [System.IO.File]::Move($backup, (Join-Path -Path $Path -ChildPath 'metadata.json'))
            }
            throw
        }
        if ($movedBackup) {
            [System.IO.File]::Delete($backup)
        }
        return (& $result 'pass' "cloned to $Path")
    }
    finally {
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ProgressAction SilentlyContinue -ErrorAction SilentlyContinue
        }
    }
}
