function Set-AvmManagedFilesVersionPin {
    <#
    .SYNOPSIS
        Write the '.avm/managed-files-version.json' pin for a repository
        working tree.

    .DESCRIPTION
        The pin records both the release the repository is synchronised
        against and enough provenance to audit it: the resolved commit, that
        commit's committer date, and when the pin itself was stamped. Written
        as UTF-8 without BOM using LF endings so the file survives the managed
        encoding rules unchanged.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [semver] $Version,

        [Parameter(Mandatory)]
        [string] $Repo,

        [AllowEmptyString()]
        [string] $Commit = '',

        [AllowEmptyString()]
        [string] $CommitDate = '',

        [AllowEmptyString()]
        [string] $UpdatedAt = ''
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $pinPath = Get-AvmManagedFilesVersionPinPath -Root $Root
    $stamp = if ([string]::IsNullOrWhiteSpace($UpdatedAt)) {
        [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    else {
        $UpdatedAt
    }

    $payload = [ordered]@{
        version    = $Version.ToString()
        repo       = $Repo
        commit     = $Commit
        commitDate = $CommitDate
        updatedAt  = $stamp
    }

    if ($PSCmdlet.ShouldProcess($pinPath, "Pin managed files to $Version")) {
        $parent = Split-Path -Parent $pinPath
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }

        $json = (($payload | ConvertTo-Json -Depth 3) -replace "`r`n", "`n") + "`n"
        [System.IO.File]::WriteAllText($pinPath, $json, [System.Text.UTF8Encoding]::new($false))
        Write-AvmLog "managed-files version pin: wrote $Version to '$pinPath'" -Level Verbose
    }

    return [pscustomobject][ordered]@{
        Version    = $Version
        Repo       = $Repo
        Commit     = $Commit
        CommitDate = $CommitDate
        UpdatedAt  = $stamp
        Path       = $pinPath
    }
}
