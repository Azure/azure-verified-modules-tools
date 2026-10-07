BeforeAll {
    Set-StrictMode -Version 3.0
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $sharedLib = Join-Path $root 'repository-management' 'repository-sync' 'scripts' 'lib'
    $reviewerRoutingLib = Join-Path $root 'repository-management' 'reviewer-routing' 'scripts' 'lib'
    . (Join-Path $sharedLib 'RetryHelpers.ps1')
    . (Join-Path $sharedLib 'RepoTree.ps1')
    . (Join-Path $reviewerRoutingLib 'RepositoryFileAccess.ps1')
    . (Join-Path $reviewerRoutingLib 'ModuleOwners.ps1')
    . (Join-Path $root 'repository-management' 'module-owner-audit' 'scripts' 'lib' 'ModuleOwnerAudit.ps1')

    function New-TestEntry {
        param ($Eco, $Name, $Path, $Repo, $Status = 'Available', $Owners = @(), $Parent = $null, $Family = $null, $Type = 'resource')
        @{
            ecosystem = $Eco; moduleType = $Type; moduleStatus = $Status; moduleName = $Name; modulePath = $Path
            repository = $Repo; repoURL = "https://github.com/$Repo"; parentModule = $Parent; familyModule = $(if ($Family) { $Family } else { $Path })
            moduleDisplayName = $Name; owners = @($Owners | ForEach-Object { @{ handle = $_; type = 'user'; displayName = "Name $_" } })
        }
    }
    $script:Index = @{
        modules = @{
            'a' = @{
                bicep     = @(
                    New-TestEntry bicep 'avm/res/net/thing' 'avm/res/net/thing' 'Azure/bicep-registry-modules' -Owners 'gone'
                    New-TestEntry bicep 'avm/res/net/thing/child' 'avm/res/net/thing/child' 'Azure/bicep-registry-modules' -Owners 'gone' -Parent 'avm/res/net/thing' -Family 'avm/res/net/thing'
                )
                terraform = @(
                    New-TestEntry terraform 'avm-res-net-thing' '.' 'Azure/terraform-azurerm-avm-res-net-thing' -Owners 'active', 'gone'
                    New-TestEntry terraform 'avm-res-net-thing//modules/sub' 'modules/sub' 'Azure/terraform-azurerm-avm-res-net-thing' -Owners 'active', 'gone' -Parent '.' -Family '.'
                )
            }
            'b' = @{
                bicep     = @(New-TestEntry bicep 'avm/res/net/orphan' 'avm/res/net/orphan' 'Azure/bicep-registry-modules' -Status 'Orphaned')
                terraform = @(New-TestEntry terraform 'avm-res-net-orphan' '.' 'Azure/terraform-azurerm-avm-res-net-orphan' -Status 'Orphaned')
            }
            'c' = @{
                bicep = @(
                    New-TestEntry bicep 'avm/res/net/team-join' 'avm/res/net/team-join' 'Azure/bicep-registry-modules' -Owners 'notinteam'
                    New-TestEntry bicep 'avm/res/net/healthy' 'avm/res/net/healthy' 'Azure/bicep-registry-modules' -Owners 'active'
                    New-TestEntry bicep 'avm/res/net/adopted' 'avm/res/net/adopted' 'Azure/bicep-registry-modules' -Owners 'active'
                    New-TestEntry bicep 'avm/res/net/adopted-review' 'avm/res/net/adopted-review' 'Azure/bicep-registry-modules' -Owners 'notinteam'
                    New-TestEntry bicep 'avm/res/net/old' 'avm/res/net/old' 'Azure/bicep-registry-modules' -Status 'Deprecated'
                    New-TestEntry bicep 'avm/ptn/net/proposed' 'avm/ptn/net/proposed' 'Azure/bicep-registry-modules' -Status 'Proposed' -Owners 'gone' -Type 'pattern'
                    New-TestEntry bicep 'avm/res/net/exempted' 'avm/res/net/exempted' 'Azure/bicep-registry-modules' -Owners 'exemptme'
                )
            }
        }
    }
    $script:Flat = Get-AvmRootModule -Index $script:Index
    $script:OwnerStatus = Get-AvmOwnerStatus -Owners @($script:Flat.Roots | ForEach-Object { $_.Owners }) -Organization 'Azure' -Team 't' -Exempt 'ExemptMe' `
        -TeamMemberProvider { param($o, $t) 'Active' } `
        -MembershipProvider { param($o, $h, $type) switch ($h) { 'notinteam' { 'member' } 'gone' { 'notMember' } 'exemptme' { 'notMember' } default { 'noAccount' } } }

    function New-TestIssue ($Number, $Title, $Body = '') { [pscustomobject]@{ number = $Number; title = $Title; body = $Body } }
}

Describe 'Get-AvmRootModule' {
    It 'returns only root modules with child counts and metadata paths' {
        $tf = $script:Flat.Roots | Where-Object ModuleName -EQ 'avm-res-net-thing'
        $bicep = $script:Flat.Roots | Where-Object ModuleName -EQ 'avm/res/net/thing'
        $script:Flat.Roots.ModuleName | Should -Not -Contain 'avm/res/net/thing/child'
        $tf.MetadataPath | Should -Be 'metadata.json'
        $tf.ChildModuleCount | Should -Be 1
        $bicep.MetadataPath | Should -Be 'avm/res/net/thing/metadata.json'
        $bicep.ChildModuleCount | Should -Be 1
    }
}

Describe 'Get-AvmOwnerStatus' {
    It 'classifies <Handle> as <Status>' -ForEach @(
        @{ Handle = 'active'; Status = 'Active'; IsActive = $true }
        @{ Handle = 'ACTIVE'; Status = 'Active'; IsActive = $true }
        @{ Handle = 'notinteam'; Status = 'ActiveNotInTeam'; IsActive = $true }
        @{ Handle = 'gone'; Status = 'NotInOrg'; IsActive = $false }
        @{ Handle = 'exemptme'; Status = 'Exempt'; IsActive = $true }
    ) {
        $script:OwnerStatus[$Handle].Status | Should -Be $Status
        $script:OwnerStatus[$Handle].IsActive | Should -Be $IsActive
    }
    It 'flags deleted accounts as AccountNotFound' {
        $s = Get-AvmOwnerStatus -Owners @([pscustomobject]@{ Handle = 'deleted'; Type = 'user'; DisplayName = $null }) -Organization 'Azure' -Team 't' -TeamMemberProvider { @() } -MembershipProvider { 'noAccount' }
        $s['deleted'].Status | Should -Be 'AccountNotFound'
    }
}

Describe 'Orphan issue matching' {
    BeforeAll { $script:Lookup = Get-AvmModuleLookup -Roots $script:Flat.Roots -Children $script:Flat.Children }
    It 'normalizes <In> to <Out>' -ForEach @(
        @{ In = '`avm/res/net/thing`'; Out = 'avm/res/net/thing' }
        @{ In = 'br/public:avm/res/net/thing:0.1.0'; Out = 'avm/res/net/thing' }
        @{ In = 'https://github.com/Azure/bicep-registry-modules/tree/main/avm/res/net/thing/'; Out = 'avm/res/net/thing' }
        @{ In = 'https://github.com/Azure/terraform-azurerm-avm-res-net-thing'; Out = 'avm-res-net-thing' }
        @{ In = 'https://registry.terraform.io/modules/Azure/avm-res-net-thing/azurerm/latest'; Out = 'avm-res-net-thing' }
        @{ In = 'terraform-azurerm-avm-res-net-thing'; Out = 'avm-res-net-thing' }
    ) {
        ConvertTo-AvmNormalizedModuleToken -Token $In | Should -Be $Out
    }
    It 'matches <Case>' -ForEach @(
        @{ Case = 'template title'; Title = '[Orphaned Module]: `avm/res/net/orphan`'; Body = ''; Expected = 'avm/res/net/orphan'; Via = 'root' }
        @{ Case = 'body module name'; Title = 'Orphaned module'; Body = "### Bicep or Terraform?`n`nTerraform`n`n### Module Name`n`navm-res-net-orphan`n"; Expected = 'avm-res-net-orphan'; Via = 'root' }
        @{ Case = 'repo url in body'; Title = 'help'; Body = 'see https://github.com/Azure/terraform-azurerm-avm-res-net-orphan for details'; Expected = 'avm-res-net-orphan'; Via = 'root' }
        @{ Case = 'bicep-style name in a Terraform issue'; Title = '[Orphaned Module]: `avm/res/net/orphan`'; Body = "### Bicep or Terraform?`n`nTerraform"; Expected = 'avm-res-net-orphan'; Via = 'root' }
        @{ Case = 'plural name'; Title = '[Orphaned Module]: `avm/res/net/orphans`'; Body = ''; Expected = 'avm/res/net/orphan'; Via = 'root' }
        @{ Case = 'child module'; Title = '[Orphaned Module]: `avm/res/net/thing/child`'; Body = ''; Expected = 'avm/res/net/thing'; Via = 'child' }
    ) {
        $m = Resolve-AvmOrphanIssueModule -Issue (New-TestIssue 1 $Title $Body) -Lookup $script:Lookup
        $m.Root.ModuleName | Should -Be $Expected
        $m.Via | Should -Be $Via
    }
    It 'returns $null when nothing matches' {
        Resolve-AvmOrphanIssueModule -Issue (New-TestIssue 1 '[Orphaned Module]: `avm/res/nope/nope`') -Lookup $script:Lookup | Should -BeNullOrEmpty
    }
}

Describe 'Get-AvmAuditResult' {
    BeforeAll {
        $issues = @(
            New-TestIssue 10 '[Orphaned Module]: `avm/res/net/orphan`'
            New-TestIssue 11 '[Orphaned Module]: `avm/res/net/adopted`'
            New-TestIssue 12 '[Orphaned Module]: `avm/res/net/adopted-review`'
            New-TestIssue 13 '[Orphaned Module]: `avm/res/net/old`'
            New-TestIssue 14 '[Orphaned Module]: `something else`'
            New-TestIssue 15 '[Orphaned Module]: `avm/res/net/healthy`'
            New-TestIssue 16 '[Orphaned Module]: `avm/res/net/healthy`'
        )
        $live = { param($m) if ($m.ModuleName -eq 'avm/res/net/healthy') { @() } else { @('someone') } }
        $script:Results = Get-AvmAuditResult -Roots $script:Flat.Roots -Children $script:Flat.Children -OwnerStatus $script:OwnerStatus -OpenIssues $issues -LiveOwnersProvider $live
        $script:ByName = @{}
        foreach ($r in $script:Results | Where-Object Verdict -NE 'IssueHygiene') { $script:ByName["$($r.Ecosystem)|$($r.ModuleName)"] = $r }
    }
    It '<Key> is <Verdict>' -ForEach @(
        @{ Key = 'bicep|avm/res/net/thing'; Verdict = 'WouldOrphan' }
        @{ Key = 'terraform|avm-res-net-thing'; Verdict = 'OwnerReduction' }
        @{ Key = 'terraform|avm-res-net-orphan'; Verdict = 'OrphanMissingIssue' }
        @{ Key = 'bicep|avm/res/net/orphan'; Verdict = 'OK' }
        @{ Key = 'bicep|avm/res/net/adopted'; Verdict = 'OrphanIssueCanClose' }
        @{ Key = 'bicep|avm/res/net/adopted-review'; Verdict = 'OrphanIssueNeedsReview' }
        @{ Key = 'bicep|avm/res/net/healthy'; Verdict = 'OrphanIssueNeedsReview' }
        @{ Key = 'bicep|avm/res/net/team-join'; Verdict = 'NeedsTeamJoin' }
        @{ Key = 'bicep|avm/res/net/exempted'; Verdict = 'OK' }
        @{ Key = 'bicep|avm/ptn/net/proposed'; Verdict = 'WouldOrphan' }
    ) {
        $script:ByName[$Key].Verdict | Should -Be $Verdict
    }
    It 'marks tracked orphans and records removed owners' {
        $script:ByName['bicep|avm/res/net/orphan'].Flags | Should -Contain 'OrphanTracked'
        $script:ByName['terraform|avm-res-net-thing'].InactiveOwners | Should -Be @('gone')
        $script:ByName['terraform|avm-res-net-thing'].ActiveOwners | Should -Be @('active')
    }
    It 'excludes deprecated modules and reports issue hygiene' {
        $script:ByName.Keys | Should -Not -Contain 'bicep|avm/res/net/old'
        $hygiene = @($script:Results | Where-Object Verdict -EQ 'IssueHygiene')
        $hygiene.Flags | Should -Contain 'IssueForDeprecatedModule'
        $hygiene.Flags | Should -Contain 'UnmatchedIssue'
        $hygiene.Flags | Should -Contain 'DuplicateOrphanIssues'
    }
    It 'sorts by priority with proposed modules last' {
        $script:Results[0].Verdict | Should -Be 'WouldOrphan'
        $script:Results[0].ModuleStatus | Should -Not -Be 'Proposed'
        $script:Results[-1].ModuleStatus | Should -Be 'Proposed'
    }
    It 'honours -ModuleFilter' {
        $r = Get-AvmAuditResult -Roots $script:Flat.Roots -OwnerStatus $script:OwnerStatus -ModuleFilter 'avm-res-*'
        $r.ModuleName | Should -Be @('avm-res-net-orphan', 'avm-res-net-thing')
    }
    It 'honours -Ecosystem and -ModuleType and drops unmatched issues when filtered' {
        $issues = @(New-TestIssue 14 '[Orphaned Module]: `something else`')
        $tf = Get-AvmAuditResult -Roots $script:Flat.Roots -OwnerStatus $script:OwnerStatus -OpenIssues $issues -Ecosystem 'terraform'
        @($tf.Ecosystem | Select-Object -Unique) | Should -Be @('terraform')
        $tf.Verdict | Should -Not -Contain 'IssueHygiene'
        $ptn = Get-AvmAuditResult -Roots $script:Flat.Roots -OwnerStatus $script:OwnerStatus -ModuleType 'pattern'
        $ptn.ModuleName | Should -Be @('avm/ptn/net/proposed')
        $all = Get-AvmAuditResult -Roots $script:Flat.Roots -OwnerStatus $script:OwnerStatus -OpenIssues $issues -Ecosystem 'bicep', 'terraform' -ModuleType 'resource', 'pattern', 'utility'
        $all.Verdict | Should -Contain 'IssueHygiene'
    }
}

Describe 'Write-AvmAuditReport' {
    BeforeAll { $script:Report = (Write-AvmAuditReport -Results $script:Results -OwnerStatus $script:OwnerStatus 6>&1 | Out-String) }
    It 'shows a verdict matrix by language and module type' {
        $script:Report | Should -Match 'Verdict\s+Bicep-Res\s+TF-Res\s+Total'
    }
    It 'groups modules by language and module type' {
        $script:Report | Should -Match '-- Bicep / Resource \(1\)\s+avm/res/net/thing'
        $script:Report | Should -Match '-- Terraform / Resource \(1\)\s+avm-res-net-thing'
        $script:Report | Should -Match '-- Bicep / Pattern \(1\)\s+avm/ptn/net/proposed'
    }
    It 'lists the usernames that need to join the team' {
        $script:Report | Should -Match '== NeedsTeamJoin \(1\) ==\s+-- Bicep / Resource \(1\)\s+avm/res/net/team-join\s+needs team join: notinteam'
        $script:Report | Should -Match 'notinteam \(Name notinteam\) - 2 module\(s\)'
    }
}

Describe 'Set-AvmOwnersInMetadataText' {
    It 'edits an inline array and preserves the rest of the file' {
        $text = "{`n  `"`$schema`": `"x`",`n  `"owners`": [`"a`", `"b`"],`n  `"z`": [`"keep`"]`n}`n"
        Set-AvmOwnersInMetadataText -Text $text -Owners 'b' | Should -Be "{`n  `"`$schema`": `"x`",`n  `"owners`": [`"b`"],`n  `"z`": [`"keep`"]`n}`n"
    }
    It 'edits a multi-line CRLF array keeping indentation' {
        $text = "{`r`n  `"owners`": [`r`n    `"a`",`r`n    `"b`"`r`n  ],`r`n  `"t`": 1`r`n}"
        Set-AvmOwnersInMetadataText -Text $text -Owners 'a' | Should -Be "{`r`n  `"owners`": [`r`n    `"a`"`r`n  ],`r`n  `"t`": 1`r`n}"
    }
    It 'writes an empty array when orphaning' {
        Set-AvmOwnersInMetadataText -Text "{`n  `"owners`": [`n    `"a`"`n  ]`n}" -Owners @() | Should -Be "{`n  `"owners`": []`n}"
    }
    It 'throws when there is no owners array' {
        { Set-AvmOwnersInMetadataText -Text '{ "x": 1 }' -Owners @() } | Should -Throw
    }
}

Describe 'Issue and PR bodies' {
    BeforeAll {
        $script:Row = $script:Results | Where-Object { $_.ModuleName -eq 'avm/res/net/thing' } | Select-Object -First 1
    }
    It 'follows the orphaned module issue form' {
        $body = New-AvmOrphanIssueBody -Row $script:Row -Details (Get-AvmOrphanIssueDetail -Row $script:Row -RemovedOwners 'gone')
        $body | Should -Match '### Bicep or Terraform\?\s+Bicep'
        $body | Should -Match '### Module Classification\?\s+Resource Module'
        $body | Should -Match '### Module Name\s+avm/res/net/thing'
        $body | Should -Match '`gone` \(not a member of the `Azure` GitHub organization\)'
        $body | Should -Match '### Do you want to be the new owner of this module\?\s+No'
    }
    It 'lists orphanings and reductions in the PR body' {
        $tfRow = $script:Results | Where-Object { $_.ModuleName -eq 'avm-res-net-thing' } | Select-Object -First 1
        $body = New-AvmPullRequestBody -Changes @(
            [pscustomobject]@{ Row = $script:Row; Removed = @('gone'); Remaining = @(); Orphan = $true; IssueRef = 'Azure/Azure-Verified-Modules#99' }
            [pscustomobject]@{ Row = $tfRow; Removed = @('gone'); Remaining = @('active'); Orphan = $false; IssueRef = $null }
        )
        $body | Should -Match '\| `avm/res/net/thing` \| @gone \| Azure/Azure-Verified-Modules#99 \|'
        $body | Should -Match '\| `avm-res-net-thing` \| @gone \| `active` \|'
    }
}

Describe 'Export-AvmAuditCsv' {
    It 'writes module and owner CSV files' {
        $out = Export-AvmAuditCsv -Results $script:Results -OutputPath $TestDrive -Stamp 'test'
        $modules = Import-Csv $out.ModulesCsv
        $owners = Import-Csv $out.OwnersCsv
    ($modules | Where-Object ModuleName -EQ 'avm/res/net/thing').Verdict | Should -Be 'WouldOrphan'
    ($owners | Where-Object { $_.ModuleName -eq 'avm-res-net-thing' -and $_.OwnerHandle -eq 'gone' }).Action | Should -Be 'Remove'
    ($owners | Where-Object { $_.ModuleName -eq 'avm/res/net/team-join' }).Action | Should -Match 'join AVM'
    }
}

Describe 'Invoke-AvmAuditApply (mocked GitHub)' {
    BeforeAll {
        function Invoke-TestApply {
            [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
            param ($Results, [int] $MaxChanges = [int]::MaxValue, [string] $TargetRepoOverride, [string] $IssueRepoOverride)
            Invoke-AvmAuditApply -Results $Results -Cmdlet $PSCmdlet -Force -CloseResolvedIssues -MaxChanges $MaxChanges `
                -TargetRepoOverride $TargetRepoOverride -IssueRepoOverride $IssueRepoOverride
        }
        $script:LiveFiles = @{
            'Azure/bicep-registry-modules/avm/res/net/thing/metadata.json' = @('gone')
            'Azure/terraform-azurerm-avm-res-net-thing/metadata.json'      = @('active', 'gone')
            'Azure/terraform-azurerm-avm-res-net-orphan/metadata.json'     = @()
        }
    }
    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        $script:GhCalls = [System.Collections.Generic.List[string]]::new()
        $script:OpenAuditPrRepo = $null
        $script:DefaultBranchCache = @{}
        Mock Test-AvmMetadataText { $null }
        Mock Get-AvmRepositoryFileAtRef {
            $key = "$Repository/$Path"
            if ($script:LiveFiles.ContainsKey($key)) {
                $list = (@($script:LiveFiles[$key]) | ForEach-Object { '"' + $_ + '"' }) -join ', '
                return [pscustomobject]@{ Content = '{' + "`n" + '  "$schema": "x",' + "`n" + '  "owners": [' + $list + ']' + "`n" + '}' + "`n"; Sha = 'filesha' }
            }
            return $null
        }
        Mock Invoke-AvmOwnerAuditGh {
            $script:GhCalls.Add($Arguments -join ' ')
            $out = switch ($Arguments[1]) {
                'view' { '{"id":"PROJ"}' }
                'field-list' { '{"fields":[{"id":"FIELD","name":"Status","options":[{"id":"OPT-ORPH","name":"Orphaned"},{"id":"OPT-TRIAGE","name":"Needs: Triage"}]}]}' }
                'item-add' { '{"id":"ITEM"}' }
                default { '' }
            }
            [pscustomobject]@{ Success = $true; StatusCode = 200; Output = $out; Error = '' }
        }
        Mock Invoke-AvmOwnerAuditGhApi {
            $m = if ($Method) { $Method } else { 'GET' }
            $script:Calls.Add([pscustomobject]@{ Method = $m; Endpoint = $Endpoint; Body = $Body })
            switch -Regex ("$m $Endpoint") {
                '^GET repos/([^/]+/[^/]+)/pulls\?' {
                    if ($Matches[1] -eq $script:OpenAuditPrRepo) { return @([pscustomobject]@{ html_url = 'https://x/pr/1'; head = @{ ref = 'avm-owner-audit/20200101'; repo = @{ full_name = $Matches[1] } } }) }
                    return @()
                }
                '^GET repos/[^/]+/[^/]+/labels' { return @($script:PrLabels + $script:OrphanLabels + $script:AvailableLabels | ForEach-Object { [pscustomobject]@{ name = $_ } }) }
                '^GET repos/([^/]+/[^/]+)/contents/([^?]+)\?ref=' { return $null }
                '^GET repos/[^/]+/[^/]+/git/ref/heads/main$' { return [pscustomobject]@{ object = @{ sha = 'basesha' } } }
                '^GET repos/[^/]+/[^/]+/git/ref/heads/' { return $null }
                '^GET repos/[^/]+/[^/]+$' { return [pscustomobject]@{ default_branch = 'main' } }
                '^POST repos/([^/]+/[^/]+)/pulls$' { return [pscustomobject]@{ number = 5; html_url = "https://github.com/$($Matches[1])/pull/5" } }
                '^POST repos/([^/]+/[^/]+)/issues$' { $n = 100 + @($script:Calls | Where-Object { $_.Method -eq 'POST' -and $_.Endpoint -match '/issues$' }).Count; return [pscustomobject]@{ number = $n; html_url = "https://github.com/$($Matches[1])/issues/$n" } }
                default { return [pscustomobject]@{} }
            }
        }
    }

    It 'removes owners, opens one PR per repository, creates and links orphan issues, and closes resolved issues' {
        $summary = Invoke-TestApply -Results $script:Results

        $puts = @($script:Calls | Where-Object Method -EQ 'PUT')
        $puts.Endpoint | Should -Be @('repos/Azure/bicep-registry-modules/contents/avm/res/net/thing/metadata.json', 'repos/Azure/terraform-azurerm-avm-res-net-thing/contents/metadata.json')
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($puts[0].Body.content)) | Should -Match '"owners": \[\]'
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($puts[1].Body.content)) | Should -Match '"owners": \["active"\]'
        $puts[0].Body.branch | Should -BeLike 'avm-owner-audit/*'

        $prs = @($script:Calls | Where-Object { $_.Method -eq 'POST' -and $_.Endpoint -match '/pulls$' })
        $prs.Count | Should -Be 2
        $prs[0].Body.title | Should -Be $script:PrTitle
        $prs[0].Body.body | Should -Match 'Azure/Azure-Verified-Modules#101'

        $issues = @($script:Calls | Where-Object { $_.Method -eq 'POST' -and $_.Endpoint -eq 'repos/Azure/Azure-Verified-Modules/issues' })
        $issues.Body.title | Should -Be @('[Orphaned Module]: `avm/res/net/thing`', '[Orphaned Module]: `avm-res-net-orphan`')
        $issues[0].Body.labels | Should -Be $script:OrphanLabels

    ($script:GhCalls | Where-Object { $_ -match 'item-edit' }) -join "`n" | Should -Match 'OPT-ORPH'
    ($script:GhCalls | Where-Object { $_ -match 'item-edit' }) -join "`n" | Should -Match 'OPT-TRIAGE'

        $reviewers = @($script:Calls | Where-Object { $_.Endpoint -match 'requested_reviewers' })
        $reviewers.Body.team_reviewers | Should -Contain 'azure-verified-modules-engineering-owners'

        $close = $script:Calls | Where-Object { $_.Method -eq 'PATCH' -and $_.Endpoint -eq 'repos/Azure/Azure-Verified-Modules/issues/11' }
        $close.Body.state | Should -Be 'closed'
    ($summary | Where-Object Action -EQ 'CloseIssue').Result | Should -Be 'Closed'
    }

    It 'honours -MaxChanges' {
        Invoke-TestApply -Results $script:Results -MaxChanges 1 | Out-Null

        @($script:Calls | Where-Object Method -EQ 'PUT').Count | Should -Be 1
        @($script:Calls | Where-Object Method -EQ 'PATCH').Count | Should -Be 0
    }

    It 'skips repositories with an open audit PR' {
        $script:OpenAuditPrRepo = 'Azure/bicep-registry-modules'
        $summary = Invoke-TestApply -Results $script:Results
        @($script:Calls | Where-Object Method -EQ 'PUT').Endpoint | Should -Not -Contain 'repos/Azure/bicep-registry-modules/contents/avm/res/net/thing/metadata.json'
    ($summary | Where-Object { $_.Target -eq 'Azure/bicep-registry-modules' }).Result | Should -BeLike 'Skipped*'
    }

    It 'makes no changes with -WhatIf' {
        Invoke-TestApply -Results $script:Results -WhatIf | Out-Null
        @($script:Calls | Where-Object Method -NE 'GET').Count | Should -Be 0
    }

    It 'writes to the sandbox and skips projects and real issue closes with overrides' {
        Invoke-TestApply -Results $script:Results -TargetRepoOverride 'me/sandbox' -IssueRepoOverride 'me/sandbox' | Out-Null

        @($script:Calls | Where-Object Method -EQ 'PUT').Endpoint | Should -Be @('repos/me/sandbox/contents/avm/res/net/thing/metadata.json', 'repos/me/sandbox/contents/terraform/terraform-azurerm-avm-res-net-thing/metadata.json')
        @($script:Calls | Where-Object { $_.Method -eq 'POST' -and $_.Endpoint -match '/issues$' }).Endpoint | Should -Not -Contain 'repos/Azure/Azure-Verified-Modules/issues'
        $script:GhCalls | Should -BeNullOrEmpty
        @($script:Calls | Where-Object Method -EQ 'PATCH').Count | Should -Be 0
    }
}

Describe 'Invoke-AvmOwnerAuditGh' {
    It 'returns trimmed output on success' {
        Mock Invoke-GitHubCliWithRetry { @(@{ success = $true; output = "  {`"a`":1}  " }) }
        $r = Invoke-AvmOwnerAuditGh -Arguments @('api', 'user')
        $r.Success | Should -BeTrue
        $r.Output | Should -Be '{"a":1}'
    }
    It 'maps the HTTP status code from the error output' {
        Mock Invoke-GitHubCliWithRetry { @(@{ success = $false; exitCode = 1; error = 'gh: Not Found (HTTP 404)' }) }
        $r = Invoke-AvmOwnerAuditGh -Arguments @('api', 'orgs/Azure/members/nobody')
        $r.Success | Should -BeFalse
        $r.StatusCode | Should -Be 404
    }
    It 'treats exhausted retries without error text as a failure' {
        Mock Invoke-GitHubCliWithRetry { @(@{ success = $false }) }
        (Invoke-AvmOwnerAuditGh -Arguments @('api', 'user')).StatusCode | Should -Be 0
    }
    It 'retries transient 5xx responses through the shared wrapper' {
        Mock Invoke-GitHubCliWithRetry { @(@{ success = $true; output = '' }) }
        Invoke-AvmOwnerAuditGh -Arguments @('api', 'user') | Out-Null
        Should -Invoke Invoke-GitHubCliWithRetry -Times 1 -ParameterFilter { $retryOn -contains 'HTTP 502' -and $literalArguments }
    }
}

Describe 'Test-AvmOwnerAuditGhResource' {
    It 'returns $false for 404 and throws for other failures' {
        Mock Invoke-AvmOwnerAuditGh { [pscustomobject]@{ Success = $false; StatusCode = 404; Output = ''; Error = 'HTTP 404' } }
        Test-AvmOwnerAuditGhResource -Endpoint 'orgs/Azure/members/x' | Should -BeFalse
        Mock Invoke-AvmOwnerAuditGh { [pscustomobject]@{ Success = $false; StatusCode = 403; Output = ''; Error = 'HTTP 403' } }
        { Test-AvmOwnerAuditGhResource -Endpoint 'orgs/Azure/members/x' } | Should -Throw
    }
}