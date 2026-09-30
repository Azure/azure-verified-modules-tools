function Export-AvmReadmeNote {
    <#
    .SYNOPSIS
        Extract authored Bicep README Notes into an adjacent, tracked sidecar.

    .DESCRIPTION
        One-time migration only. Copies the body of the top-level ## Notes
        section from README.md to README.notes.md without overwriting either
        file. Existing sidecars are left unchanged; normal documentation
        generation reads only the sidecar, never README Notes.

    .PARAMETER Path
        Directory containing the existing README.md. Defaults to the current
        directory. Run once per module with authored Notes.

    .EXAMPLE
        avm docs export-notes -Path ./avm/res/storage/storage-account
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [string] $Path = $PWD.Path,

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck

    $root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw [AvmConfigurationException]::new("Notes migration needs an existing module directory: $root")
    }

    $readmePath = Join-Path -Path $root -ChildPath 'README.md'
    $sidecarPath = Join-Path -Path $root -ChildPath 'README.notes.md'
    $files = @(Get-ChildItem -LiteralPath $root -Force)
    $readmes = @($files | Where-Object { $_.Name -ieq 'README.md' })
    if ($readmes.Count -ne 1 -or $readmes[0].Name -cne 'README.md' -or
        $readmes[0].PSIsContainer -or
        ($readmes[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw [AvmConfigurationException]::new("Notes migration needs a regular README.md with exact casing: $readmePath")
    }

    $existingSidecars = @($files | Where-Object { $_.Name -ieq 'README.notes.md' })
    if ($existingSidecars.Count -gt 0) {
        if ($existingSidecars.Count -ne 1 -or $existingSidecars[0].Name -cne 'README.notes.md' -or
            $existingSidecars[0].PSIsContainer -or
            ($existingSidecars[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw [AvmConfigurationException]::new("Notes sidecar must be a regular README.notes.md with exact casing: $sidecarPath")
        }
        return [pscustomobject]@{ Engine = 'bicep'; Status = 'pass'; Changed = $false; PlannedFiles = @() }
    }

    $readmeBytes = [System.IO.File]::ReadAllBytes($readmePath)
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    try {
        $content = $utf8.GetString($readmeBytes)
    }
    catch [System.Text.DecoderFallbackException] {
        throw [AvmConfigurationException]::new("README.md must be valid UTF-8 to migrate its Notes: $readmePath")
    }
    $notes = Get-AvmLegacyReadmeNote -Content $content
    if ($null -eq $notes) {
        return [pscustomobject]@{ Engine = 'bicep'; Status = 'pass'; Changed = $false; PlannedFiles = @() }
    }

    $plan = @([pscustomobject]@{ Path = $sidecarPath; Original = $null; Content = $notes.Body })
    Test-AvmModuleInitializationPlan -Root $root -Plan $plan
    $changed = $false
    if ($PSCmdlet.ShouldProcess($sidecarPath, 'Extract authored README Notes into a tracked sidecar')) {
        $changed = Write-AvmModuleInitializationPlan -Root $root -Plan $plan -Confirm:$false
    }

    return [pscustomobject]@{
        Engine       = 'bicep'
        Status       = 'pass'
        Changed      = $changed
        PlannedFiles = @('README.notes.md')
    }
}
