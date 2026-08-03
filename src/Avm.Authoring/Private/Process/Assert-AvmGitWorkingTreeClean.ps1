function Assert-AvmGitWorkingTreeClean {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $git = Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $git) {
        throw [AvmConfigurationException]::new(
            'Pr-check requires git to verify that the working tree is clean, but git was not found on PATH.')
    }

    $result = Invoke-AvmProcess `
        -FilePath $git.Source `
        -ArgumentList @('status', '--porcelain') `
        -WorkingDirectory $Path `
        -Label 'git status --porcelain'

    if (-not [string]::IsNullOrWhiteSpace($result.StdOut)) {
        throw [AvmConfigurationException]::new(
            "Pr-check requires a clean working tree. Commit, stash, or remove these changes before retrying:`n$($result.StdOut.TrimEnd())")
    }
}
