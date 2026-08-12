function Get-AvmManagedFilesVersionPin {
    <#
    .SYNOPSIS
        Read the '.avm/managed-files-version.json' pin from a repository
        working tree.

    .DESCRIPTION
        Returns $null when the repository is not yet pinned, so callers can
        treat "never pinned" and "pin unreadable" identically and self-heal by
        stamping a fresh pin. An unreadable pin warns rather than throwing,
        matching how Get-AvmManagedFilesFileConfig treats a malformed
        '.avm/managed-files.json'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Root
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $pinPath = Get-AvmManagedFilesVersionPinPath -Root $Root
    if (-not (Test-Path -LiteralPath $pinPath -PathType Leaf)) { return $null }

    try {
        $json = Get-Content -LiteralPath $pinPath -Raw | ConvertFrom-Json
    }
    catch {
        Write-AvmLog "Failed to parse '$pinPath': $($_.Exception.Message)" -Level Warning
        return $null
    }

    if ($null -eq $json -or -not $json.PSObject.Properties['version']) {
        Write-AvmLog "'$pinPath' does not declare a 'version'; treating the repository as unpinned." -Level Warning
        return $null
    }

    $versionText = [string]$json.version
    $parsed = [semver]::new(0, 0, 0)
    if (-not [semver]::TryParse($versionText, [ref]$parsed)) {
        Write-AvmLog "'$pinPath' declares an invalid version '$versionText'; treating the repository as unpinned." -Level Warning
        return $null
    }

    $read = {
        param([string] $Name)
        if (-not $json.PSObject.Properties[$Name]) { return '' }

        # ConvertFrom-Json silently coerces ISO 8601 strings to [datetime], so
        # re-render date fields rather than letting culture-specific formatting
        # corrupt the value on the way back out.
        $value = $json.$Name
        if ($value -is [datetime]) { return $value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
        if ($value -is [datetimeoffset]) { return $value.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ') }
        return [string]$value
    }

    return [pscustomobject][ordered]@{
        Version    = $parsed
        Repo       = & $read 'repo'
        Commit     = & $read 'commit'
        CommitDate = & $read 'commitDate'
        UpdatedAt  = & $read 'updatedAt'
        Path       = $pinPath
    }
}
