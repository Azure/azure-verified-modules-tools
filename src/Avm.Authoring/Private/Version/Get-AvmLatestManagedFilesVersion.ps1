function Get-AvmLatestManagedFilesVersion {
    <#
    .SYNOPSIS
        Discover the highest semver release tag published by the managed-files
        repository.

    .DESCRIPTION
        Lists remote tags with 'git ls-remote --tags' rather than the GitHub
        API so the lookup needs no credentials and is not subject to anonymous
        rate limits. Only 'vMAJOR.MINOR.PATCH' tags participate; peeled
        annotated-tag entries ('...^{}') and any other ref shape are ignored.
    #>
    [CmdletBinding()]
    [OutputType([semver])]
    param(
        [Parameter(Mandatory)]
        [string] $Repo,

        [AllowEmptyString()]
        [string] $GitPath = ''
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($GitPath)) {
        throw [AvmManagedFilesLookupException]::new(
            'git was not found on PATH, so the managed-files release tags could not be listed.')
    }

    Write-AvmLog "managed-files version lookup: listing release tags for $Repo" -Level Verbose

    try {
        $result = Invoke-AvmProcess `
            -FilePath $GitPath `
            -ArgumentList @('ls-remote', '--tags', "https://github.com/$Repo.git") `
            -TimeoutSec 30 `
            -IgnoreExitCode
    }
    catch {
        throw [AvmManagedFilesLookupException]::new(
            "Unable to list release tags for '$Repo'.",
            $_.Exception)
    }

    if ($result.ExitCode -ne 0) {
        $message = Add-AvmProcessFailureDetail `
            -Message "git ls-remote for '$Repo' exited with code $($result.ExitCode)." `
            -StdOut $result.StdOut `
            -StdErr $result.StdErr
        throw [AvmManagedFilesLookupException]::new(
            $message)
    }

    $versions = @(
        ($result.StdOut -split "`n") |
            ForEach-Object {
                # Peeled annotated-tag rows end in '^{}' and are excluded by the
                # anchored patch group rather than by a separate filter.
                if ($_ -match 'refs/tags/v?(?<version>\d+\.\d+\.\d+)\s*$') {
                    [semver]$Matches['version']
                }
            } |
            Sort-Object -Unique
    )

    if ($versions.Count -eq 0) {
        throw [AvmManagedFilesLookupException]::new(
            "No semver release tags were found for '$Repo'.")
    }

    $latest = $versions[-1]
    Write-AvmLog (
        'managed-files version lookup: discovered latest release {0} for {1}' -f $latest, $Repo) -Level Verbose
    return $latest
}
