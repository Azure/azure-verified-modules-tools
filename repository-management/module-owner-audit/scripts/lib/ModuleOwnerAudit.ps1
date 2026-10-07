#Requires -Version 7.4

# AVM module owner audit: classifies root module owners in the published module catalog
# and optionally remediates (metadata.json pull requests, orphaned module issues).
# Dot-source after repository-sync RetryHelpers.ps1 and RepoTree.ps1, and reviewer-routing
# RepositoryFileAccess.ps1 and ModuleOwners.ps1.

#region Constants
$script:VerdictPriority = [ordered]@{
    WouldOrphan            = 1
    OrphanMissingIssue     = 2
    OwnerReduction         = 3
    OrphanIssueCanClose    = 4
    OrphanIssueNeedsReview = 5
    NeedsTeamJoin          = 6
    IssueHygiene           = 7
    OK                     = 8
}
$script:BicepRepository = 'Azure/bicep-registry-modules'
$script:AuditBranchPrefix = 'avm-owner-audit/'
$script:PrTitle = 'chore(metadata): remove inactive module owners [AVM owner audit]'
$script:OrphanLabels = @('Status: Module Orphaned :yellow_circle:', 'Needs: Module Owner :mega:', 'Needs: Triage :mag:')
$script:AvailableLabels = @('Status: Module Available :green_circle:', 'Status: Owners Identified :metal:')
$script:PrLabels = @('Type: AVM :a: :v: :m:', 'Needs: Core Team :genie:')
$script:PrReviewerTeams = @('azure-verified-modules-module-owners', 'azure-verified-modules-engineering-owners')
$script:IssueProjects = @(
    @{ Number = 529; Status = 'Orphaned' }
    @{ Number = 1011; Status = 'Needs: Triage' }
)
$script:ClosingRemarksPath = 'docs/static/includes/msg-final-reply-new-orph-mod-owners.md'
$script:ToolSource = '[`repository-management/module-owner-audit`](https://github.com/Azure/azure-verified-modules-tools/tree/main/repository-management/module-owner-audit) in Azure/azure-verified-modules-tools'
$script:DefaultBranchCache = @{}
$script:LogFile = $null
#endregion

#region GitHub CLI helpers
function Invoke-AvmOwnerAuditGh {
    <#
    .SYNOPSIS
    Run a gh command through the shared repository-sync retry wrapper. Never throws.
    .DESCRIPTION
    Transient failures (rate limits, TLS, resets and 5xx responses) are retried by Invoke-GitHubCliWithRetry.
    The shared wrapper's per-command narration is suppressed so the audit report stays readable.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)] [string[]] $Arguments,
        [int] $MaxRetries = 4
    )
    $retryOn = @(Get-GitHubTransientRetryPatterns) + @('HTTP 500', 'HTTP 502', 'HTTP 503', 'HTTP 504', 'secondary rate limit')
    $result = Invoke-GitHubCliWithRetry -commands @(@{ Arguments = $Arguments }) -literalArguments -returnOutput `
        -maxRetries $MaxRetries -retryDelayIncremental 5 -retryOn $retryOn 6>$null
    $result = @($result)[0]
    if ($result -and $result.success) {
        $text = if ($result.ContainsKey('output')) { [string]$result.output } else { '' }
        return [pscustomobject]@{ Success = $true; StatusCode = 200; Output = $text.Trim(); Error = '' }
    }
    $err = if ($result -and $result.ContainsKey('error')) { [string]$result.error } else { 'retry attempts exhausted' }
    $status = 0
    if ($err -match 'HTTP (\d{3})') {
        $status = [int]$Matches[1]
    }
    return [pscustomobject]@{ Success = $false; StatusCode = $status; Output = ''; Error = $err }
}
function Invoke-AvmOwnerAuditGhApi {
    <#
    .SYNOPSIS
    Call the GitHub REST API through gh. Returns the parsed JSON (or $null for empty bodies).
    Throws on failure unless the status code is listed in -AllowStatus, in which case $null is returned.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string] $Endpoint,
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')] [string] $Method = 'GET',
        [object] $Body,
        [switch] $Paginate,
        [int[]] $AllowStatus = @(),
        [string[]] $Headers = @()
    )
    $ghArgs = @('api', '--hostname', 'github.com', $Endpoint, '--method', $Method)
    foreach ($h in $Headers) { $ghArgs += @('-H', $h) }
    if ($Paginate) { $ghArgs += @('--paginate', '--jq', '.[]') }
    $bodyFile = $null
    try {
        if ($null -ne $Body) {
            $bodyFile = [System.IO.Path]::GetTempFileName()
            [System.IO.File]::WriteAllText($bodyFile, ($Body | ConvertTo-Json -Depth 20 -Compress), [System.Text.UTF8Encoding]::new($false))
            $ghArgs += @('--input', $bodyFile)
        }
        $r = Invoke-AvmOwnerAuditGh -Arguments $ghArgs
    }
    finally {
        if ($bodyFile) {
            Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false
        }
    }
    if (-not $r.Success) {
        if ($r.StatusCode -in $AllowStatus) { return $null }
        throw "GitHub API $Method $Endpoint failed (HTTP $($r.StatusCode)): $($r.Error) $($r.Output)"
    }
    if ([string]::IsNullOrWhiteSpace($r.Output)) { return $null }
    if ($Paginate) {
        return @($r.Output -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    }
    return $r.Output | ConvertFrom-Json
}

function Test-AvmOwnerAuditGhResource {
    <#
    .SYNOPSIS
    Returns $true for a 2xx response, $false for 404. Throws on any other failure.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param ([Parameter(Mandatory)] [string] $Endpoint)
    $r = Invoke-AvmOwnerAuditGh -Arguments @('api', '--hostname', 'github.com', $Endpoint, '--silent')
    if ($r.Success) { return $true }
    if ($r.StatusCode -eq 404) { return $false }
    throw "GitHub API GET $Endpoint failed (HTTP $($r.StatusCode)): $($r.Error)"
}

function Write-AvmAuditLog {
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [string] $Message, [switch] $Warn)
    $line = '{0:u} {1}' -f (Get-Date), $Message
    if ($script:LogFile) { Add-Content -Path $script:LogFile -Value $line -Encoding utf8 -WhatIf:$false -Confirm:$false }
    if ($Warn) { Write-Warning $Message } else { Write-Verbose $Message }
}
#endregion

#region Index and owner classification
function Get-AvmModuleIndex {
    <#
    .SYNOPSIS
    Load the published module catalog (latest on main, integrity-verified) or a local copy for testing.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ([string] $Path)
    if (-not $Path) {
        return Get-AvmReviewerRoutingCatalog
    }
    # Keys differing only in case exist (e.g. 'Microsoft.App/Jobs' vs 'Microsoft.App/jobs').
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 64
}
function ConvertTo-AvmModuleKind {
    param ([string] $ModuleType, [string] $Name)
    if ($ModuleType -in 'resource', 'pattern', 'utility') { return $ModuleType }
    switch -Regex ($Name) {
        '(^|/|-)res(/|-)' { return 'resource' }
        '(^|/|-)ptn(/|-)' { return 'pattern' }
        '(^|/|-)utl(/|-)' { return 'utility' }
    }
    return 'resource'
}

function Get-AvmRootModule {
    <#
    .SYNOPSIS
    Flatten the module index into root module objects (all statuses), plus a child-to-root lookup.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [hashtable] $Index)
    $entries = foreach ($typeKey in $Index.modules.Keys) {
        foreach ($eco in $Index.modules[$typeKey].Keys) {
            foreach ($e in $Index.modules[$typeKey][$eco]) { $e }
        }
    }
    $childCount = @{}
    $children = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $entries) {
        if ($e.parentModule) {
            $key = if ($e.ecosystem -eq 'terraform') { "terraform|$($e.repository)" } else { "bicep|$($e.repository)|$($e.familyModule)" }
            $childCount[$key] = 1 + [int]$childCount[$key]
            $children.Add($e)
        }
    }
    $roots = foreach ($e in $entries | Where-Object { -not $_.parentModule }) {
        $isTf = $e.ecosystem -eq 'terraform'
        $key = if ($isTf) { "terraform|$($e.repository)" } else { "bicep|$($e.repository)|$($e.familyModule)" }
        [pscustomobject]@{
            Ecosystem        = $e.ecosystem
            ModuleType       = ConvertTo-AvmModuleKind -ModuleType $e.moduleType -Name $e.moduleName
            ModuleStatus     = $e.moduleStatus
            ModuleName       = if ($isTf) { $e.moduleName } else { $e.modulePath }
            ModulePath       = $e.modulePath
            FamilyModule     = $e.familyModule
            Repository       = $e.repository
            RepoURL          = $e.repoURL
            MetadataPath     = if ($isTf) { 'metadata.json' } else { "$($e.modulePath)/metadata.json" }
            DisplayName      = $e.moduleDisplayName
            Owners           = @($e.owners | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Handle = $_.handle; Type = $_.type; DisplayName = $_.displayName } })
            ChildModuleCount = [int]$childCount[$key]
        }
    }
    return [pscustomobject]@{ Roots = @($roots); Children = $children.ToArray() }
}

function Test-AvmModuleFilter {
    param ([object] $Module, [string[]] $Filter, [string[]] $Ecosystem, [string[]] $ModuleType)
    if ($Ecosystem -and $Module.Ecosystem -notin $Ecosystem) { return $false }
    if ($ModuleType -and $Module.ModuleType -notin $ModuleType) { return $false }
    if (-not $Filter) { return $true }
    foreach ($f in $Filter) {
        if ($Module.ModuleName -like $f -or $Module.ModulePath -like $f -or $Module.Repository -like $f) { return $true }
    }
    return $false
}

function Get-AvmOwnerStatus {
    <#
    .SYNOPSIS
    Classify each unique owner handle. Returns a case-insensitive hashtable handle -> status object.
    Status: Active | ActiveNotInTeam | NotInOrg | AccountNotFound | Exempt | TeamOwner | TeamNotFound
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Owners,
        [Parameter(Mandatory)] [string] $Organization,
        [Parameter(Mandatory)] [string] $Team,
        [string[]] $Exempt = @(),
        [scriptblock] $TeamMemberProvider,
        [scriptblock] $MembershipProvider
    )
    if (-not $TeamMemberProvider) {
        $TeamMemberProvider = { param($org, $team) Invoke-AvmOwnerAuditGhApi -Endpoint "orgs/$org/teams/$team/members?per_page=100" -Paginate | ForEach-Object { $_.login } }
    }
    if (-not $MembershipProvider) {
        # Returns 'member', 'notMember' or 'noAccount' for users; 'team' or 'noTeam' for teams.
        $MembershipProvider = {
            param($org, $handle, $type)
            if ($type -eq 'team') {
                $slug = ($handle.TrimStart('@') -split '/')[-1]
                if (Test-AvmOwnerAuditGhResource -Endpoint "orgs/$org/teams/$slug") { return 'team' } else { return 'noTeam' }
            }
            if (Test-AvmOwnerAuditGhResource -Endpoint "orgs/$org/members/$handle") { return 'member' }
            if (Test-AvmOwnerAuditGhResource -Endpoint "users/$handle") { return 'notMember' }
            return 'noAccount'
        }
    }

    $teamMembers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($m in @(& $TeamMemberProvider $Organization $Team)) { if ($m) { [void]$teamMembers.Add($m) } }
    $exemptSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Exempt | Where-Object { $_ }), [System.StringComparer]::OrdinalIgnoreCase)

    $result = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    $unique = $Owners | Where-Object { $_.Handle } | Sort-Object -Property Handle -Unique
    foreach ($o in $unique) {
        if ($result.ContainsKey($o.Handle)) { continue }
        $handle = $o.Handle
        $isTeam = $o.Type -eq 'team' -or $handle -match '/'
        $inTeam = $teamMembers.Contains($handle)
        if ($exemptSet.Contains($handle)) {
            $status = 'Exempt'; $inOrg = $null
        }
        elseif ($isTeam) {
            $m = & $MembershipProvider $Organization $handle 'team'
            $status = if ($m -eq 'team') { 'TeamOwner' } else { 'TeamNotFound' }; $inOrg = $m -eq 'team'; $inTeam = $null
        }
        elseif ($inTeam) {
            $status = 'Active'; $inOrg = $true
        }
        else {
            $m = & $MembershipProvider $Organization $handle 'user'
            switch ($m) {
                'member' { $status = 'ActiveNotInTeam'; $inOrg = $true }
                'notMember' { $status = 'NotInOrg'; $inOrg = $false }
                default { $status = 'AccountNotFound'; $inOrg = $false }
            }
        }
        $result[$handle] = [pscustomobject]@{
            Handle      = $handle
            DisplayName = $o.DisplayName
            Status      = $status
            InAzureOrg  = $inOrg
            InAvmTeam   = $inTeam
            IsActive    = $status -in 'Active', 'ActiveNotInTeam', 'Exempt', 'TeamOwner'
        }
    }
    return $result
}
#endregion

#region Orphan issue matching
function ConvertTo-AvmNormalizedModuleToken {
    [CmdletBinding()]
    [OutputType([string])]
    param ([AllowEmptyString()] [string] $Token)
    if (-not $Token) { return '' }
    $t = $Token.Trim().ToLowerInvariant()
    $t = $t -replace '[`"''<>\*\(\)\[\]]', '' -replace '\\', '/'
    $t = $t -replace '^https?://github\.com/azure/bicep-registry-modules/(tree|blob)/[^/]+/', ''
    $t = $t -replace '^https?://github\.com/azure/terraform-azurerm-', ''
    $t = $t -replace '^https?://registry\.terraform\.io/modules/azure/', ''
    $t = $t -replace '^br/public:', '' -replace '^br:mcr\.microsoft\.com/bicep/', ''
    $t = $t -replace ':[0-9x]+\.[0-9x]+\.[0-9x]+.*$', ''
    $t = $t -replace '^terraform-azurerm-', ''
    $t = $t -replace '/(main\.bicep|metadata\.json|readme\.md)$', ''
    $t = $t -replace '/azurerm(/latest)?$', ''
    return $t.Trim().TrimEnd('/', '.', ',', ';', ':').Trim()
}

function Get-AvmModuleLookup {
    <#
    .SYNOPSIS
    Build 'ecosystem|normalized-name' -> list of @{ Root; Via } for all root modules and Bicep child modules.
    #>
    [CmdletBinding()]
    param ([object[]] $Roots, [object[]] $Children = @())
    $lookup = @{}
    $add = {
        param($key, $root, $via)
        if (-not $lookup.ContainsKey($key)) { $lookup[$key] = [System.Collections.Generic.List[object]]::new() }
        if (-not ($lookup[$key] | Where-Object { $_.Root -eq $root })) { $lookup[$key].Add([pscustomobject]@{ Root = $root; Via = $via }) }
    }
    $bicepRoots = @{}
    foreach ($r in $Roots) {
        if ($r.Ecosystem -eq 'terraform') {
            & $add "terraform|$($r.ModuleName.ToLowerInvariant())" $r 'root'
            $repoName = ($r.Repository -split '/')[-1].ToLowerInvariant() -replace '^terraform-azurerm-', ''
            & $add "terraform|$repoName" $r 'root'
        }
        else {
            & $add "bicep|$($r.ModuleName.ToLowerInvariant())" $r 'root'
            $bicepRoots["$($r.Repository)|$($r.FamilyModule)".ToLowerInvariant()] = $r
        }
    }
    foreach ($c in $Children | Where-Object { $_.ecosystem -eq 'bicep' }) {
        $root = $bicepRoots["$($c.repository)|$($c.familyModule)".ToLowerInvariant()]
        if ($root) { & $add "bicep|$($c.modulePath.ToLowerInvariant())" $root 'child' }
    }
    return $lookup
}

function Get-AvmIssueModuleCandidate {
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [object] $Issue)
    $title = [string]$Issue.title
    $body = [string]$Issue.body
    $raw = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($title, '`([^`]+)`')) { $raw.Add($m.Groups[1].Value) }
    if ($body -match '(?is)###\s*Module Name\s*\r?\n\s*([^\r\n]+)') { $raw.Add($Matches[1]) }
    $text = "$title`n$body"
    foreach ($m in [regex]::Matches($text, '(?i)https?://\S+')) { $raw.Add($m.Value) }
    foreach ($m in [regex]::Matches($text, '(?i)avm/(?:res|ptn|utl)/[a-z0-9][a-z0-9\-]*(?:/[a-z0-9][a-z0-9\-]*)*')) { $raw.Add($m.Value) }
    foreach ($m in [regex]::Matches($text, '(?i)(?:terraform-azurerm-)?avm-(?:res|ptn|utl)-[a-z0-9][a-z0-9\-]*[a-z0-9]')) { $raw.Add($m.Value) }
    # Title without the template prefix, as a last resort.
    $raw.Add(($title -replace '(?i)^\s*\[orphaned module\]\s*:\s*', ''))
    $language = $null
    if ($body -match '(?is)###\s*Bicep or Terraform\?\s*(Bicep|Terraform)\b') { $language = $Matches[1].ToLowerInvariant() }
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $tokens = foreach ($r in $raw) {
        $n = ConvertTo-AvmNormalizedModuleToken -Token $r
        if ($n -and $n -match '^avm[/-]' -and $seen.Add($n)) { $n }
    }
    return [pscustomobject]@{ Language = $language; Tokens = @($tokens) }
}

function Resolve-AvmOrphanIssueModule {
    <#
    .SYNOPSIS
    Match an orphan issue to a root module. Returns @{ Root; MatchedBy; Via } or $null.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [object] $Issue, [Parameter(Mandatory)] [hashtable] $Lookup)
    $cand = Get-AvmIssueModuleCandidate -Issue $Issue
    foreach ($n in $cand.Tokens) {
        $shapeEco = if ($n -match '^avm/') { 'bicep' } else { 'terraform' }
        $keys = [System.Collections.Generic.List[string]]::new()
        if ($cand.Language -and $cand.Language -ne $shapeEco -and $shapeEco -eq 'bicep') {
            # Bicep-style name in a Terraform issue: avm/res/network/private-link-service -> avm-res-network-privatelinkservice
            $seg = $n -split '/'
            if ($seg.Count -ge 4) { $keys.Add("terraform|avm-$($seg[1])-$($seg[2] -replace '-','')-$($seg[3] -replace '-','')") }
        }
        $keys.Add("$shapeEco|$n")
        if ($n.EndsWith('s')) { $keys.Add("$shapeEco|$($n.Substring(0, $n.Length - 1))") }
        foreach ($k in $keys) {
            $hits = $Lookup[$k]
            if ($hits -and $hits.Count -eq 1) {
                return [pscustomobject]@{ Root = $hits[0].Root; MatchedBy = $n; Via = $hits[0].Via }
            }
        }
    }
    return $null
}
#endregion

#region Audit
function New-AvmAuditRow {
    param (
        [object] $Module,
        [string] $Verdict,
        [string[]] $Flags = @(),
        [object[]] $OwnerDetails = @(),
        [int[]] $Issues = @(),
        [string] $Notes = ''
    )
    $inactive = @($OwnerDetails | Where-Object { -not $_.IsActive })
    $active = @($OwnerDetails | Where-Object { $_.IsActive })
    [pscustomobject]@{
        Priority         = $script:VerdictPriority[$Verdict]
        Verdict          = $Verdict
        Flags            = @($Flags | Select-Object -Unique)
        ModuleStatus     = $Module.ModuleStatus
        Ecosystem        = $Module.Ecosystem
        ModuleType       = $Module.ModuleType
        ModuleName       = $Module.ModuleName
        Repository       = $Module.Repository
        RepoURL          = $Module.RepoURL
        MetadataPath     = $Module.MetadataPath
        ChildModuleCount = $Module.ChildModuleCount
        OwnerDetails     = $OwnerDetails
        ActiveOwners     = @($active | ForEach-Object Handle)
        InactiveOwners   = @($inactive | ForEach-Object Handle)
        NotInTeamOwners  = @($OwnerDetails | Where-Object { $_.Status -eq 'ActiveNotInTeam' } | ForEach-Object Handle)
        ExemptOwners     = @($OwnerDetails | Where-Object { $_.Status -eq 'Exempt' } | ForEach-Object Handle)
        OpenOrphanIssues = @($Issues)
        Module           = $Module
        Notes            = $Notes
    }
}

function Get-AvmAuditResult {
    <#
    .SYNOPSIS
    Pure classification of root modules and orphan issues. All external data is passed in.
    .PARAMETER LiveOwnersProvider
    Scriptblock (module) returning the owners array from the live root metadata.json, used to confirm
    'OrphanIssueCanClose' candidates.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [object[]] $Roots,
        [object[]] $Children = @(),
        [Parameter(Mandatory)] [hashtable] $OwnerStatus,
        [object[]] $OpenIssues = @(),
        [string[]] $ModuleFilter,
        [string[]] $Ecosystem,
        [string[]] $ModuleType,
        [scriptblock] $LiveOwnersProvider
    )
    $scope = @{ Filter = $ModuleFilter; Ecosystem = $Ecosystem; ModuleType = $ModuleType }
    $filtered = $ModuleFilter -or ($Ecosystem -and @('bicep', 'terraform' | Where-Object { $_ -notin $Ecosystem })) -or ($ModuleType -and @('resource', 'pattern', 'utility' | Where-Object { $_ -notin $ModuleType }))
    $lookup = Get-AvmModuleLookup -Roots $Roots -Children $Children
    $issuesByModule = @{}
    $rows = [System.Collections.Generic.List[object]]::new()
    $hygiene = [System.Collections.Generic.List[object]]::new()

    foreach ($issue in $OpenIssues | Sort-Object -Property number) {
        $match = Resolve-AvmOrphanIssueModule -Issue $issue -Lookup $lookup
        if (-not $match) {
            if (-not $filtered) {
                $pseudo = [pscustomobject]@{ ModuleStatus = 'Unknown'; Ecosystem = ''; ModuleType = ''; ModuleName = [string]$issue.title; Repository = ''; RepoURL = ''; MetadataPath = ''; ChildModuleCount = 0 }
                $hygiene.Add((New-AvmAuditRow -Module $pseudo -Verdict 'IssueHygiene' -Flags 'UnmatchedIssue' -Issues $issue.number -Notes "Issue #$($issue.number) could not be matched to a module in the index."))
            }
            continue
        }
        $root = $match.Root
        if (-not (Test-AvmModuleFilter -Module $root @scope)) { continue }
        if ($root.ModuleStatus -in 'Deprecated', 'Proposed') {
            $hygiene.Add((New-AvmAuditRow -Module $root -Verdict 'IssueHygiene' -Flags "IssueFor$($root.ModuleStatus)Module" -Issues $issue.number -Notes "Open orphan issue #$($issue.number) relates to a $($root.ModuleStatus.ToLower()) module."))
            continue
        }
        $key = "$($root.Ecosystem)|$($root.ModuleName)"
        if (-not $issuesByModule.ContainsKey($key)) { $issuesByModule[$key] = [System.Collections.Generic.List[object]]::new() }
        $issuesByModule[$key].Add([pscustomobject]@{ Number = [int]$issue.number; Via = $match.Via })
    }

    foreach ($m in $Roots | Where-Object { $_.ModuleStatus -in 'Available', 'Orphaned', 'Proposed' }) {
        if (-not (Test-AvmModuleFilter -Module $m @scope)) { continue }
        $details = @($m.Owners | ForEach-Object {
                $s = $OwnerStatus[$_.Handle]
                if ($s) { $s } else { [pscustomobject]@{ Handle = $_.Handle; DisplayName = $_.DisplayName; Status = 'Unknown'; InAzureOrg = $null; InAvmTeam = $null; IsActive = $true } }
            })
        $key = "$($m.Ecosystem)|$($m.ModuleName)"
        $issueInfo = @(if ($issuesByModule.ContainsKey($key)) { $issuesByModule[$key] })
        $issueNumbers = @($issueInfo | ForEach-Object Number)
        $flags = [System.Collections.Generic.List[string]]::new()
        $notes = [System.Collections.Generic.List[string]]::new()
        if ($issueNumbers.Count -gt 0) { $flags.Add('OrphanIssueOpen') }
        if ($issueInfo | Where-Object Via -EQ 'child') { $notes.Add('Orphan issue references a child module; mapped to its root module.') }
        if ($issueNumbers.Count -gt 1) {
            $flags.Add('DuplicateOrphanIssues')
            $hygiene.Add((New-AvmAuditRow -Module $m -Verdict 'IssueHygiene' -Flags 'DuplicateOrphanIssues' -Issues $issueNumbers -Notes "Multiple open orphan issues for the same module: $(($issueNumbers | ForEach-Object { "#$_" }) -join ', ')."))
        }
        $active = @($details | Where-Object IsActive)
        $inactive = @($details | Where-Object { -not $_.IsActive })
        $notInTeam = @($details | Where-Object Status -EQ 'ActiveNotInTeam')
        if ($notInTeam.Count -gt 0) { $flags.Add('NeedsTeamJoin') }

        if ($details.Count -eq 0) {
            if ($m.ModuleStatus -eq 'Proposed') {
                $verdict = 'OK'; $flags.Add('NoOwners')
            }
            elseif ($issueNumbers.Count -eq 0) {
                $verdict = 'OrphanMissingIssue'
            }
            else {
                $verdict = 'OK'; $flags.Add('OrphanTracked')
            }
        }
        elseif ($active.Count -eq 0) {
            $verdict = 'WouldOrphan'
        }
        elseif ($inactive.Count -gt 0) {
            $verdict = 'OwnerReduction'
        }
        elseif ($issueNumbers.Count -gt 0 -and $m.ModuleStatus -ne 'Proposed') {
            $allInTeam = -not ($details | Where-Object { $_.Status -notin 'Active', 'TeamOwner' })
            if (-not $allInTeam) {
                $verdict = 'OrphanIssueNeedsReview'
                $notes.Add('Not every owner is an active member of the AVM module contributors team.')
            }
            elseif ($m.ModuleStatus -ne 'Available') {
                $verdict = 'OrphanIssueNeedsReview'
                $notes.Add("Module status in the index is '$($m.ModuleStatus)'.")
            }
            else {
                $live = @(if ($LiveOwnersProvider) { & $LiveOwnersProvider $m } else { 'unchecked' })
                if ($live.Count -gt 0) {
                    $verdict = 'OrphanIssueCanClose'
                }
                else {
                    $verdict = 'OrphanIssueNeedsReview'
                    $notes.Add('Live root metadata.json has no owners.')
                }
            }
        }
        elseif ($notInTeam.Count -gt 0) {
            $verdict = 'NeedsTeamJoin'
        }
        else {
            $verdict = 'OK'
        }
        $rows.Add((New-AvmAuditRow -Module $m -Verdict $verdict -Flags $flags -OwnerDetails $details -Issues $issueNumbers -Notes ($notes -join ' ')))
    }
    $all = @($rows) + @($hygiene)
    return @($all | Sort-Object -Property @{ Expression = { if ($_.ModuleStatus -eq 'Proposed') { 1 } else { 0 } } }, Priority, Ecosystem, ModuleName)
}
#endregion

#region Reporting
function Format-AvmOwnerList {
    param ([object[]] $Owners)
  (@($Owners) | ForEach-Object { "$($_.Handle) ($($_.Status))" }) -join ', '
}

function Get-AvmOwnerAction {
    param ([object] $Row, [object] $Owner)
    switch ($Owner.Status) {
        'ActiveNotInTeam' { return 'Keep - ask to join AVM module contributors team' }
        'Exempt' { return 'Keep (exempt)' }
        { -not $Owner.IsActive } {
            if ($Row.ModuleStatus -eq 'Proposed') { return 'Remove (proposed module - report only)' }
            return 'Remove'
        }
        default { return 'Keep' }
    }
}

function Export-AvmAuditCsv {
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [object[]] $Results, [Parameter(Mandatory)] [string] $OutputPath, [Parameter(Mandatory)] [string] $Stamp)
    $modulesCsv = Join-Path $OutputPath "avm-owner-audit-$Stamp-modules.csv"
    $ownersCsv = Join-Path $OutputPath "avm-owner-audit-$Stamp-owners.csv"
    $Results | ForEach-Object {
        [pscustomobject]@{
            Priority         = $_.Priority
            Verdict          = $_.Verdict
            Flags            = $_.Flags -join '; '
            ModuleStatus     = $_.ModuleStatus
            Ecosystem        = $_.Ecosystem
            ModuleType       = $_.ModuleType
            ModuleName       = $_.ModuleName
            Repository       = $_.Repository
            RepoURL          = $_.RepoURL
            OwnerCount       = @($_.OwnerDetails).Count
            ActiveOwnerCount = @($_.ActiveOwners).Count
            InactiveOwners   = $_.InactiveOwners -join '; '
            NotInTeamOwners  = $_.NotInTeamOwners -join '; '
            ExemptOwners     = $_.ExemptOwners -join '; '
            RemainingOwners  = $_.ActiveOwners -join '; '
            OpenOrphanIssues = ($_.OpenOrphanIssues | ForEach-Object { "#$_" }) -join '; '
            ChildModuleCount = $_.ChildModuleCount
            Notes            = $_.Notes
        }
    } | Export-Csv -Path $modulesCsv -NoTypeInformation -Encoding utf8 -WhatIf:$false -Confirm:$false
    $ownerRows = foreach ($r in $Results | Where-Object Verdict -NE 'IssueHygiene') {
        foreach ($o in $r.OwnerDetails) {
            [pscustomobject]@{
                Priority         = $r.Priority
                ModuleVerdict    = $r.Verdict
                ModuleStatus     = $r.ModuleStatus
                Ecosystem        = $r.Ecosystem
                ModuleType       = $r.ModuleType
                ModuleName       = $r.ModuleName
                Repository       = $r.Repository
                OwnerHandle      = $o.Handle
                OwnerDisplayName = $o.DisplayName
                OwnerStatus      = $o.Status
                InAzureOrg       = $o.InAzureOrg
                InAvmTeam        = $o.InAvmTeam
                Action           = Get-AvmOwnerAction -Row $r -Owner $o
            }
        }
    }
    @($ownerRows) | Export-Csv -Path $ownersCsv -NoTypeInformation -Encoding utf8 -WhatIf:$false -Confirm:$false
    return [pscustomobject]@{ ModulesCsv = $modulesCsv; OwnersCsv = $ownersCsv }
}

function Get-AvmSegmentLabel {
    param ([string] $Ecosystem, [string] $ModuleType)
    $eco = switch ($Ecosystem) { 'bicep' { 'Bicep' } 'terraform' { 'Terraform' } default { 'Unmatched' } }
    if (-not $ModuleType) { return $eco }
    return "$eco / $((Get-Culture).TextInfo.ToTitleCase($ModuleType))"
}

function Get-AvmSegmentOrder {
    param ([object] $Row)
    $e = switch ($Row.Ecosystem) { 'bicep' { 0 } 'terraform' { 1 } default { 2 } }
    $t = switch ($Row.ModuleType) { 'resource' { 0 } 'pattern' { 1 } 'utility' { 2 } default { 3 } }
    return $e * 10 + $t
}

function Format-AvmReportLine {
    param ([object] $Row, [switch] $ShowVerdict)
    $line = "    $($Row.ModuleName)"
    if ($ShowVerdict) { $line += "  $($Row.Verdict)" }
    if ($Row.Flags -contains 'NoOwners') { $line += ' (no owners)' }
    if ($Row.InactiveOwners) { $line += "  remove: $(Format-AvmOwnerList ($Row.OwnerDetails | Where-Object { -not $_.IsActive }))" }
    if ($Row.ActiveOwners -and $Row.Verdict -in 'OwnerReduction', 'OrphanIssueCanClose', 'OrphanIssueNeedsReview') { $line += "  keep: $($Row.ActiveOwners -join ', ')" }
    if ($Row.NotInTeamOwners) { $line += "  needs team join: $($Row.NotInTeamOwners -join ', ')" }
    if ($Row.OpenOrphanIssues) { $line += "  issues: $(($Row.OpenOrphanIssues | ForEach-Object { "#$_" }) -join ', ')" }
    if ($Row.Notes) { $line += "  ($($Row.Notes))" }
    return $line
}

function Write-AvmGroupedRow {
    param ([object[]] $Rows, [switch] $ShowVerdict)
    foreach ($g in $Rows | Group-Object { Get-AvmSegmentLabel -Ecosystem $_.Ecosystem -ModuleType $_.ModuleType } | Sort-Object { Get-AvmSegmentOrder -Row $_.Group[0] }) {
        Write-Host "  -- $($g.Name) ($($g.Count))" -ForegroundColor DarkCyan
        foreach ($r in $g.Group | Sort-Object Priority, ModuleName) { Write-Host (Format-AvmReportLine -Row $r -ShowVerdict:$ShowVerdict) }
    }
}

function Write-AvmAuditReport {
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Results, [Parameter(Mandatory)] [hashtable] $OwnerStatus, [string] $Source)
    $colors = @{ WouldOrphan = 'Red'; OrphanMissingIssue = 'Red'; OwnerReduction = 'Yellow'; OrphanIssueCanClose = 'Green'; OrphanIssueNeedsReview = 'Yellow'; NeedsTeamJoin = 'Cyan'; IssueHygiene = 'Magenta'; OK = 'Gray' }
    $main = @($Results | Where-Object ModuleStatus -NE 'Proposed')
    $proposed = @($Results | Where-Object ModuleStatus -EQ 'Proposed')
    $modules = @($Results | Where-Object Verdict -NE 'IssueHygiene')

    Write-Host ''
    Write-Host "AVM module owner audit - $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor White
    if ($Source) { Write-Host "Index: $Source" -ForegroundColor DarkGray }
    $byStatus = ($modules | Group-Object ModuleStatus | Sort-Object Name | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', '
    Write-Host "Root modules audited: $($modules.Count) ($byStatus)"
    $ownerSummary = ($OwnerStatus.Values | Group-Object Status | Sort-Object Name | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ' | '
    Write-Host "Unique owners checked: $($OwnerStatus.Count) ($ownerSummary)"

    # Verdict matrix (excluding proposed modules), one column per language / module type present.
    $segments = foreach ($e in 'bicep', 'terraform') {
        foreach ($t in 'resource', 'pattern', 'utility') {
            if ($main | Where-Object { $_.Ecosystem -eq $e -and $_.ModuleType -eq $t }) {
                [pscustomobject]@{ Ecosystem = $e; ModuleType = $t; Header = "$(if ($e -eq 'bicep') { 'Bicep' } else { 'TF' })-$($t.Substring(0, 3).Replace('uti', 'Utl').Replace('res', 'Res').Replace('pat', 'Ptn'))" }
            }
        }
    }
    $segments = @($segments)
    Write-Host ''
    Write-Host (('{0,-24}' -f 'Verdict') + (($segments | ForEach-Object { '{0,10}' -f $_.Header }) -join '') + ('{0,8}' -f 'Total')) -ForegroundColor White
    foreach ($v in $script:VerdictPriority.Keys) {
        $rows = @($main | Where-Object Verdict -EQ $v)
        $cells = ($segments | ForEach-Object { $s = $_; '{0,10}' -f @($rows | Where-Object { $_.Ecosystem -eq $s.Ecosystem -and $_.ModuleType -eq $s.ModuleType }).Count }) -join ''
        Write-Host (('{0,-24}' -f $v) + $cells + ('{0,8}' -f $rows.Count)) -ForegroundColor $(if ($rows.Count -and $v -ne 'OK') { $colors[$v] } else { 'Gray' })
    }

    foreach ($v in $script:VerdictPriority.Keys | Where-Object { $_ -ne 'OK' }) {
        $items = @($main | Where-Object Verdict -EQ $v)
        if (-not $items) { continue }
        Write-Host ''
        Write-Host "== $v ($($items.Count)) ==" -ForegroundColor $colors[$v]
        Write-AvmGroupedRow -Rows $items
    }

    $teamJoin = @($main | Where-Object { $_.Verdict -ne 'IssueHygiene' } | ForEach-Object { $row = $_; $_.OwnerDetails | Where-Object Status -EQ 'ActiveNotInTeam' | ForEach-Object { [pscustomobject]@{ Owner = $_; Row = $row } } })
    if ($teamJoin) {
        Write-Host ''
        Write-Host "== Owners to contact: active FTEs not in the AVM module contributors team ($(@($teamJoin | ForEach-Object { $_.Owner.Handle } | Select-Object -Unique).Count)) ==" -ForegroundColor $colors.NeedsTeamJoin
        Write-Host '   Ask them to join the AVM Module Contributors access package: https://aka.ms/avm/id/access-package/module-contributor' -ForegroundColor DarkGray
        foreach ($g in $teamJoin | Group-Object { $_.Owner.Handle } | Sort-Object Name) {
            $display = $g.Group[0].Owner.DisplayName
            $mods = ($g.Group | Sort-Object { Get-AvmSegmentOrder -Row $_.Row }, { $_.Row.ModuleName } | ForEach-Object { "$($_.Row.ModuleName) [$(Get-AvmSegmentLabel -Ecosystem $_.Row.Ecosystem -ModuleType $_.Row.ModuleType)]" }) -join ', '
            Write-Host "  $($g.Name)$(if ($display) { " ($display)" }) - $($g.Count) module(s): $mods"
        }
    }

    $proposedFlagged = @($proposed | Where-Object { $_.Verdict -ne 'OK' -or $_.Flags -contains 'NoOwners' })
    if ($proposedFlagged) {
        Write-Host ''
        Write-Host "== Proposed modules (report only) ($($proposedFlagged.Count)) ==" -ForegroundColor DarkYellow
        Write-AvmGroupedRow -Rows $proposedFlagged -ShowVerdict
    }
}#endregion

#region Metadata editing
function Set-AvmOwnersInMetadataText {
    <#
    .SYNOPSIS
    Replace only the root "owners" array in metadata.json text, preserving all other formatting.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory)] [string] $Text, [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Owners)
    $rx = [regex]'("owners"\s*:\s*)\[(?<inner>[^\]]*)\]'
    $matches_ = $rx.Matches($Text)
    if ($matches_.Count -ne 1) { throw "Expected exactly one 'owners' array in metadata.json, found $($matches_.Count)." }
    $m = $matches_[0]
    $inner = $m.Groups['inner'].Value
    if ($Owners.Count -eq 0) {
        $array = '[]'
    }
    elseif ($inner -match '\r?\n') {
        $nl = if ($Text -match '\r\n') { "`r`n" } else { "`n" }
        $lineStart = $Text.LastIndexOf("`n", [Math]::Max(0, $m.Index - 1)) + 1
        $keyIndent = ([regex]::Match($Text.Substring($lineStart), '^[ \t]*')).Value
        $itemIndent = if ($inner -match '\r?\n([ \t]+)"') { $Matches[1] } else { "$keyIndent  " }
        $closeIndent = if ($inner -match '\r?\n([ \t]*)$') { $Matches[1] } else { $keyIndent }
        $array = '[' + $nl + (($Owners | ForEach-Object { "$itemIndent`"$_`"" }) -join ",$nl") + $nl + $closeIndent + ']'
    }
    else {
        $array = '[' + (($Owners | ForEach-Object { "`"$_`"" }) -join ', ') + ']'
    }
    $newText = $Text.Substring(0, $m.Index) + $m.Groups[1].Value + $array + $Text.Substring($m.Index + $m.Length)
    $parsedOwners = @(($newText | ConvertFrom-Json -AsHashtable).owners)
    if ((@($Owners) -join "`n") -cne (@($parsedOwners) -join "`n")) {
        throw 'Owners array edit verification failed.'
    }
    return $newText
}

function Get-AvmDefaultBranch {
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory)] [string] $Repository)
    if (-not $script:DefaultBranchCache.ContainsKey($Repository)) {
        $script:DefaultBranchCache[$Repository] = [string](Invoke-AvmOwnerAuditGhApi -Endpoint "repos/$Repository").default_branch
    }
    return $script:DefaultBranchCache[$Repository]
}

function Get-AvmRemoteFile {
    <#
    .SYNOPSIS
    Read a file on the repository's default branch (or -Ref) with the shared integrity-verified reader.
    Returns @{ Text; Sha; Owners } or $null when it does not exist. Owners is $null if the JSON cannot be parsed.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param ([Parameter(Mandatory)] [string] $Repository, [Parameter(Mandatory)] [string] $Path, [string] $Ref)
    if (-not $Ref) {
        $Ref = Get-AvmDefaultBranch -Repository $Repository
    }
    $file = Get-AvmRepositoryFileAtRef -Repository $Repository -Path $Path -Ref $Ref -AllowMissing
    if (-not $file) {
        return $null
    }
    $owners = $null
    try {
        $json = $file.Content | ConvertFrom-Json -AsHashtable -Depth 64
        $owners = if ($json.ContainsKey('owners')) { @($json.owners | Where-Object { $_ }) } else { @() }
    }
    catch {
        Write-Verbose "Could not parse $Repository/$Path : $_"
    }
    return [pscustomobject]@{ Text = $file.Content; Sha = $file.Sha; Owners = $owners }
}

function Test-AvmMetadataText {
    <#
    .SYNOPSIS
    Validate metadata.json text with Avm.Authoring. Returns $null when valid, otherwise the error messages.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [string] $Text, [Parameter(Mandatory)] [string] $Ecosystem, [Parameter(Mandatory)] [string] $ModuleType)
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) "avm-owner-audit-validate-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false -Confirm:$false | Out-Null
    try {
        [System.IO.File]::WriteAllText((Join-Path $dir 'metadata.json'), $Text, [System.Text.UTF8Encoding]::new($false))
        # The -Apply preflight enforces the minimum module version once; skip the per-call gallery lookup.
        $r = Test-AvmModuleMetadata -Path $dir -Ecosystem $Ecosystem -ModuleType $ModuleType -SkipModuleVersionCheck -WarningAction SilentlyContinue
        if ($r.Status -eq 'pass') { return $null }
        return (@($r.Issues) | ForEach-Object { "$($_.Code): $($_.Message)" }) -join ' | '
    }
    finally {
        Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false
    }
}
#endregion

#region Apply helpers
$script:LabelCache = @{}
$script:ProjectCache = @{}

function Get-AvmExistingLabel {
    <#
    .SYNOPSIS
    Return only the label names that exist in the repository (labels are never created).
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [string] $Repository, [string[]] $Name)
    if (-not $script:LabelCache.ContainsKey($Repository)) {
        $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($l in @(Invoke-AvmOwnerAuditGhApi -Endpoint "repos/$Repository/labels?per_page=100" -Paginate)) { [void]$set.Add($l.name) }
        $script:LabelCache[$Repository] = $set
    }
    $existing = @($Name | Where-Object { $script:LabelCache[$Repository].Contains($_) })
    foreach ($missing in $Name | Where-Object { $_ -notin $existing }) { Write-AvmAuditLog "Label '$missing' does not exist in $Repository; skipped." -Warn }
    return $existing
}

function New-AvmOrphanIssueBody {
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory)] [object] $Row, [Parameter(Mandatory)] [string] $Details)
    $language = if ($Row.Ecosystem -eq 'terraform') { 'Terraform' } else { 'Bicep' }
    $classification = switch ($Row.ModuleType) { 'pattern' { 'Pattern Module' } 'utility' { 'Utility Module' } default { 'Resource Module' } }
    return @"
### Bicep or Terraform?

$language

### Module Classification?

$classification

### Module Name

$($Row.ModuleName)

### Module Details

$Details

### Do you want to be the new owner of this module?

No

### Newly proposed Module Owner's GitHub Username (handle)

_No response_

### (Optional) Newly proposed Secondary Module Owner's GitHub Username (handle)

_No response_
"@
}

function Get-AvmOrphanIssueDetail {
    param ([object] $Row, [string[]] $RemovedOwners, [string] $Organization = 'Azure')
    $stamp = Get-Date -Format 'yyyy-MM-dd'
    $intro = "Raised automatically on $stamp by the AVM module owner audit ($script:ToolSource)."
    if ($RemovedOwners) {
        $list = ($Row.OwnerDetails | Where-Object { $_.Handle -in $RemovedOwners } | ForEach-Object {
                $why = if ($_.Status -eq 'AccountNotFound') { 'GitHub account not found' } else { "not a member of the ``$Organization`` GitHub organization" }
                "- ``$($_.Handle)`` ($why)"
            }) -join "`n"
        return "$intro`n`nNone of the module's listed owners is still an active Microsoft FTE (membership of the ``$Organization`` GitHub organization is required for AVM module owners). The following owners are being removed from the module's root ``metadata.json``, which leaves the module without owners:`n`n$list"
    }
    return "$intro`n`nThe module's root ``metadata.json`` has no owners and no open orphaned module issue was found."
}

function Add-AvmIssueToProject {
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [string] $IssueUrl, [Parameter(Mandatory)] [int] $ProjectNumber, [Parameter(Mandatory)] [string] $StatusName, [string] $Organization = 'Azure')
    if (-not $script:ProjectCache.ContainsKey($ProjectNumber)) {
        $view = Invoke-AvmOwnerAuditGh -Arguments @('project', 'view', "$ProjectNumber", '--owner', $Organization, '--format', 'json')
        $fields = Invoke-AvmOwnerAuditGh -Arguments @('project', 'field-list', "$ProjectNumber", '--owner', $Organization, '--format', 'json', '--limit', '100')
        if (-not ($view.Success -and $fields.Success)) { throw "Unable to read project $ProjectNumber : $($view.Error) $($fields.Error)" }
        $script:ProjectCache[$ProjectNumber] = @{ Id = ($view.Output | ConvertFrom-Json).id; Fields = ($fields.Output | ConvertFrom-Json).fields }
    }
    $project = $script:ProjectCache[$ProjectNumber]
    $add = Invoke-AvmOwnerAuditGh -Arguments @('project', 'item-add', "$ProjectNumber", '--owner', $Organization, '--url', $IssueUrl, '--format', 'json')
    if (-not $add.Success) { throw "Unable to add $IssueUrl to project $ProjectNumber : $($add.Error)" }
    $itemId = ($add.Output | ConvertFrom-Json).id
    $field = $project.Fields | Where-Object { $_.name -eq 'Status' } | Select-Object -First 1
    $option = $field.options | Where-Object { $_.name -eq $StatusName } | Select-Object -First 1
    if (-not $option) { Write-AvmAuditLog "Project $ProjectNumber has no Status option '$StatusName'; item added without status." -Warn; return }
    $edit = Invoke-AvmOwnerAuditGh -Arguments @('project', 'item-edit', '--id', $itemId, '--project-id', $project.Id, '--field-id', $field.id, '--single-select-option-id', $option.id)
    if (-not $edit.Success) { throw "Unable to set Status '$StatusName' on project $ProjectNumber item: $($edit.Error)" }
}

function New-AvmOrphanIssue {
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [object] $Row, [Parameter(Mandatory)] [string] $Repository, [string[]] $RemovedOwners, [switch] $SkipProjects, [string] $Organization = 'Azure')
    $body = New-AvmOrphanIssueBody -Row $Row -Details (Get-AvmOrphanIssueDetail -Row $Row -RemovedOwners $RemovedOwners -Organization $Organization)
    $payload = @{
        title  = "[Orphaned Module]: ``$($Row.ModuleName)``"
        body   = $body
        labels = @(Get-AvmExistingLabel -Repository $Repository -Name $script:OrphanLabels)
    }
    $issue = Invoke-AvmOwnerAuditGhApi -Endpoint "repos/$Repository/issues" -Method POST -Body $payload
    Write-AvmAuditLog "Created orphan issue $Repository#$($issue.number) for $($Row.ModuleName): $($issue.html_url)"
    if ($SkipProjects) {
        Write-AvmAuditLog "Project assignment skipped for $($issue.html_url) (issue repository override)."
    }
    else {
        foreach ($p in $script:IssueProjects) {
            try { Add-AvmIssueToProject -IssueUrl $issue.html_url -ProjectNumber $p.Number -StatusName $p.Status -Organization $Organization }
            catch { Write-AvmAuditLog "Failed to add $($issue.html_url) to project $($p.Number): $_" -Warn }
        }
    }
    return [pscustomobject]@{ Number = [int]$issue.number; Url = $issue.html_url }
}

function Get-AvmOpenAuditPullRequest {
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [string] $Repository)
    $pulls = @(Invoke-AvmOwnerAuditGhApi -Endpoint "repos/$Repository/pulls?state=open&per_page=100" -Paginate)
    return @($pulls | Where-Object {
            $_.head.ref -like "$($script:AuditBranchPrefix)*" -and $null -ne $_.head.repo -and $_.head.repo.full_name -eq $Repository
        }) | Select-Object -First 1
}

function New-AvmAuditBranch {
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [string] $Repository)
    $base = Get-AvmDefaultBranch -Repository $Repository
    $sha = (Invoke-AvmOwnerAuditGhApi -Endpoint "repos/$Repository/git/ref/heads/$base").object.sha
    $name = "$($script:AuditBranchPrefix)$(Get-Date -Format 'yyyyMMdd')"
    if (Invoke-AvmOwnerAuditGhApi -Endpoint "repos/$Repository/git/ref/heads/$name" -AllowStatus 404) { $name += "-$(Get-Date -Format 'HHmmss')" }
    Invoke-AvmOwnerAuditGhApi -Endpoint "repos/$Repository/git/refs" -Method POST -Body @{ ref = "refs/heads/$name"; sha = $sha } | Out-Null
    Write-AvmAuditLog "Created branch ${Repository}:$name from $base ($sha)."
    return [pscustomobject]@{ Name = $name; Base = $base }
}

function Set-AvmRemoteFile {
    [CmdletBinding()]
    param ([string] $Repository, [string] $Path, [string] $Branch, [string] $Text, [string] $Message)
    $existing = Invoke-AvmOwnerAuditGhApi -Endpoint "repos/$Repository/contents/$Path`?ref=$([uri]::EscapeDataString($Branch))" -AllowStatus 404
    $body = @{ message = $Message; branch = $Branch; content = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($Text)) }
    if ($existing) { $body.sha = $existing.sha }
    Invoke-AvmOwnerAuditGhApi -Endpoint "repos/$Repository/contents/$Path" -Method PUT -Body $body | Out-Null
}

function New-AvmPullRequestBody {
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory)] [object[]] $Changes, [string] $Organization = 'Azure')
    $mention = { param($handles) (@($handles) | ForEach-Object { "@$_" }) -join ', ' }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('## Description').AppendLine()
    [void]$sb.AppendLine("Automated [AVM](https://aka.ms/avm) module owner audit ($script:ToolSource).").AppendLine()
    [void]$sb.AppendLine("The owners below are no longer members of the ``$Organization`` GitHub organization (required for AVM module owners, who must be Microsoft FTEs), or their GitHub account no longer exists. They are removed from the module's root ``metadata.json``.").AppendLine()
    $orphans = @($Changes | Where-Object Orphan)
    $reductions = @($Changes | Where-Object { -not $_.Orphan })
    if ($orphans) {
        [void]$sb.AppendLine('### Modules becoming orphaned (no active owners remain)').AppendLine()
        [void]$sb.AppendLine('| Module | Removed owner(s) | Orphan issue |').AppendLine('| --- | --- | --- |')
        foreach ($c in $orphans) { [void]$sb.AppendLine("| ``$($c.Row.ModuleName)`` | $(& $mention $c.Removed) | $(if ($c.IssueRef) { $c.IssueRef } else { 'n/a' }) |") }
        [void]$sb.AppendLine()
    }
    if ($reductions) {
        [void]$sb.AppendLine('### Owner reductions (at least one active owner remains)').AppendLine()
        [void]$sb.AppendLine('| Module | Removed owner(s) | Remaining owner(s) |').AppendLine('| --- | --- | --- |')
        foreach ($c in $reductions) {
            $keep = (@($c.Remaining) | ForEach-Object { '`' + $_ + '`' }) -join ', '
            [void]$sb.AppendLine("| ``$($c.Row.ModuleName)`` | $(& $mention $c.Removed) | $keep |")
        }
        [void]$sb.AppendLine()
    }
    [void]$sb.AppendLine('> [!NOTE]')
    [void]$sb.AppendLine("> If you were removed but are still a Microsoft FTE, link your GitHub account to join the ``$Organization`` GitHub organization and request the [AVM Module Contributors access package](https://aka.ms/avm/id/access-package/module-contributor) (see the [contribution prerequisites](https://azure.github.io/Azure-Verified-Modules/contributing/terraform/prerequisites/)), then ask the AVM core team to re-add you as an owner.").AppendLine()
    [void]$sb.AppendLine('This is a metadata-only ownership change following the [module metadata process](https://azure.github.io/Azure-Verified-Modules/contributing/module-metadata/). No version change or module release is required; the module index updates automatically at the next scheduled catalog sync.').AppendLine()
    [void]$sb.AppendLine('## Type of Change').AppendLine()
    [void]$sb.AppendLine('- [x] Metadata-only ownership change (root `metadata.json` `owners` array only)')
    return $sb.ToString()
}

function New-AvmAuditPullRequest {
    [CmdletBinding()]
    param ([string] $Repository, [object] $Branch, [object[]] $Changes, [string] $Organization = 'Azure')
    $pr = Invoke-AvmOwnerAuditGhApi -Endpoint "repos/$Repository/pulls" -Method POST -Body @{
        title = $script:PrTitle; head = $Branch.Name; base = $Branch.Base; body = (New-AvmPullRequestBody -Changes $Changes -Organization $Organization)
    }
    Write-AvmAuditLog "Opened PR $($pr.html_url)"
    $labels = @(Get-AvmExistingLabel -Repository $Repository -Name $script:PrLabels)
    if ($labels) {
        try { Invoke-AvmOwnerAuditGhApi -Endpoint "repos/$Repository/issues/$($pr.number)/labels" -Method POST -Body @{ labels = $labels } | Out-Null }
        catch { Write-AvmAuditLog "Failed to add labels to $($pr.html_url): $_" -Warn }
    }
    foreach ($team in $script:PrReviewerTeams) {
        try { Invoke-AvmOwnerAuditGhApi -Endpoint "repos/$Repository/pulls/$($pr.number)/requested_reviewers" -Method POST -Body @{ team_reviewers = @($team) } | Out-Null }
        catch { Write-AvmAuditLog "Failed to request review from @$Organization/$team on $($pr.html_url): $_" -Warn }
    }
    return $pr
}

function Get-AvmClosingRemark {
    param ([string[]] $Owners, [string] $IssueRepository = 'Azure/Azure-Verified-Modules')
    $template = $null
    try {
        $file = Get-AvmRepositoryFileAtRef -Repository $IssueRepository -Path $script:ClosingRemarksPath -Ref (Get-AvmDefaultBranch -Repository $IssueRepository) -AllowMissing
        if ($file) {
            $template = $file.Content
        }
    }
    catch {
        Write-Verbose "Falling back to built-in closing remarks: $_"
    }
    if (-not $template) {
        $template = @'
- [x] Module Contributors access package approved for all incoming module owners.
- [x] Root metadata ownership change approved by either metadata code-owner team, merged, and linked to this issue through the [metadata review process](https://azure.github.io/Azure-Verified-Modules/contributing/module-metadata/).

The module index is regenerated automatically every four hours, so the ownership change should appear shortly.

Thank you for your work @replace_with_author! I'm closing this issue now.
'@
    }
    return $template.Replace('@replace_with_author', ((@($Owners) | ForEach-Object { "@$_" }) -join ', '))
}

function Close-AvmOrphanIssue {
    [CmdletBinding()]
    param ([string] $Repository, [int] $Number, [string[]] $Owners)
    foreach ($l in $script:OrphanLabels | Where-Object { $_ -ne 'Needs: Triage :mag:' }) {
        Invoke-AvmOwnerAuditGhApi -Endpoint "repos/$Repository/issues/$Number/labels/$([uri]::EscapeDataString($l))" -Method DELETE -AllowStatus 404 | Out-Null
    }
    $add = @(Get-AvmExistingLabel -Repository $Repository -Name $script:AvailableLabels)
    if ($add) { Invoke-AvmOwnerAuditGhApi -Endpoint "repos/$Repository/issues/$Number/labels" -Method POST -Body @{ labels = $add } | Out-Null }
    Invoke-AvmOwnerAuditGhApi -Endpoint "repos/$Repository/issues/$Number/comments" -Method POST -Body @{ body = (Get-AvmClosingRemark -Owners $Owners -IssueRepository $Repository) } | Out-Null
    Invoke-AvmOwnerAuditGhApi -Endpoint "repos/$Repository/issues/$Number" -Method PATCH -Body @{ state = 'closed'; state_reason = 'completed' } | Out-Null
    Write-AvmAuditLog "Closed orphan issue $Repository#$Number."
}
#endregion

#region Apply orchestration
function Invoke-AvmAuditApply {
    <#
    .SYNOPSIS
    Apply the remediation for audit results. Each module change is gated by ShouldProcess (-WhatIf)
    and, unless -Force, a ShouldContinue confirmation.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param (
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Results,
        [Parameter(Mandatory)] [System.Management.Automation.PSCmdlet] $Cmdlet,
        [string] $Organization = 'Azure',
        [string] $IssueRepository = 'Azure/Azure-Verified-Modules',
        [string] $IssueRepoOverride,
        [string] $TargetRepoOverride,
        [int] $MaxChanges = [int]::MaxValue,
        [switch] $CloseResolvedIssues,
        [switch] $Force
    )
    $approve = {
        param($target, $action)
        $Cmdlet.ShouldProcess($target, $action) -and ($Force -or $Cmdlet.ShouldContinue("$action ($target)", 'AVM module owner audit'))
    }
    $issueRepo = if ($IssueRepoOverride) { $IssueRepoOverride } else { $IssueRepository }
    $skipProjects = [bool]$IssueRepoOverride
    $changes = 0
    $summary = [System.Collections.Generic.List[object]]::new()
    $note = { param($action, $target, $result, $url) $summary.Add([pscustomobject]@{ Action = $action; Target = $target; Result = $result; Url = $url }) }
    $main = @($Results | Where-Object { $_.ModuleStatus -ne 'Proposed' })

    # 1. Remove inactive owners: one PR per repository (Bicep batch PR, one PR per Terraform module repo).
    $edits = @($main | Where-Object { $_.Verdict -in 'WouldOrphan', 'OwnerReduction' -and $_.ModuleStatus -eq 'Available' })
    foreach ($g in $edits | Group-Object Repository | Sort-Object { ($_.Group | Measure-Object Priority -Minimum).Minimum }, Name) {
        if ($changes -ge $MaxChanges) { break }
        $sourceRepo = $g.Name
        $targetRepo = if ($TargetRepoOverride) { $TargetRepoOverride } else { $sourceRepo }
        $openPr = Get-AvmOpenAuditPullRequest -Repository $targetRepo
        if ($openPr) {
            Write-AvmAuditLog "Skipping $sourceRepo : audit PR already open ($($openPr.html_url))." -Warn
            & $note 'MetadataPR' $sourceRepo 'Skipped - audit PR pending' $openPr.html_url
            continue
        }
        $pending = [System.Collections.Generic.List[object]]::new()
        foreach ($row in $g.Group | Sort-Object Priority, ModuleName) {
            if ($changes -ge $MaxChanges) { break }
            $action = "Remove inactive owner(s) [$($row.InactiveOwners -join ', ')] from root metadata.json in $targetRepo"
            if ($row.Verdict -eq 'WouldOrphan') { $action += ' and raise an orphaned module issue' }
            if (-not (& $approve "$($row.Ecosystem) module $($row.ModuleName)" $action)) { continue }
            try {
                $live = Get-AvmRemoteFile -Repository $sourceRepo -Path $row.MetadataPath
                if (-not $live -or $null -eq $live.Owners) { Write-AvmAuditLog "No readable root metadata.json for $($row.ModuleName) at $sourceRepo/$($row.MetadataPath); skipped." -Warn; continue }
                $removeSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$row.InactiveOwners, [System.StringComparer]::OrdinalIgnoreCase)
                $removed = @($live.Owners | Where-Object { $removeSet.Contains($_) })
                if (-not $removed) { Write-AvmAuditLog "$($row.ModuleName): inactive owners already removed in live metadata.json; skipped."; & $note 'MetadataEdit' $row.ModuleName 'Skipped - already up to date' ''; continue }
                $remaining = @($live.Owners | Where-Object { -not $removeSet.Contains($_) })
                $newText = Set-AvmOwnersInMetadataText -Text $live.Text -Owners $remaining
                $validation = Test-AvmMetadataText -Text $newText -Ecosystem $row.Ecosystem -ModuleType $row.ModuleType
                if ($validation) { Write-AvmAuditLog "$($row.ModuleName): Avm.Authoring validation failed, skipped. $validation" -Warn; & $note 'MetadataEdit' $row.ModuleName 'Failed - validation' ''; continue }
                $targetPath = if ($TargetRepoOverride -and $row.Ecosystem -eq 'terraform') { "terraform/$(($sourceRepo -split '/')[-1])/metadata.json" } else { $row.MetadataPath }
                $pending.Add([pscustomobject]@{ Row = $row; NewText = $newText; TargetPath = $targetPath; Removed = $removed; Remaining = $remaining; Orphan = ($remaining.Count -eq 0); IssueNumber = $null; IssueRef = $null })
                $changes++
            }
            catch {
                Write-AvmAuditLog "$($row.ModuleName): $_" -Warn
                & $note 'MetadataEdit' $row.ModuleName "Failed - $_" ''
            }
        }
        if ($pending.Count -eq 0) { continue }

        foreach ($c in $pending | Where-Object Orphan) {
            $existing = @($c.Row.OpenOrphanIssues) | Select-Object -First 1
            if ($existing -and -not $IssueRepoOverride) {
                $c.IssueNumber = $existing; $c.IssueRef = "$IssueRepository#$existing"
                Write-AvmAuditLog "Reusing open orphan issue $($c.IssueRef) for $($c.Row.ModuleName)."
                & $note 'OrphanIssue' $c.Row.ModuleName 'Reused existing' "https://github.com/$IssueRepository/issues/$existing"
                continue
            }
            try {
                $issue = New-AvmOrphanIssue -Row $c.Row -Repository $issueRepo -RemovedOwners $c.Removed -SkipProjects:$skipProjects -Organization $Organization
                $c.IssueNumber = $issue.Number; $c.IssueRef = "$issueRepo#$($issue.Number)"
                & $note 'OrphanIssue' $c.Row.ModuleName 'Created' $issue.Url
            }
            catch {
                Write-AvmAuditLog "Failed to create orphan issue for $($c.Row.ModuleName): $_" -Warn
                & $note 'OrphanIssue' $c.Row.ModuleName "Failed - $_" ''
            }
        }

        try {
            $branch = New-AvmAuditBranch -Repository $targetRepo
            foreach ($c in $pending) {
                Set-AvmRemoteFile -Repository $targetRepo -Path $c.TargetPath -Branch $branch.Name -Text $c.NewText -Message "chore(metadata): remove inactive owners from $($c.Row.ModuleName) [AVM owner audit]"
            }
            $pr = New-AvmAuditPullRequest -Repository $targetRepo -Branch $branch -Changes $pending -Organization $Organization
            & $note 'MetadataPR' $sourceRepo "Opened ($($pending.Count) module(s))" $pr.html_url
            foreach ($c in $pending | Where-Object IssueNumber) {
                $repoOfIssue = ($c.IssueRef -split '#')[0]
                try { Invoke-AvmOwnerAuditGhApi -Endpoint "repos/$repoOfIssue/issues/$($c.IssueNumber)/comments" -Method POST -Body @{ body = "Metadata pull request removing the inactive owner(s): $($pr.html_url)" } | Out-Null }
                catch { Write-AvmAuditLog "Failed to comment on $($c.IssueRef): $_" -Warn }
            }
        }
        catch {
            Write-AvmAuditLog "Failed to open PR for $sourceRepo : $_" -Warn
            & $note 'MetadataPR' $sourceRepo "Failed - $_" ''
        }
    }

    # 2. Orphaned modules without an open orphan issue.
    foreach ($row in $main | Where-Object Verdict -EQ 'OrphanMissingIssue') {
        if ($changes -ge $MaxChanges) { break }
        if (-not (& $approve "$($row.Ecosystem) module $($row.ModuleName)" "Create orphaned module issue in $issueRepo")) { continue }
        try {
            $live = Get-AvmRemoteFile -Repository $row.Repository -Path $row.MetadataPath
            if ($live -and @($live.Owners).Count -gt 0) {
                Write-AvmAuditLog "$($row.ModuleName): live metadata.json has owners again ($($live.Owners -join ', ')); no issue created."
                & $note 'OrphanIssue' $row.ModuleName 'Skipped - owners present in live metadata' ''
                continue
            }
            $issue = New-AvmOrphanIssue -Row $row -Repository $issueRepo -SkipProjects:$skipProjects -Organization $Organization
            & $note 'OrphanIssue' $row.ModuleName 'Created' $issue.Url
            $changes++
        }
        catch {
            Write-AvmAuditLog "Failed to create orphan issue for $($row.ModuleName): $_" -Warn
            & $note 'OrphanIssue' $row.ModuleName "Failed - $_" ''
        }
    }

    # 3. Close orphan issues for modules that are owned again (opt-in).
    if ($CloseResolvedIssues) {
        foreach ($row in $main | Where-Object Verdict -EQ 'OrphanIssueCanClose') {
            foreach ($n in $row.OpenOrphanIssues) {
                if ($changes -ge $MaxChanges) { break }
                if ($IssueRepoOverride) { Write-AvmAuditLog "Not closing $IssueRepository#$n (issue repository override in use)." -Warn; continue }
                if (-not (& $approve "$IssueRepository#$n ($($row.ModuleName))" "Close orphan issue; module is owned by $($row.ActiveOwners -join ', ')")) { continue }
                try {
                    Close-AvmOrphanIssue -Repository $IssueRepository -Number $n -Owners $row.ActiveOwners
                    & $note 'CloseIssue' $row.ModuleName 'Closed' "https://github.com/$IssueRepository/issues/$n"
                    $changes++
                }
                catch {
                    Write-AvmAuditLog "Failed to close $IssueRepository#$n : $_" -Warn
                    & $note 'CloseIssue' $row.ModuleName "Failed - $_" "https://github.com/$IssueRepository/issues/$n"
                }
            }
        }
    }
    return $summary.ToArray()
}

function Write-AvmDryRunPlan {
    param ([object[]] $Results)
    foreach ($r in $Results | Where-Object { $_.ModuleStatus -ne 'Proposed' }) {
        switch ($r.Verdict) {
            'WouldOrphan' { Write-AvmAuditLog "WOULD remove [$($r.InactiveOwners -join ', ')] from $($r.Repository)/$($r.MetadataPath) and raise/reuse an orphan issue." }
            'OwnerReduction' { Write-AvmAuditLog "WOULD remove [$($r.InactiveOwners -join ', ')] from $($r.Repository)/$($r.MetadataPath)." }
            'OrphanMissingIssue' { Write-AvmAuditLog "WOULD create an orphan issue for $($r.ModuleName)." }
            'OrphanIssueCanClose' { Write-AvmAuditLog "WOULD close orphan issue(s) $(($r.OpenOrphanIssues | ForEach-Object { "#$_" }) -join ', ') for $($r.ModuleName) (with -CloseResolvedIssues)." }
        }
    }
}
#endregion

#region Entry point
function Invoke-AvmModuleOwnerAudit {
    <#
    .SYNOPSIS
    Audit AVM root module owners against Azure GitHub organization membership and optionally remediate.
    .DESCRIPTION
    See repository-management/module-owner-audit/README.md. Dry run (report only) unless -Apply is set.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject[]])]
    param (
        [string] $IndexPath,
        [string] $Organization = 'Azure',
        [string] $ContributorTeam = 'azure-verified-modules-module-contributors',
        [string] $IssueRepository = 'Azure/Azure-Verified-Modules',
        [string[]] $ExemptHandles = @(),
        [string] $ExemptHandlesPath,
        [string[]] $ModuleFilter,
        [ValidateSet('bicep', 'terraform')]
        [string[]] $Ecosystem = @('bicep', 'terraform'),
        [ValidateSet('resource', 'pattern', 'utility')]
        [string[]] $ModuleType = @('resource', 'pattern', 'utility'),
        [string] $OutputPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'avm-owner-audit'),
        [switch] $Apply,
        [switch] $CloseResolvedIssues,
        [switch] $Force,
        [ValidateRange(1, [int]::MaxValue)]
        [int] $MaxChanges = [int]::MaxValue,
        [string] $TargetRepoOverride,
        [string] $IssueRepoOverride,
        [version] $MinimumAvmAuthoringVersion = '0.20.0',
        [switch] $PassThru
    )
    begin {
        Set-StrictMode -Version 3.0
        $ErrorActionPreference = 'Stop'
    }
    process {
        if ([bool]$TargetRepoOverride -ne [bool]$IssueRepoOverride) {
            throw [System.ArgumentException]::new('-TargetRepoOverride and -IssueRepoOverride must be used together.')
        }
        if ($CloseResolvedIssues -and -not $Apply) {
            Write-Warning '-CloseResolvedIssues has no effect without -Apply.'
        }

        New-Item -ItemType Directory -Path $OutputPath -Force -WhatIf:$false -Confirm:$false | Out-Null
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $script:LogFile = Join-Path $OutputPath "avm-owner-audit-$stamp.log"
        Write-AvmAuditLog "Run started. Mode: $(if ($Apply) { 'Apply' } else { 'DryRun' }). Filter: $($ModuleFilter -join ', '). Ecosystem: $($Ecosystem -join ', '). ModuleType: $($ModuleType -join ', ')"

        # Preflight
        $avm = Get-Module -Name Avm.Authoring | Select-Object -First 1
        if (-not $avm) {
            throw [System.InvalidOperationException]::new('Import Avm.Authoring before running the module owner audit.')
        }
        $login = (Invoke-AvmOwnerAuditGhApi -Endpoint 'user').login
        if (-not (Test-AvmOwnerAuditGhResource -Endpoint "orgs/$Organization/members/$login")) {
            throw [System.InvalidOperationException]::new("The authenticated GitHub user '$login' must be a member of the '$Organization' organization to read private memberships.")
        }
        if ($Apply) {
            # 0.0.0 is the unreleased version stamped in this repository's source manifest.
            if ($avm.Version -lt $MinimumAvmAuthoringVersion -and $avm.Version -ne [version]'0.0.0') {
                throw [System.InvalidOperationException]::new("Avm.Authoring >= $MinimumAvmAuthoringVersion is required for -Apply (loaded: $($avm.Version)). Run Update-AvmAuthoring or import the module from this repository's src folder.")
            }
            $headers = Invoke-AvmOwnerAuditGh -Arguments @('api', '--hostname', 'github.com', 'user', '--include')
            if ($headers.Output -match '(?im)^X-Oauth-Scopes:\s*(.*)$') {
                $scopes = $Matches[1].Split(',').Trim()
                $missing = @('repo', 'read:org', 'project' | Where-Object { $_ -notin $scopes -and -not ($_ -eq 'read:org' -and 'admin:org' -in $scopes) })
                if ($missing) {
                    throw [System.InvalidOperationException]::new("gh token is missing scope(s): $($missing -join ', '). Run: gh auth refresh -s $($missing -join ',')")
                }
            }
        }

        $exempt = @($ExemptHandles)
        if ($ExemptHandlesPath) {
            $exempt += @(Get-Content -LiteralPath $ExemptHandlesPath | ForEach-Object { ($_ -replace '#.*$', '').Trim() } | Where-Object { $_ })
        }

        Write-Host 'Reading the published module catalog...' -ForegroundColor DarkGray
        $index = Get-AvmModuleIndex -Path $IndexPath
        $flat = Get-AvmRootModule -Index $index
        $inScope = @($flat.Roots | Where-Object { $_.ModuleStatus -in 'Available', 'Orphaned', 'Proposed' -and (Test-AvmModuleFilter -Module $_ -Filter $ModuleFilter -Ecosystem $Ecosystem -ModuleType $ModuleType) })
        $owners = @($inScope | ForEach-Object { $_.Owners })
        Write-Host "Checking $(@($owners | ForEach-Object Handle | Sort-Object -Unique).Count) unique owners across $($inScope.Count) root modules..." -ForegroundColor DarkGray
        $ownerStatus = Get-AvmOwnerStatus -Owners $owners -Organization $Organization -Team $ContributorTeam -Exempt $exempt

        Write-Host 'Reading open orphaned module issues...' -ForegroundColor DarkGray
        $labelQuery = [uri]::EscapeDataString($script:OrphanLabels[0])
        $openIssues = @(Invoke-AvmOwnerAuditGhApi -Endpoint "repos/$IssueRepository/issues?state=open&labels=$labelQuery&per_page=100" -Paginate |
                Where-Object { -not $_.PSObject.Properties['pull_request'] })

        $liveOwners = {
            param($m)
            $f = Get-AvmRemoteFile -Repository $m.Repository -Path $m.MetadataPath
            if ($f -and $null -ne $f.Owners) { @($f.Owners) } else { @() }
        }
        $results = @(Get-AvmAuditResult -Roots $flat.Roots -Children $flat.Children -OwnerStatus $ownerStatus -OpenIssues $openIssues `
                -ModuleFilter $ModuleFilter -Ecosystem $Ecosystem -ModuleType $ModuleType -LiveOwnersProvider $liveOwners)

        Write-AvmAuditReport -Results $results -OwnerStatus $ownerStatus -Source $(if ($IndexPath) { $IndexPath } else { "$($script:AvmReviewerRoutingCatalogRepository)/$($script:AvmReviewerRoutingCatalogPath)@$($script:AvmReviewerRoutingCatalogRef)" })
        $csv = Export-AvmAuditCsv -Results $results -OutputPath $OutputPath -Stamp $stamp

        if ($Apply) {
            Write-Host ''
            Write-Host '== Applying changes ==' -ForegroundColor White
            $applyParams = @{
                Results             = $results
                Cmdlet              = $PSCmdlet
                Organization        = $Organization
                IssueRepository     = $IssueRepository
                IssueRepoOverride   = $IssueRepoOverride
                TargetRepoOverride  = $TargetRepoOverride
                MaxChanges          = $MaxChanges
                CloseResolvedIssues = $CloseResolvedIssues
                Force               = ($Force -or $ConfirmPreference -eq 'None')
            }
            $summary = @(Invoke-AvmAuditApply @applyParams)
            if ($summary) {
                $summary | Format-Table -AutoSize -Wrap | Out-String -Width 250 | Write-Host
            }
            else {
                Write-Host '  No changes made.'
            }
        }
        else {
            Write-AvmDryRunPlan -Results $results
            Write-Host ''
            Write-Host 'Dry run: no changes made. Re-run with -Apply (optionally -WhatIf, -Ecosystem, -ModuleType, -ModuleFilter, -MaxChanges, -CloseResolvedIssues) to remediate.' -ForegroundColor DarkGray
        }
        Write-Host ''
        Write-Host "Modules CSV: $($csv.ModulesCsv)"
        Write-Host "Owners CSV:  $($csv.OwnersCsv)"
        Write-Host "Run log:     $($script:LogFile)"
        Write-AvmAuditLog 'Run finished.'
        if ($PassThru) {
            return $results
        }
    }
}
#endregion