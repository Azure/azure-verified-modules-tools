BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $script:syncRoot = Join-Path $script:root 'repository-management' 'bicep-codeowners-sync'
    . (Join-Path $script:syncRoot 'scripts' 'lib' 'Codeowners.ps1')
    $script:template = Get-Content -LiteralPath (Join-Path $script:syncRoot 'CODEOWNERS.template') -Raw
    $script:group = '@Azure/azure-verified-modules-module-owners'
    $script:metadataRule = 'metadata.json @Azure/azure-verified-modules-engineering-owners'

    function New-OwnershipRow {
        param(
            [string] $Name = 'avm/res/test/parent',
            [string] $Primary = 'Alice',
            [string] $Secondary = '',
            [string] $Parent = 'n/a',
            [string] $Status = 'Available'
        )
        [pscustomobject][ordered]@{
            ModuleName = $Name
            ParentModule = $Parent
            ModuleStatus = $Status
            PrimaryModuleOwnerGHHandle = $Primary
            SecondaryModuleOwnerGHHandle = $Secondary
            ModuleOwnersGHTeam = '@Azure/retired-team'
        }
    }

    function ConvertTo-OwnershipCsv {
        param([object[]] $Rows)
        ($Rows | ConvertTo-Csv -NoTypeInformation) -join "`n"
    }

    function New-OwnershipIndexes {
        param([object[]] $ResourceRows = @((New-OwnershipRow)))
        @{
            res = ConvertTo-OwnershipCsv -Rows $ResourceRows
            ptn = ConvertTo-OwnershipCsv -Rows @((New-OwnershipRow -Name 'avm/ptn/test/pattern' -Primary 'Bob' -Secondary 'Carol'))
            utl = ConvertTo-OwnershipCsv -Rows @((New-OwnershipRow -Name 'avm/utl/test/utility' -Primary ''))
        }
    }

    function Get-ModuleRules {
        param([string] $Content)
        @($Content.Split("`n") | Where-Object { $_ -cmatch '^/avm/(res|ptn|utl)/' })
    }
}

Describe 'Bicep CODEOWNERS ownership generation' {
    It 'includes all three indexes with primary then secondary and the shared group last' {
        $content = ConvertTo-AvmBicepCodeowners -Indexes (New-OwnershipIndexes) -Template $script:template
        Get-ModuleRules $content | Should -Be @(
            "/avm/ptn/test/pattern/ @bob @carol $script:group"
            "/avm/res/test/parent/ @alice $script:group"
            "/avm/utl/test/utility/ $script:group"
        )
        $content | Should -Not -Match 'retired-team'
    }

    It 'normalizes whitespace, case, and one leading at sign before deduplicating' {
        $indexes = New-OwnershipIndexes -ResourceRows @((New-OwnershipRow -Primary ' @ALIce ' -Secondary 'alice'))
        $content = ConvertTo-AvmBicepCodeowners -Indexes $indexes -Template $script:template
        Get-ModuleRules $content | Should -Contain "/avm/res/test/parent/ @alice $script:group"
        $content | Should -Not -Match '@alice @alice'
    }

    It 'keeps a secondary owner when the primary owner is empty' {
        $indexes = New-OwnershipIndexes -ResourceRows @((New-OwnershipRow -Primary '' -Secondary '@CAROL'))
        Get-ModuleRules (ConvertTo-AvmBicepCodeowners -Indexes $indexes -Template $script:template) |
            Should -Contain "/avm/res/test/parent/ @carol $script:group"
    }

    It 'uses the group alone for ownerless available and orphaned modules' -ForEach @('Available', 'Orphaned') {
        $indexes = New-OwnershipIndexes -ResourceRows @((New-OwnershipRow -Primary '' -Status $_))
        Get-ModuleRules (ConvertTo-AvmBicepCodeowners -Indexes $indexes -Template $script:template) |
            Should -Contain "/avm/res/test/parent/ $script:group"
    }

    It 'discards stale individual ownership for orphaned modules' {
        $indexes = New-OwnershipIndexes -ResourceRows @((New-OwnershipRow -Primary 'FormerOwner' -Secondary 'FormerBackup' -Status 'Orphaned'))
        $content = ConvertTo-AvmBicepCodeowners -Indexes $indexes -Template $script:template
        Get-ModuleRules $content | Should -Contain "/avm/res/test/parent/ $script:group"
        $content | Should -Not -Match 'former'
    }

    It 'includes proposed and deprecated modules for new and retained contributions' -ForEach @('Proposed', 'Deprecated') {
        $indexes = New-OwnershipIndexes -ResourceRows @((New-OwnershipRow -Status $_))
        Get-ModuleRules (ConvertTo-AvmBicepCodeowners -Indexes $indexes -Template $script:template) |
            Should -Contain "/avm/res/test/parent/ @alice $script:group"
    }

    It 'emits only top-level directory rules even when children declare different owners' {
        $indexes = New-OwnershipIndexes -ResourceRows @(
            (New-OwnershipRow -Name 'avm/res/test/parent/child/leaf' -Primary '' -Parent 'avm/res/test/parent')
            (New-OwnershipRow -Name 'avm/res/test/parent/child' -Primary 'ChildOwner' -Parent 'avm/res/test/parent')
            (New-OwnershipRow -Primary 'ParentOwner' -Secondary 'Backup')
        )
        $rules = Get-ModuleRules (ConvertTo-AvmBicepCodeowners -Indexes $indexes -Template $script:template)
        $rules[1] | Should -Be "/avm/res/test/parent/ @parentowner @backup $script:group"
        $rules | Should -HaveCount 3
        ($rules -join "`n") | Should -Not -Match '/child/|@childowner'
        foreach ($rule in $rules) {
            ($rule -split ' ')[0] | Should -Match '^/avm/(res|ptn|utl)/[^/]+/[^/]+/$'
        }
    }

    It 'does not resolve or execute child-specific ownership metadata' {
        $indexes = New-OwnershipIndexes -ResourceRows @(
            (New-OwnershipRow)
            (New-OwnershipRow -Name 'avm/res/test/parent/child' -Primary '$(throw "not code")' -Parent 'missing')
            (New-OwnershipRow -Name 'avm/res/test/parent/child/leaf' -Primary '' -Parent '')
        )
        $content = ConvertTo-AvmBicepCodeowners -Indexes $indexes -Template $script:template
        Get-ModuleRules $content | Should -Contain "/avm/res/test/parent/ @alice $script:group"
        $content | Should -Not -Match '/child/|not code'
    }

    It 'ignores retired per-module teams instead of using them as an ownerless fallback' {
        $indexes = New-OwnershipIndexes -ResourceRows @((New-OwnershipRow -Primary ''))
        $content = ConvertTo-AvmBicepCodeowners -Indexes $indexes -Template $script:template
        Get-ModuleRules $content | Should -Contain "/avm/res/test/parent/ $script:group"
        $content | Should -Not -Match 'retired-team'
    }

    It 'is byte-identical after index reordering and omits all child paths' {
        $rows = @(
            (New-OwnershipRow -Name 'avm/res/test/parent/child' -Primary '' -Parent 'avm/res/test/parent')
            (New-OwnershipRow -Name 'avm/res/test/parent-sibling')
            (New-OwnershipRow)
        )
        $first = ConvertTo-AvmBicepCodeowners -Indexes (New-OwnershipIndexes $rows) -Template $script:template
        [array]::Reverse($rows)
        $second = ConvertTo-AvmBicepCodeowners -Indexes (New-OwnershipIndexes $rows) -Template $script:template
        $first | Should -BeExactly $second
        $first.Contains("`r") | Should -BeFalse
        $first.EndsWith("`n") | Should -BeTrue
        $first[0] | Should -Not -Be ([char]0xFEFF)
        $first | Should -Not -Match '/parent/child/'
    }

    It 'rejects an incomplete index that contains no top-level modules' {
        $indexes = New-OwnershipIndexes -ResourceRows @((New-OwnershipRow -Name 'avm/res/test/parent/child'))
        { ConvertTo-AvmBicepCodeowners -Indexes $indexes -Template $script:template } | Should -Throw '*no top-level modules*'
    }

    It 'rejects duplicate normalized module paths' {
        $indexes = New-OwnershipIndexes -ResourceRows @((New-OwnershipRow), (New-OwnershipRow -Name '/avm/res/test/parent/'))
        { ConvertTo-AvmBicepCodeowners -Indexes $indexes -Template $script:template } | Should -Throw '*duplicate module path*'
    }

    It 'rejects wildcard, traversal, wrong-kind, case, and whitespace paths' -ForEach @(
        'avm/res/test/*', 'avm/res/test/../escape', 'avm/res/test/white space',
        'avm/ptn/test/parent', 'avm/res/Test/parent', 'avm/res/test//parent',
        'avm\res\test\parent', "avm/res/test/parent`n*"
    ) {
        $indexes = New-OwnershipIndexes -ResourceRows @((New-OwnershipRow -Name $_))
        { ConvertTo-AvmBicepCodeowners -Indexes $indexes -Template $script:template } | Should -Throw '*module path*'
    }

    It 'rejects malformed or executable-looking handles rather than widening fallback' -ForEach @(
        '@@alice', '@Azure/a-team', 'alice,bob', 'alice;bob', 'alice bob', 'a--b', '-alice', 'alice-',
        'alice@example.com', ('a' * 40), '$(throw "executed")', "alice`n* @attacker"
    ) {
        $indexes = New-OwnershipIndexes -ResourceRows @((New-OwnershipRow -Primary $_))
        { ConvertTo-AvmBicepCodeowners -Indexes $indexes -Template $script:template } | Should -Throw '*Invalid individual GitHub handle*'
    }

    It 'rejects unknown module statuses rather than skipping rows' {
        $indexes = New-OwnershipIndexes -ResourceRows @((New-OwnershipRow -Status 'unexpected'))
        { ConvertTo-AvmBicepCodeowners -Indexes $indexes -Template $script:template } | Should -Throw '*Unknown module status*'
    }
}

Describe 'Ownership CSV failure boundaries' {
    It 'requires all three nonempty indexes' -ForEach @('res', 'ptn', 'utl') {
        $indexes = New-OwnershipIndexes
        $indexes[$_] = ''
        { ConvertTo-AvmBicepCodeowners -Indexes $indexes -Template $script:template } | Should -Throw '*empty*'
        $indexes.Remove($_)
        { ConvertTo-AvmBicepCodeowners -Indexes $indexes -Template $script:template } | Should -Throw '*All three*'
    }

    It 'rejects header-only, HTML, malformed quoting, duplicated headers, extra or missing cells' -ForEach @(
        @{ Csv = 'ModuleName,ModuleStatus,ParentModule,PrimaryModuleOwnerGHHandle,SecondaryModuleOwnerGHHandle' }
        @{ Csv = '<html>Temporarily unavailable</html>' }
        @{ Csv = "ModuleName,ModuleStatus,ParentModule,PrimaryModuleOwnerGHHandle,SecondaryModuleOwnerGHHandle`navm/res/test/parent,Available,n/a,`"unterminated," }
        @{ Csv = "ModuleName,modulename,ParentModule,ModuleStatus,PrimaryModuleOwnerGHHandle,SecondaryModuleOwnerGHHandle`na,b,n/a,Available,x,y" }
        @{ Csv = "ModuleName,ModuleStatus,ParentModule,PrimaryModuleOwnerGHHandle,SecondaryModuleOwnerGHHandle`navm/res/test/parent,Available,n/a,alice,bob,extra" }
        @{ Csv = "ModuleName,ModuleStatus,ParentModule,PrimaryModuleOwnerGHHandle,SecondaryModuleOwnerGHHandle`navm/res/test/parent,Available,n/a,alice" }
    ) {
        { ConvertFrom-AvmBicepOwnershipCsv -Content $Csv -Kind res } | Should -Throw
    }

    It 'requires the primary, secondary, path, and status columns' -ForEach @(
        'PrimaryModuleOwnerGHHandle', 'SecondaryModuleOwnerGHHandle', 'ModuleName', 'ModuleStatus'
    ) {
        $row = New-OwnershipRow
        $row.PSObject.Properties.Remove($_)
        { ConvertFrom-AvmBicepOwnershipCsv -Content (ConvertTo-OwnershipCsv @($row)) -Kind res } | Should -Throw '*missing column*'
    }

    It 'accepts quoted CSV and absent optional trailing publication cells in the official indexes' {
        $csv = "ModuleName,ModuleStatus,ParentModule,PrimaryModuleOwnerGHHandle,SecondaryModuleOwnerGHHandle,Description,FirstPublishedIn`r`n" +
            "avm/res/test/parent,Available,n/a,Alice,,`"A quoted, description`"`r`n"
        $rows = @(ConvertFrom-AvmBicepOwnershipCsv -Content $csv -Kind res)
        $rows.Count | Should -Be 1
        $rows[0].PrimaryModuleOwnerGHHandle | Should -Be 'Alice'
        $rows[0].SecondaryModuleOwnerGHHandle | Should -Be ''
    }

    It 'does not require or consume ParentModule in any index' -ForEach @('res', 'ptn', 'utl') {
        $row = New-OwnershipRow -Name "avm/$_/test/module"
        $row.PSObject.Properties.Remove('ParentModule')
        $rows = @(ConvertFrom-AvmBicepOwnershipCsv -Content (ConvertTo-OwnershipCsv @($row)) -Kind $_)
        $rows[0].ModuleName | Should -Be "avm/$_/test/module"
        $rows[0].PrimaryModuleOwnerGHHandle | Should -Be 'Alice'
    }
}

Describe 'Template-backed static ownership preservation' {
    BeforeEach {
        $script:rendered = ConvertTo-AvmBicepCodeowners -Indexes (New-OwnershipIndexes) -Template $script:template
    }

    It 'retains the automation header, actual template URL, and all critical static rules in order' {
        $script:rendered | Should -Match '^# This file is generated automatically'
        $script:rendered | Should -Match 'Do not edit manually\.'
        $script:rendered | Should -Match '# Template: https://github.com/Azure/azure-verified-modules-tools/blob/main/repository-management/bicep-codeowners-sync/CODEOWNERS.template'
        $rules = @($script:rendered.Split("`n") | Where-Object { $_ -and -not $_.StartsWith('#') })
        $rules[0] | Should -Be '* @Azure/azure-verified-modules-tooling-contributors'
        $rules[1] | Should -Be "/avm/ $script:group"
        $rules[-3] | Should -Be '*avm.core.team.tests.ps1 @Azure/azure-verified-modules-tooling-contributors'
        $rules[-2] | Should -Be '*.e2eignore @Azure/azure-verified-modules-tooling-contributors'
        $rules[-1] | Should -BeExactly $script:metadataRule
    }

    It 'permits only the explicit first-time header, default, and metadata migration' {
        $legacy = @(
            '* @Azure/azure-verified-modules-tooling-contributors', '',
            '/avm/ @Azure/azure-verified-modules-module-contributors', '',
            '*avm.core.team.tests.ps1 @Azure/azure-verified-modules-tooling-contributors',
            '*.e2eignore @Azure/azure-verified-modules-tooling-contributors', ''
        ) -join "`n"
        { Assert-AvmCodeownersContent -Content $legacy -Template $script:template -AllowLegacyDefault } | Should -Not -Throw
        { Assert-AvmCodeownersContent -Content $legacy -Template $script:template } | Should -Throw '*static CODEOWNERS*'
        { Assert-AvmCodeownersContent -Content ("# Keep this manual note`n" + $legacy) -Template $script:template -AllowLegacyDefault } |
            Should -Throw '*static CODEOWNERS*'
    }

    It 'accepts old generated content without metadata protection only in compatibility mode' {
        $legacy = $script:rendered.Replace("$script:metadataRule`n", '')
        { Assert-AvmCodeownersContent -Content $legacy -Template $script:template -AllowLegacyDefault } | Should -Not -Throw
        { Assert-AvmCodeownersContent -Content $legacy -Template $script:template } | Should -Throw '*static CODEOWNERS*'
        $legacy | Should -Not -Match '(?m)^metadata\.json '
    }

    It 'rejects a template with <Mutation> metadata protection even in compatibility mode' -ForEach @(
        @{ Mutation = 'missing'; Replacement = '' }
        @{ Mutation = 'root-only'; Replacement = '/metadata.json @Azure/azure-verified-modules-engineering-owners' }
        @{ Mutation = 'additional owners'; Replacement = 'metadata.json @Azure/azure-verified-modules-engineering-owners @alice' }
        @{ Mutation = 'non-final'; Replacement = "metadata.json @Azure/azure-verified-modules-engineering-owners`n* @alice" }
    ) {
        $template = $script:template.Replace($script:metadataRule, $Replacement)
        { ConvertTo-AvmBicepCodeowners -Indexes (New-OwnershipIndexes) -Template $template } | Should -Throw '*static ownership contract*'
        { Assert-AvmCodeownersContent -Content $script:rendered -Template $template -AllowLegacyDefault } |
            Should -Throw '*static ownership contract*'
    }

    It 'rejects changed metadata ownership or precedence in old and new content' -ForEach @(
        @{ Replacement = 'metadata.json @alice' }
        @{ Replacement = 'metadata.json @Azure/azure-verified-modules-engineering-owners @alice' }
        @{ Replacement = '/metadata.json @Azure/azure-verified-modules-engineering-owners' }
        @{ Replacement = "metadata.json @Azure/azure-verified-modules-engineering-owners`n* @alice" }
        @{ Replacement = "metadata.json @Azure/azure-verified-modules-engineering-owners`nmetadata.json @Azure/azure-verified-modules-engineering-owners" }
    ) {
        $changed = $script:rendered.Replace($script:metadataRule, $Replacement)
        { Assert-AvmCodeownersContent -Content $changed -Template $script:template } | Should -Throw '*static CODEOWNERS*'
        { Assert-AvmCodeownersContent -Content $changed -Template $script:template -AllowLegacyDefault } | Should -Throw '*static CODEOWNERS*'
    }

    It 'rejects moving metadata before the tooling overrides without changing their rules' {
        $changed = $script:rendered.Replace("$script:metadataRule`n", '').Replace(
            '*avm.core.team.tests.ps1', "$script:metadataRule`n*avm.core.team.tests.ps1"
        )
        { Assert-AvmCodeownersContent -Content $changed -Template $script:template } | Should -Throw '*static CODEOWNERS*'
        { Assert-AvmCodeownersContent -Content $changed -Template $script:template -AllowLegacyDefault } | Should -Throw '*static CODEOWNERS*'
    }

    It 'preserves additional reviewed template comments byte-for-byte and does not evaluate them' {
        $template = $script:template.Replace("__AVM_MODULE_OWNERS__", '# $(throw "do not execute")' + "`n__AVM_MODULE_OWNERS__")
        $content = ConvertTo-AvmBicepCodeowners -Indexes (New-OwnershipIndexes) -Template $template
        $content | Should -Match ([regex]::Escape('# $(throw "do not execute")'))
        { Assert-AvmCodeownersContent -Content $content -Template $template } | Should -Not -Throw
    }

    It 'refuses missing, duplicate, or inline placeholders' -ForEach @('', "__AVM_MODULE_OWNERS__`n__AVM_MODULE_OWNERS__", '# __AVM_MODULE_OWNERS__') {
        $template = $script:template.Replace('__AVM_MODULE_OWNERS__', $_)
        { ConvertTo-AvmBicepCodeowners -Indexes (New-OwnershipIndexes) -Template $template } | Should -Throw '*placeholder*'
    }

    It 'refuses a placeholder after the final tooling override' {
        $template = $script:template.Replace("__AVM_MODULE_OWNERS__`n", '') + "__AVM_MODULE_OWNERS__`n"
        { ConvertTo-AvmBicepCodeowners -Indexes (New-OwnershipIndexes) -Template $template } | Should -Throw '*final tooling overrides*'
    }

    It 'refuses unfamiliar static rules, comments, and lost tooling overrides' -ForEach @(
        @{ From = '*.e2eignore @Azure/azure-verified-modules-tooling-contributors'; To = '*.e2eignore @attacker' }
        @{ From = '* @Azure/azure-verified-modules-tooling-contributors'; To = '* @attacker' }
        @{ From = '*avm.core.team.tests.ps1'; To = '*avm.other.tests.ps1' }
        @{ From = '# This file is generated automatically'; To = "# An unreviewed manual note`n# This file is generated automatically" }
    ) {
        $changed = $script:rendered.Replace($From, $To)
        { Assert-AvmCodeownersContent -Content $changed -Template $script:template } | Should -Throw
    }

    It 'rejects non-final, repeated, or missing shared module groups' -ForEach @(
        "@alice @Azure/azure-verified-modules-module-owners @bob",
        "@alice @Azure/azure-verified-modules-module-owners @Azure/azure-verified-modules-module-owners",
        '@alice', '@Alice @alice @Azure/azure-verified-modules-module-owners'
    ) {
        $changed = $script:rendered.Replace("@alice $script:group", $_)
        { Assert-AvmCodeownersContent -Content $changed -Template $script:template } | Should -Throw
    }

    It 'rejects module rows appended after critical overrides' {
        $changed = $script:rendered + "/avm/res/zzzz/module/ @alice $script:group`n"
        { Assert-AvmCodeownersContent -Content $changed -Template $script:template } | Should -Throw '*out-of-order*'
    }

    It 'rejects files at the exact GitHub size limit' {
        $padding = '# ' + ('x' * 3MB) + "`n"
        $template = $padding + $script:template
        { ConvertTo-AvmBicepCodeowners -Indexes (New-OwnershipIndexes) -Template $template } | Should -Throw '*3 MB*'
    }
}
