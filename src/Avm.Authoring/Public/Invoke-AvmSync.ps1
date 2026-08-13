function Invoke-AvmSync {
    <#
    .SYNOPSIS
        Synchronise the current Terraform module repository's managed files
        against the AVM governance source-of-truth (file sync only, no PR).

    .DESCRIPTION
        Terraform-only. Resolves the enclosing module via Get-AvmModuleContext,
        then hands off to Sync-AvmManagedFile, which reconciles the working
        tree's managed files with the governance source: it adds missing
        managed files, updates stale ones, and removes deprecated files.

        Managed file content and the repository config come from two separate
        repositories. Files default to Azure/azure-verified-modules-managed-files
        (ref 'main', base folder 'terraform'); config.json defaults to
        Azure/azure-verified-modules-tools (ref 'main', folder
        'repository-management/repository-config'). Every piece of that is
        overridable, either per parameter here, via AVM_MANAGED_FILES_*
        environment variables, or via a repo-committed
        '.avm/managed-files.json'. A direct local source
        (-ManagedFilesLocalPath) skips the git fetch entirely.

        By default the reconciled changes are written straight to the working
        tree. With -CheckDrift nothing is written: any file
        that would change makes the result Status 'fail' and is reported as an
        Issue. That drift gate is what pr-check wires in, while pre-commit runs
        the plain apply as its first step.

        This verb performs the *file sync* only. It never opens, updates, or
        merges a pull request; committing and pushing the result is left to the
        caller (a human, pre-commit, or a repo-sync workflow).

        Routed by the dispatcher: 'avm sync'.

    .PARAMETER Path
        Working directory whose enclosing module to sync. Defaults to the
        current location.

    .PARAMETER Ecosystem
        Force the ecosystem selector. Defaults to 'auto'. Bicep modules are
        rejected: managed-files sync is terraform-only.

    .PARAMETER AllowPathFallback
        Accepted for parity with the other verbs; forwarded to the engine.

    .PARAMETER CheckDrift
        Report-only mode. No files are written; any required change makes the
        result Status 'fail' and is emitted as an Issue.

    .PARAMETER ManagedFilesRepo
        owner/name of the git repo holding the managed files. Defaults to
        'Azure/azure-verified-modules-managed-files'.

    .PARAMETER ManagedFilesRef
        Git ref to fetch. Defaults to 'main'.

    .PARAMETER ManagedFilesPath
        Path within the source repo to the managed-files base folder. Defaults
        to 'terraform'.

    .PARAMETER ManagedFilesLocalPath
        Direct local path to the managed-files base folder. Skips the git fetch.

    .PARAMETER ConfigRepo
        owner/name of the git repo holding the config folder. Defaults to
        'Azure/azure-verified-modules-tools'. This is deliberately independent
        of -ManagedFilesRepo, because config.json stays in the tools repo.

    .PARAMETER ConfigRef
        Git ref for the config repo. Defaults to 'main', independently of
        -ManagedFilesRef.

    .PARAMETER ConfigPath
        Path within the config repo to the folder holding 'config.json'.
        Defaults to 'repository-management/repository-config'.

    .PARAMETER ConfigLocalPath
        Direct local path to the config folder. Skips the config repo fetch.

    .PARAMETER RepoId
        Repository id used to look up overlays/exclusions in config.json.
        Defaults to the leaf of the module root with a leading
        'terraform-azurerm-' / 'terraform-azapi-' prefix stripped.

    .PARAMETER Upgrade
        Sync the newest managed-files release instead of the version pinned in
        '.avm/managed-files-version.json', and rewrite the pin to match.

    .PARAMETER SkipManagedFilesVersionCheck
        Bypass managed-files version pinning and release-drift enforcement.

    .OUTPUTS
        pscustomobject from the engine: Engine, Tool, ToolPath, ToolSource,
        Status, FilesProcessed, Issues, Added, Updated, Removed.

    .EXAMPLE
        avm sync

    .EXAMPLE
        avm sync -CheckDrift

    .EXAMPLE
        Invoke-AvmSync -Path C:\repos\terraform-azurerm-avm-res-foo -ManagedFilesLocalPath D:\gov\managed-files
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string] $Path = $PWD.Path,

        [ValidateSet('auto', 'bicep', 'terraform')]
        [string] $Ecosystem = 'auto',

        [switch] $AllowPathFallback,

        [switch] $CheckDrift,

        [string] $ManagedFilesRepo,
        [string] $ManagedFilesRef,
        [string] $ManagedFilesPath,
        [string] $ManagedFilesLocalPath,

        [string] $ConfigRepo,
        [string] $ConfigRef,
        [string] $ConfigPath,
        [string] $ConfigLocalPath,

        [string] $RepoId,

        [switch] $Upgrade,

        [switch] $SkipManagedFilesVersionCheck,

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck

    $context = Get-AvmModuleContext -Path $Path -Ecosystem $Ecosystem

    switch ($context.Ecosystem) {
        'terraform' {
            Sync-AvmManagedFile `
                -Context $context `
                -AllowPathFallback:$AllowPathFallback `
                -CheckDrift:$CheckDrift `
                -ManagedFilesRepo $ManagedFilesRepo `
                -ManagedFilesRef $ManagedFilesRef `
                -ManagedFilesPath $ManagedFilesPath `
                -ManagedFilesLocalPath $ManagedFilesLocalPath `
                -ConfigRepo $ConfigRepo `
                -ConfigRef $ConfigRef `
                -ConfigPath $ConfigPath `
                -ConfigLocalPath $ConfigLocalPath `
                -RepoId $RepoId `
                -Upgrade:$Upgrade `
                -SkipManagedFilesVersionCheck:$SkipManagedFilesVersionCheck
        }
        default {
            throw [AvmNotSupportedException]::new(
                "avm sync is a terraform-only command; the resolved module ecosystem is '$($context.Ecosystem)'. Managed-files sync for bicep is not implemented.")
        }
    }
}
