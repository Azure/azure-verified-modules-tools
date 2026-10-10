#Requires -Version 7.4

function Get-AvmTestScope {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    $relative = $Path.Replace('\', '/')
    if ($relative -ceq 'tests/Pester/Unit/Module/TerraformInitUpgrade.Tests.ps1') {
        return @('authoring', 'repository-management')
    }
    if ($relative -clike 'tests/Pester/Unit/Workflows/*') {
        return 'workflows'
    }
    if ($relative -clike 'tests/Pester/Unit/RepositoryManagement/*' -or
        $relative -cmatch '^tests/Pester/Component/(BicepModuleIdentities|BicepTestTenantSync|ModuleCatalog|Repository|TerraformCodeowners)[^/]*\.Tests\.ps1$') {
        return 'repository-management'
    }
    if ($relative -cmatch '^tests/Pester/(Unit|Component|Integration)/') {
        return 'authoring'
    }
    throw [System.ArgumentException]::new("Not a Pester test path: '$Path'.")
}

function Get-AvmScopedTestFile {
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [ValidateSet('Unit', 'Component')] [string] $Tier,
        [ValidateSet('All', 'Authoring', 'RepositoryManagement')] [string] $Group = 'All'
    )

    $scope = if ($Group -eq 'RepositoryManagement') { 'repository-management' } else { 'authoring' }
    $files = @(Get-ChildItem -LiteralPath $Path -Filter '*.Tests.ps1' -File -Recurse |
            Where-Object {
                $relative = [System.IO.Path]::GetRelativePath($Path, $_.FullName).Replace('\', '/')
                $Group -eq 'All' -or $scope -in @(Get-AvmTestScope -Path "tests/Pester/$Tier/$relative")
            } | Sort-Object -Property FullName)
    if ($files.Count -eq 0) {
        throw [System.IO.InvalidDataException]::new("No $Tier test files found for group '$Group' in '$Path'.")
    }
    $files
}

function Get-AvmCiScope {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [AllowEmptyCollection()] [string[]] $ChangedPath = @(),
        [ValidateSet('auto', 'all', 'authoring', 'workflows', 'repository-management')]
        [string] $Scope = 'auto'
    )

    $selected = [ordered]@{
        authoring = $false
        workflows = $false
        'repository-management' = $false
    }
    if ($Scope -ne 'auto') {
        foreach ($name in @($selected.Keys)) {
            $selected[$name] = $Scope -eq 'all' -or $Scope -eq $name
        }
        return $selected
    }

    foreach ($changed in $ChangedPath) {
        if ([string]::IsNullOrWhiteSpace($changed)) {
            throw [System.ArgumentException]::new('Changed paths must not be empty.')
        }
        $path = $changed.Replace('\', '/')
        if ($path -cin @('build.ps1', '.gitattributes', '.gitignore', '.github/workflows/ci.yml',
                'scripts/Get-AvmCiScope.ps1', 'scripts/Install-AvmBuildPrerequisites.ps1', 'scripts/Import-AvmNetworkRetry.ps1') -or
            $path -clike 'build/*' -or $path -clike '.github/actions/*') {
            foreach ($name in @($selected.Keys)) { $selected[$name] = $true }
            continue
        }
        if ($path -cmatch '^tests/Pester/(Unit|Component|Integration)/.*\.Tests\.ps1$') {
            foreach ($name in @(Get-AvmTestScope -Path $path)) { $selected[$name] = $true }
            continue
        }
        if ($path -clike 'repository-management/*' -or $path -clike 'infra/*' -or
            $path -cin @('tests/fixtures/TestTenant.ps1', 'tests/fixtures/BicepIdentities.ps1',
                'tests/Pester/Helpers/ModuleCatalogFixture.ps1')) {
            $selected['repository-management'] = $true
            continue
        }
        if ($path -clike '.github/workflows/*' -or $path -ceq '.github/dependabot.yml') {
            $selected.workflows = $true
            if ($path -clike '.github/workflows/repository-management-*' -or
                $path -ceq '.github/workflows/module-metadata-sync.yml') {
                $selected['repository-management'] = $true
            }
            if ($path -ceq '.github/workflows/ci-authoring.yml') {
                $selected.authoring = $true
            }
            if ($path -ceq '.github/workflows/terraform-module.yml') {
                $selected.authoring = $true
                $selected['repository-management'] = $true
            }
            continue
        }
        if ($path -clike 'src/*') {
            $selected.authoring = $true
            $selected['repository-management'] = $true
            if ($path -cmatch '^src/Avm\.Authoring/(Avm\.Authoring\.ps[dm]1|Resources/(avm\.pins\.jsonc|network\.json))$' -or
                $path -cmatch '^src/Avm\.Authoring/(Private/(Tools|Network|Exceptions|Folders|Host|Output|Process|Config)|en-US)/') {
                $selected.workflows = $true
            }
            continue
        }
        if ($path -clike 'tests/Pester/Unit/Workflows/*') {
            $selected.workflows = $true
            continue
        }
        if ($path -clike 'tests/Pester/Unit/RepositoryManagement/*') {
            $selected['repository-management'] = $true
            continue
        }
        if ($path -clike 'scripts/*' -or $path -clike 'docs/reference/*' -or
            $path -clike 'tests/fixtures/*' -or $path -ceq 'tests/Pester/Helpers/BicepNativeWorkflow.ps1' -or
            $path -cin @('CHANGELOG.md', 'LICENSE')) {
            $selected.authoring = $true
            continue
        }
        if ($path -clike 'tests/*') {
            foreach ($name in @($selected.Keys)) { $selected[$name] = $true }
        }
    }
    $selected
}

function Get-AvmCiChangedPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $RepositoryRoot,
        [Parameter(Mandatory)] [ValidatePattern('^[0-9a-fA-F]{40}$')] [string] $Base,
        [Parameter(Mandatory)] [ValidatePattern('^[0-9a-fA-F]{40}$')] [string] $Head,
        [switch] $PullRequest
    )

    $module = Import-Module -Name (Join-Path $RepositoryRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -PassThru -ErrorAction Stop
    & $module {
        param($Root, $BaseCommit, $HeadCommit, $UseMergeBase)
        $git = (Get-Command -Name git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        if ($UseMergeBase) {
            $result = Invoke-AvmProcess -FilePath $git -WorkingDirectory $Root -TimeoutSec 60 `
                -ArgumentList @('merge-base', $BaseCommit, $HeadCommit)
            $BaseCommit = $result.StdOut.Trim()
            if ($BaseCommit -cnotmatch '^[0-9a-fA-F]{40}$') {
                throw [System.IO.InvalidDataException]::new('Git did not return one merge-base commit.')
            }
        }
        $result = Invoke-AvmProcess -FilePath $git -WorkingDirectory $Root -TimeoutSec 60 `
            -ArgumentList @('diff', '--no-ext-diff', '--no-textconv', '--name-only', '-z', '--no-renames', $BaseCommit, $HeadCommit, '--')
        $result.StdOut.Split([char]0, [System.StringSplitOptions]::RemoveEmptyEntries)
    } $RepositoryRoot $Base $Head ([bool]$PullRequest)
}
