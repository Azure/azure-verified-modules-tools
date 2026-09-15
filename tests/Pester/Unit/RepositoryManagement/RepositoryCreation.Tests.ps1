BeforeAll {
    $repoRoot = (Resolve-Path (
        Join-Path $PSScriptRoot ".." ".." ".." ".."
    )).Path
    $script:creationScript = Get-Content -LiteralPath (
        Join-Path $repoRoot "repository-management/repository-creation/scripts/New-Repository.ps1"
    ) -Raw
    $script:toolingScript = Get-Content -LiteralPath (
        Join-Path $repoRoot "repository-management/repository-creation/scripts/Test-Tooling.ps1"
    ) -Raw
    $script:creationHelper = Get-Content -LiteralPath (
        Join-Path $repoRoot 'repository-management' 'repository-creation' 'scripts' 'RepositoryCreation.ps1'
    ) -Raw
    $script:inventoryHelper = Get-Content -LiteralPath (
        Join-Path $repoRoot 'repository-management' 'repository-creation' 'scripts' 'RepositoryInventory.ps1'
    ) -Raw
}

Describe "Repository creation isolation" {
    It "has no repository sync dependency" {
        $script:creationScript | Should -Not -Match "Invoke-RepositorySync"
        $script:creationScript | Should -Not -Match "Get-AvmLabels"
        $script:creationScript | Should -Not -Match "skipRepoSync"
        $script:creationScript | Should -Not -Match "skipCleanup"
    }

    It "uses permanent metadata initialization without deriving its values from CSV or migration" {
        $script:creationHelper | Should -Match "ExportedCommands\['Initialize-AvmModuleMetadata'\]"
        $script:creationHelper | Should -Match "ExportedCommands\['Test-AvmModuleMetadata'\]"
        $script:creationHelper | Should -Match '\-InputObject \$Metadata'
        $script:creationHelper | Should -Not -Match '\-UpdateSource'
        foreach ($content in @($script:creationScript, $script:creationHelper)) {
            $content | Should -Not -Match 'Import-Csv|ConvertFrom-Csv|Export-Csv|repository-metadata\.csv'
            $content | Should -Not -Match 'Backfill|LegacyRecord|module-metadata[/\\]'
        }
    }

    It "updates metadata in the tooling repository" {
        $script:creationScript | Should -Match 'Publish-AvmRepositoryInventory'
        $script:creationScript | Should -Match '\-ToolingRepoUrl \$toolingRepoUrl'
        $script:inventoryHelper | Should -Match (
            "Join-Path 'repository-management' 'repository-sync' 'config' 'repository-metadata\.csv'"
        )
        $script:inventoryHelper | Should -Match 'Import-Csv -LiteralPath \$csvPath'
        $script:inventoryHelper | Should -Match 'Export-Csv -LiteralPath \$csvPath -NoTypeInformation -UseQuotes AsNeeded'
        $script:inventoryHelper | Should -Match '"chore/add/\$moduleId"'
        $script:inventoryHelper | Should -Match '"chore: add \$moduleId metadata"'
    }

    It "imports the trusted checkout instead of installing Avm.Authoring" {
        $script:creationHelper | Should -Match "'src' 'Avm.Authoring'"
        $script:creationHelper | Should -Match 'Import-Module -Name \$manifest -Scope Local'
        foreach ($content in @($script:creationHelper, $script:inventoryHelper)) {
            $content | Should -Not -Match 'Install-Module|Install-PSResource|Update-Module|Update-PSResource'
        }
        $script:creationScript | Should -Not -Match '(Install-Module|Install-PSResource|Update-Module|Update-PSResource)[^\r\n]*Avm\.Authoring'
        $script:creationScript | Should -Match 'Install-Module powershell-yaml -Force'
    }

    It "publishes the prepared initial commit instead of a remote template" {
        $script:creationHelper | Should -Match "'repo', 'create', \`$repository, '--public'"
        $script:creationHelper | Should -Match "'push', '--set-upstream', 'origin', 'HEAD:refs/heads/main'"
        $script:creationHelper | Should -Not -Match '\-\-template'
        $script:creationHelper | Should -Match 'SupportsShouldProcess'
        $script:creationScript | Should -Match 'SupportsShouldProcess'
    }

    It "checks only creation prerequisites" {
        $script:creationScript | Should -Match "Test-Tooling\.ps1'\) -AuthoringModule"
        $script:toolingScript | Should -Match '"git", "gh"'
        $script:toolingScript | Should -Match "Invoke-AvmRepositoryCreationProcess"
        $script:toolingScript | Should -Match "'auth', 'status'"
        $script:toolingScript | Should -Not -Match "\baz\b"
        $script:toolingScript | Should -Not -Match "\bARM_"
        $script:toolingScript | Should -Not -Match "\bterraform\b"
    }
}
