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
    $script:inventoryHelperPath = Join-Path $repoRoot 'repository-management' 'repository-creation' 'scripts' 'RepositoryInventory.ps1'
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

    It "does not publish an inventory change or expose obsolete CSV-only modes" {
        Test-Path -LiteralPath $script:inventoryHelperPath | Should -BeFalse
        $script:creationScript | Should -Not -Match 'Publish-AvmRepositoryInventory|toolingRepoUrl|metaDataOnly|skipMetaDataCreation|ownerPrimaryDisplayName|ownerSecondaryDisplayName'
    }

    It "imports the trusted checkout instead of installing Avm.Authoring" {
        $script:creationHelper | Should -Match "'src' 'Avm.Authoring'"
        $script:creationHelper | Should -Match 'Import-Module -Name \$manifest -Scope Local'
        $script:creationHelper | Should -Not -Match 'Install-Module|Install-PSResource|Update-Module|Update-PSResource'
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

    It 'limits the initial-push exception to the default-ruleset property' {
        $script:creationHelper | Should -Match 'rulesets-default-opt-in'
        $script:creationHelper | Should -Not -Match 'global-rulesets-opt-out|rulesets-prod-opt-in|rulesets/|bypass'
        $script:creationHelper | Should -Match 'ruleset-recovery\.json'
    }
}
