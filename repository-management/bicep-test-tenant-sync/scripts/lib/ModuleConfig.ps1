function Get-AvmBicepModuleIdentityName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $ModulePath)

    return Get-AvmTestIdentityName -ModulePath $ModulePath
}

function Get-AvmBicepModulePath {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [string] $BicepRoot)

    $root = Get-Item -LiteralPath $BicepRoot -ErrorAction Stop
    if (-not $root.PSIsContainer -or ($root.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw [System.IO.InvalidDataException]::new('Bicep discovery requires a real source directory, not a link.')
    }
    $avmDirectory = Get-Item -LiteralPath (Join-Path $root.FullName 'avm') -ErrorAction Stop
    if (-not $avmDirectory.PSIsContainer -or ($avmDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw [System.IO.InvalidDataException]::new('The Bicep module inventory must not be a directory link.')
    }
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($kind in @('res', 'ptn', 'utl')) {
        $kindPath = Join-Path $avmDirectory.FullName $kind
        $kindDirectory = Get-Item -LiteralPath $kindPath -ErrorAction Stop
        if (-not $kindDirectory.PSIsContainer -or ($kindDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw [System.IO.InvalidDataException]::new('The Bicep source inventory is incomplete or contains directory links.')
        }
        foreach ($namespace in @(Get-ChildItem -LiteralPath $kindPath -Directory -Force -ErrorAction Stop)) {
            if ($namespace.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw [System.IO.InvalidDataException]::new('Bicep namespaces must not be directory links.')
            }
            foreach ($module in @(Get-ChildItem -LiteralPath $namespace.FullName -Directory -Force -ErrorAction Stop)) {
                if ($module.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw [System.IO.InvalidDataException]::new('Bicep modules must not be directory links.')
                }
                $main = Join-Path $module.FullName 'main.bicep'
                if (-not (Test-Path -LiteralPath $main -PathType Leaf)) { continue }
                if ((Get-Item -LiteralPath $main).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw [System.IO.InvalidDataException]::new('Bicep module entry points must not be links.')
                }
                $path = "avm/$kind/$($namespace.Name)/$($module.Name)"
                Assert-AvmBicepModulePath -Path $path
                $paths.Add($path)
            }
        }
    }
    if ($paths.Count -eq 0) {
        throw [System.IO.InvalidDataException]::new('Bicep identity discovery returned no source-backed root modules.')
    }
    return ,([string[]]@($paths | Sort-Object -CaseSensitive))
}

function Assert-AvmBicepSourceInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $BicepRoot,
        [Parameter(Mandatory)] [string[]] $MainModulePaths
    )

    $root = (Get-Item -LiteralPath $BicepRoot -ErrorAction Stop).FullName
    $gitRoot = Invoke-RepositoryGit -WorkingDirectory $root -Arguments @('rev-parse', '--show-toplevel') -ReadOnly
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not [string]::Equals([IO.Path]::GetFullPath($gitRoot), [IO.Path]::GetFullPath($root), $comparison)) {
        throw [System.InvalidOperationException]::new('Bicep source inventory must be the root of its own Git checkout.')
    }
    $head = Invoke-RepositoryGit -WorkingDirectory $root -Arguments @('rev-parse', 'HEAD') -ReadOnly
    $branch = Invoke-RepositoryGitHubApi -Endpoint 'repos/Azure/bicep-registry-modules/git/ref/heads/main'
    if ($head -cnotmatch '^[0-9a-f]{40}$' -or $branch.ref -cne 'refs/heads/main' -or
        $branch.object.type -cne 'commit' -or $branch.object.sha -cne $head) {
        throw [System.InvalidOperationException]::new('Bicep source inventory must match the current trusted main commit.')
    }

    $tree = Invoke-RepositoryGit -WorkingDirectory $root -Arguments @('ls-tree', '-r', '--name-only', 'HEAD', '--', 'avm') -ReadOnly
    $tracked = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($file in ($tree -split '\r?\n')) {
        $match = [regex]::Match($file, '\A(avm/(?:res|ptn|utl)/[^/]+/[^/]+)/main\.bicep\z')
        if ($match.Success) {
            $path = $match.Groups[1].Value
            Assert-AvmBicepModulePath -Path $path
            if (-not $tracked.Add($path)) {
                throw [System.InvalidOperationException]::new('Bicep Git inventory contains duplicate module paths.')
            }
        }
    }
    $discovered = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in (Get-AvmBicepModulePath -BicepRoot $root)) { $null = $discovered.Add($path) }
    if ($tracked.Count -eq 0 -or -not $tracked.SetEquals($discovered) -or
        -not $tracked.SetEquals([string[]]$MainModulePaths)) {
        throw [System.InvalidOperationException]::new('Bicep source inventory does not match the complete trusted Git tree.')
    }
}

function Get-AvmBicepOpenPullRequestModuleNumbers {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)] [string[]] $MainModulePaths,
        [Parameter(Mandatory)] [ValidatePattern('^[1-9][0-9]*$')] [string] $RepositoryId
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $mainModules = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $MainModulePaths) {
        Assert-AvmBicepModulePath -Path $path
        $null = $mainModules.Add($path)
    }

    $result = [ordered]@{}
    $seenPullRequests = [System.Collections.Generic.HashSet[int]]::new()
    $page = 1
    do {
        $pullRequests = @(Invoke-RepositoryGitHubApi -Endpoint "repos/Azure/bicep-registry-modules/pulls?state=open&per_page=100&page=$page")
        if ($pullRequests.Count -gt 100) {
            throw [System.IO.InvalidDataException]::new('GitHub returned an oversized open pull-request page.')
        }
        foreach ($pullRequest in $pullRequests) {
            if ($pullRequest -isnot [pscustomobject] -or
                ($pullRequest.number -isnot [int] -and $pullRequest.number -isnot [long]) -or
                $pullRequest.number -lt 1 -or -not $seenPullRequests.Add([int]$pullRequest.number) -or
                $pullRequest.state -cne 'open' -or
                $pullRequest.base -isnot [pscustomobject] -or
                $pullRequest.base.repo -isnot [pscustomobject] -or
                $pullRequest.head -isnot [pscustomobject] -or
                $pullRequest.base.repo.full_name -cne 'Azure/bicep-registry-modules' -or
                [string]$pullRequest.base.repo.id -cne $RepositoryId) {
                throw [System.IO.InvalidDataException]::new('GitHub returned an invalid or duplicate Bicep pull request.')
            }

            $headRepository = $pullRequest.head.repo
            if ($null -eq $headRepository -or
                $headRepository -isnot [pscustomobject] -or
                $headRepository.full_name -cne 'Azure/bicep-registry-modules' -or
                [string]$headRepository.id -cne $RepositoryId -or
                $headRepository.fork -ne $false) {
                continue
            }
            if ($pullRequest.head.sha -isnot [string] -or
                $pullRequest.head.sha -cnotmatch '^[0-9a-f]{40}$' -or
                $pullRequest.head.ref -isnot [string] -or
                [string]::IsNullOrWhiteSpace($pullRequest.head.ref) -or
                $pullRequest.base.sha -isnot [string] -or
                $pullRequest.base.sha -cnotmatch '^[0-9a-f]{40}$') {
                throw [System.IO.InvalidDataException]::new('GitHub returned incomplete Bicep pull-request metadata.')
            }

            $detailEndpoint = "repos/Azure/bicep-registry-modules/pulls/$($pullRequest.number)"
            $detailsBefore = Invoke-RepositoryGitHubApi -Endpoint $detailEndpoint
            $files = [System.Collections.Generic.List[object]]::new()
            $seenFiles = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            $filePage = 1
            do {
                $batch = @(Invoke-RepositoryGitHubApi -Endpoint "repos/Azure/bicep-registry-modules/pulls/$($pullRequest.number)/files?per_page=100&page=$filePage")
                if ($batch.Count -gt 100) {
                    throw [System.IO.InvalidDataException]::new('GitHub returned an oversized pull-request file page.')
                }
                foreach ($file in $batch) {
                    if ($file -isnot [pscustomobject] -or
                        $file.filename -isnot [string] -or
                        $file.status -isnot [string] -or
                        -not $seenFiles.Add($file.filename)) {
                        throw [System.IO.InvalidDataException]::new('GitHub returned a malformed or duplicate pull-request file.')
                    }
                    $files.Add($file)
                }
                $filePage++
            } while ($batch.Count -eq 100)

            $detailsAfter = Invoke-RepositoryGitHubApi -Endpoint $detailEndpoint
            foreach ($details in @($detailsBefore, $detailsAfter)) {
                if ($details -isnot [pscustomobject] -or
                    $details.number -ne $pullRequest.number -or $details.state -cne 'open' -or
                    $details.head -isnot [pscustomobject] -or
                    $details.base -isnot [pscustomobject] -or
                    $details.head.repo -isnot [pscustomobject] -or
                    $details.base.repo -isnot [pscustomobject] -or
                    [string]$details.head.repo.id -cne $RepositoryId -or
                    $details.head.repo.fork -ne $false -or
                    [string]$details.base.repo.id -cne $RepositoryId -or
                    $details.head.sha -cne $pullRequest.head.sha -or
                    $details.head.ref -cne $pullRequest.head.ref -or
                    $details.base.sha -cne $pullRequest.base.sha -or
                    ($details.changed_files -isnot [int] -and $details.changed_files -isnot [long]) -or
                    $details.changed_files -lt 0 -or $details.changed_files -ne $files.Count) {
                    throw [System.IO.InvalidDataException]::new('GitHub returned incomplete pull-request file list or changed pull-request metadata.')
                }
            }
            foreach ($file in $files) {
                $match = [regex]::Match(
                    $file.filename,
                    '\A(avm/(?:res|ptn|utl)/[a-z0-9]+(?:-[a-z0-9]+)*/[a-z0-9]+(?:-[a-z0-9]+)*)/main\.bicep\z'
                )
                if ($file.status -cne 'added' -or -not $match.Success) { continue }
                $modulePath = $match.Groups[1].Value
                if ($mainModules.Contains($modulePath)) { continue }
                if (-not $result.Contains($modulePath)) { $result[$modulePath] = [System.Collections.Generic.List[string]]::new() }
                $result[$modulePath].Add([string]$pullRequest.number)
            }
        }
        $page++
    } while ($pullRequests.Count -eq 100)

    foreach ($path in @($result.Keys)) {
        $result[$path] = @($result[$path] | Sort-Object { [int]$_ } -Unique)
    }
    return $result
}

function Resolve-AvmBicepModuleSettings {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $ModulePaths,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Configuration
    )

    if ($ModulePaths.Count -eq 0 -or
        $Configuration['moduleGroups'] -isnot [System.Collections.IList] -or $Configuration['moduleGroups'].Count -eq 0) {
        throw [System.ArgumentException]::new('Bicep configuration requires moduleGroups and a nonempty module inventory.')
    }
    $groups = @($Configuration['moduleGroups'])
    foreach ($entry in $groups) {
        $group = ConvertTo-AvmSettingDictionary -Value $entry
        if (@($group.Keys | Where-Object { $_ -cnotin @('name', 'order', 'modules', 'entraGroups', 'testTenant', 'existingIdentity') }).Count -gt 0) {
            throw [System.ArgumentException]::new('Bicep module groups contain unsupported settings.')
        }
        if ($group.Contains('existingIdentity')) {
            $null = ConvertTo-AvmExistingIdentitySetting -Value $group['existingIdentity']
        }
        foreach ($selector in @($group['modules'])) {
            if ($selector -ceq '*') { continue }
            Assert-AvmBicepModulePath -Path $selector
        }
    }
    $result = [ordered]@{}
    $identityNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($ModulePaths | Sort-Object -CaseSensitive)) {
        Assert-AvmBicepModulePath -Path $path
        if ($result.Contains($path) -or -not $identityNames.Add((Get-AvmBicepModuleIdentityName -ModulePath $path))) {
            throw [System.ArgumentException]::new('Bicep module paths and generated identity names must be unique.')
        }
        if ((Resolve-AvmGroupTestTenant -Groups $groups -SelectorProperty 'modules' -Item $path) -cne 'bami') {
            throw [System.ArgumentException]::new('Every Bicep module identity must select the BAMI test tenant.')
        }
        $result[$path] = Resolve-AvmGroupEntraGroups -Groups $groups -SelectorProperty 'modules' -Item $path
    }
    return $result
}

function Resolve-AvmBicepModuleJobWorkflowPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Configuration)

    $path = $Configuration['moduleJobWorkflowPath']
    if ($path -isnot [string] -or
        $path -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+/\.github/workflows/[A-Za-z0-9][A-Za-z0-9_.-]*\.ya?ml$') {
        throw [System.ArgumentException]::new(
            'Bicep configuration requires moduleJobWorkflowPath in owner/repository/.github/workflows/name.yml form without a Git ref.'
        )
    }
    return $path
}

function Resolve-AvmBicepModuleExistingIdentities {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $ModulePaths,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Configuration
    )

    $groups = @($Configuration['moduleGroups'])
    $result = [ordered]@{}
    foreach ($path in @($ModulePaths | Sort-Object -CaseSensitive)) {
        $identity = Resolve-AvmGroupExistingIdentity -Groups $groups -SelectorProperty 'modules' -Item $path
        if ($null -ne $identity) { $result[$path] = $identity }
    }
    return $result
}

function Resolve-AvmBicepSubscriptionVendingBillingScopes {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Configuration,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Values
    )

    $selector = 'avm/ptn/lz/sub-vending'
    $null = Resolve-AvmBicepModuleSettings -ModulePaths @($selector) -Configuration $Configuration
    $identities = Resolve-AvmBicepModuleExistingIdentities -ModulePaths @($selector) -Configuration $Configuration
    $result = [ordered]@{}
    if ($identities.Contains($selector)) {
        $identity = Resolve-AvmSubscriptionVendingIdentity -ExistingIdentity $identities[$selector] -Values $Values
        $result[$selector] = $identity['billing_scope']
    }
    return $result
}

function Resolve-AvmBicepExistingIdentityClientIds {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Configuration,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Values
    )

    $selector = 'avm/ptn/lz/sub-vending'
    $identities = Resolve-AvmBicepModuleExistingIdentities -ModulePaths @($selector) -Configuration $Configuration
    $result = [ordered]@{}
    if ($identities.Contains($selector)) {
        $result[$selector] = (Resolve-AvmSubscriptionVendingIdentity -ExistingIdentity $identities[$selector] -Values $Values)['client_id']
    }
    return $result
}

function ConvertTo-AvmBicepModuleBillingScopeJson {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.IDictionary] $BillingScopes
    )

    $selector = 'avm/ptn/lz/sub-vending'
    if ($BillingScopes.Count -gt 1 -or
        ($BillingScopes.Count -eq 1 -and -not $BillingScopes.Contains($selector))) {
        throw [System.ArgumentException]::new('Only the canonical subscription-vending root may receive a Bicep Registry billing scope.')
    }
    $result = [ordered]@{}
    if ($BillingScopes.Contains($selector)) {
        $scope = $BillingScopes[$selector]
        if ($scope -isnot [string] -or
            $scope -cnotmatch '^/providers/Microsoft\.Billing/billingAccounts/[A-Za-z0-9:_-]+/billingProfiles/[A-Za-z0-9_-]+/invoiceSections/[A-Za-z0-9_-]+$') {
            throw [System.ArgumentException]::new('The Bicep Registry billing scope must be an invoice-section resource ID.')
        }
        $result[$selector] = $scope
    }
    return ConvertTo-Json -InputObject $result -Compress -Depth 3
}

function Resolve-AvmBicepSubscriptionCleanupManagementGroups {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Configuration,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Values
    )

    $selector = 'avm/ptn/lz/sub-vending'
    $identities = Resolve-AvmBicepModuleExistingIdentities -ModulePaths @($selector) -Configuration $Configuration
    $result = [ordered]@{}
    if ($identities.Contains($selector)) {
        $identity = Resolve-AvmSubscriptionVendingIdentity -ExistingIdentity $identities[$selector] -Values $Values
        $result[$selector] = $identity['management_group_id']
    }
    return $result
}

function ConvertTo-AvmBicepModuleSubscriptionCleanupManagementGroupJson {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.IDictionary] $ManagementGroups
    )

    $selector = 'avm/ptn/lz/sub-vending'
    if ($ManagementGroups.Count -gt 1 -or
        ($ManagementGroups.Count -eq 1 -and -not $ManagementGroups.Contains($selector)) -or
        ($ManagementGroups.Contains($selector) -and (
            $ManagementGroups[$selector] -isnot [string] -or
            $ManagementGroups[$selector] -cnotmatch '^[A-Za-z0-9_().-]{1,90}$' -or
            $ManagementGroups[$selector] -in @('.', '..') -or $ManagementGroups[$selector].EndsWith('.')))) {
        throw [System.ArgumentException]::new('Only the canonical subscription-vending root may receive a valid Bicep Registry cleanup management group.')
    }
    return ConvertTo-Json -InputObject $ManagementGroups -Compress -Depth 3
}

function ConvertTo-AvmBicepIdentityMapping {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Identities,
        [Parameter(Mandatory)] [string[]] $ModulePaths,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Settings,
        [AllowEmptyCollection()] [System.Collections.IDictionary] $ExistingIdentities = @{},
        [switch] $Legacy
    )

    $settings = Get-AvmBamiSettings -Values $Settings
    if ($Identities.Count -ne $ModulePaths.Count -or
        @($Identities.Keys | Where-Object { $_ -cnotin $ModulePaths }).Count -gt 0) {
        throw [System.IO.InvalidDataException]::new('Applied identity output must cover exactly the discovered root modules.')
    }
    $mapping = [ordered]@{}
    foreach ($path in $ModulePaths) {
        $identity = $Identities[$path]
        $name = Get-AvmTestIdentityName -ModulePath $path -Legacy:$Legacy
        $expectedId = "/subscriptions/$($settings.TEST_BAMI_ADMIN_SUBSCRIPTION_ID)/resourceGroups/$($settings.TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME)/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$name"
        if (-not $Legacy -and $ExistingIdentities.Contains($path)) {
            $expectedId = $ExistingIdentities[$path]['resource_id']
        }
        if ($identity -isnot [System.Collections.IDictionary] -or $identity.Count -ne 3 -or
            $identity['tenant_id'] -ine $settings.TEST_BAMI_TENANT_ID -or
            $identity['identity_resource_id'] -ine $expectedId) {
            throw [System.IO.InvalidDataException]::new('Applied identity output does not belong to its expected module and BAMI resource group.')
        }
        $mapping[$path] = $identity['client_id']
    }
    $null = ConvertTo-AvmBicepModuleClientIdJson -ClientIds $mapping `
        -ForbiddenClientIds @($settings.TEST_BAMI_CONTROLLER_CLIENT_ID, $settings.TEST_BAMI_BICEP_CLIENT_ID)
    return $mapping
}

function Resolve-AvmBicepSyncRunContext {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $branchRun = $env:GITHUB_EVENT_NAME -ceq 'workflow_dispatch' -and
        $env:GITHUB_REF -cmatch '^refs/heads/[A-Za-z0-9][A-Za-z0-9._/-]*$'
    $mainRun = $env:GITHUB_REF -ceq 'refs/heads/main'
    $workflow = "Azure/azure-verified-modules-tools/.github/workflows/repository-management-bicep-sync.yml@$($env:GITHUB_REF)"
    if ($env:GITHUB_ACTIONS -cne 'true' -or $env:GITHUB_REPOSITORY -cne 'Azure/azure-verified-modules-tools' -or
        (-not $mainRun -and -not $branchRun) -or $env:GITHUB_WORKFLOW_REF -cne $workflow) {
        throw [System.InvalidOperationException]::new(
            'Bicep sync requires trusted Tools main or a manual trusted-repository branch run with matching workflow evidence.'
        )
    }
    return [pscustomobject]@{
        WorkflowRef = $workflow
        IsManualBranch = $branchRun -and -not $mainRun
    }
}

function Get-AvmBicepIdentityPublicationContext {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param()

    $run = Resolve-AvmBicepSyncRunContext
    if (
        $env:GITHUB_REPOSITORY_ID -cnotmatch '^[1-9][0-9]*$' -or
        $env:GITHUB_RUN_ID -cnotmatch '^[1-9][0-9]*$' -or $env:GITHUB_RUN_ATTEMPT -cnotmatch '^[1-9][0-9]*$' -or
        $env:GITHUB_SHA -cnotmatch '^[0-9a-f]{40}$') {
        throw [System.InvalidOperationException]::new('Identity rename publication requires the current trusted Bicep Sync run and attempt.')
    }
    return [ordered]@{
        repositoryId = $env:GITHUB_REPOSITORY_ID
        workflowRef = $run.WorkflowRef
        commit = $env:GITHUB_SHA
        runId = $env:GITHUB_RUN_ID
        runAttempt = $env:GITHUB_RUN_ATTEMPT
    }
}

function ConvertFrom-AvmBicepIdentityMigration {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Migration,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $ClientIds,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Settings
    )

    $context = Get-AvmBicepIdentityPublicationContext
    $hasRetirements = $Migration.Contains('retired')
    if (($Migration.Count -ne 4 -and -not ($hasRetirements -and $Migration.Count -eq 5)) -or
        @($Migration.Keys | Where-Object { $_ -cnotin @('schemaVersion', 'context', 'before', 'after', 'retired') }).Count -gt 0 -or
        ($Migration['schemaVersion'] -isnot [int] -and $Migration['schemaVersion'] -isnot [long]) -or
        $Migration['schemaVersion'] -ne 1 -or
        $Migration['context'] -isnot [System.Collections.IDictionary] -or $Migration['context'].Count -ne $context.Count -or
        $Migration['before'] -isnot [System.Collections.IDictionary] -or
        $Migration['after'] -isnot [System.Collections.IDictionary] -or $Migration['before'].Count -ne $Migration['after'].Count -or
        ($hasRetirements -and $Migration['retired'] -isnot [System.Collections.IDictionary])) {
        throw [System.IO.InvalidDataException]::new('Identity evidence must contain complete current-run rename and optional retirement records.')
    }
    foreach ($key in $context.Keys) {
        if ($Migration['context'][$key] -isnot [string] -or $Migration['context'][$key] -cne $context[$key]) {
            throw [System.InvalidOperationException]::new('Identity rename evidence belongs to a different run, attempt, repository or commit.')
        }
    }
    if ($hasRetirements) {
        $retiredClients = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($path in $Migration['retired'].Keys) {
            Assert-AvmBicepModulePath -Path $path
            $clientId = [guid]::Empty
            if ($Migration['retired'][$path] -isnot [string] -or
                -not [guid]::TryParseExact($Migration['retired'][$path], 'D', [ref]$clientId) -or
                $clientId -eq [guid]::Empty -or $clientId.ToString() -in @(
                    $Settings.TEST_BAMI_CONTROLLER_CLIENT_ID, $Settings.TEST_BAMI_BICEP_CLIENT_ID
                ) -or -not $retiredClients.Add($clientId.ToString()) -or $ClientIds.Contains($path)) {
                throw [System.InvalidOperationException]::new('Retirement evidence must identify unique removed module clients absent from the proposed mapping.')
            }
        }
    }
    if ($Migration['before'].Count -eq 0) { return [ordered]@{} }
    $paths = @($Migration['before'].Keys)
    $previous = ConvertTo-AvmBicepIdentityMapping -Identities $Migration['before'] -ModulePaths $paths -Settings $Settings -Legacy
    $current = ConvertTo-AvmBicepIdentityMapping -Identities $Migration['after'] -ModulePaths $paths -Settings $Settings
    foreach ($path in $paths) {
        if (-not $ClientIds.Contains($path) -or $ClientIds[$path] -ine $current[$path] -or
            $previous[$path] -in @($ClientIds.Values)) {
            throw [System.InvalidOperationException]::new('Identity rename evidence must bind each old module client to its new applied client, without stale or reused IDs.')
        }
    }
    return $previous
}

function Assert-AvmBicepModuleMappingExtension {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ExistingJson,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $ClientIds,
        [string[]] $ForbiddenClientIds = @(),
        [System.Collections.IDictionary] $IdentityMigration,
        [System.Collections.IDictionary] $Settings,
        [System.Collections.IDictionary] $ExistingIdentityClientIds = @{}
    )

    $existing = ConvertFrom-AvmTestTenantJson -Json $ExistingJson
    if ($existing -isnot [System.Collections.IDictionary]) {
        throw [System.IO.InvalidDataException]::new('The existing module client-ID mapping must be a JSON object.')
    }
    if ($existing.Count -gt 0) {
        $null = ConvertTo-AvmBicepModuleClientIdJson -ClientIds $existing -ForbiddenClientIds $ForbiddenClientIds
    }
    $previous = if ($null -ne $IdentityMigration) {
        ConvertFrom-AvmBicepIdentityMigration -Migration $IdentityMigration -ClientIds $ClientIds -Settings $Settings
    }
    else { @{} }
    $retired = if ($null -ne $IdentityMigration -and $IdentityMigration.Contains('retired')) {
        $IdentityMigration['retired']
    }
    else { @{} }
    foreach ($path in $retired.Keys) {
        if (-not $existing.Contains($path) -or $existing[$path] -ine $retired[$path]) {
            throw [System.InvalidOperationException]::new("Retirement evidence does not match the previously published client ID for '$path'.")
        }
    }
    foreach ($path in $existing.Keys) {
        if ((-not $ClientIds.Contains($path) -and
                (-not $retired.Contains($path) -or $retired[$path] -ine $existing[$path])) -or
            ($ClientIds.Contains($path) -and $ClientIds[$path] -ine $existing[$path] -and
            (-not $previous.Contains($path) -or $previous[$path] -ine $existing[$path]) -and
            -not ($ExistingIdentityClientIds.Contains($path) -and $ClientIds[$path] -ieq $ExistingIdentityClientIds[$path]))) {
            throw [System.InvalidOperationException]::new("The existing client ID for '$path' cannot be removed or retargeted by routine synchronization.")
        }
    }
}
