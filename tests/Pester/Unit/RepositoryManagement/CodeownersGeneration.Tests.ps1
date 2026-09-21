BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $script:syncRoot = Join-Path $script:root 'repository-management' 'bicep-codeowners-sync'
    . (Join-Path $script:syncRoot 'scripts' 'lib' 'Codeowners.ps1')
    $script:template = Get-Content -LiteralPath (Join-Path $script:syncRoot 'CODEOWNERS.template') -Raw
    $script:group = '@Azure/azure-verified-modules-module-owners'
    $script:metadataRule = 'metadata.json @Azure/azure-verified-modules-engineering-owners @Azure/azure-verified-modules-module-owners'

    function New-CodeownersModule {
        param(
            [string] $Name = 'avm/res/test/parent',
            [string[]] $Owners = @('Alice')
        )
        [pscustomobject]@{ Name = $Name; Owners = $Owners }
    }

    function Get-DefaultModules {
        @(
            (New-CodeownersModule)
            (New-CodeownersModule -Name 'avm/ptn/test/pattern' -Owners @('Bob', 'Carol'))
            (New-CodeownersModule -Name 'avm/utl/test/utility' -Owners @())
        )
    }

    function Get-ModuleRules {
        param([string] $Content)
        @($Content.Split("`n") | Where-Object { $_ -cmatch '^/avm/(res|ptn|utl)/' })
    }
}

Describe 'Bicep CODEOWNERS ownership generation' {
    It 'includes all three kinds with owners in file order and the shared group last' {
        $content = ConvertTo-AvmBicepCodeowners -Modules (Get-DefaultModules) -Template $script:template
        Get-ModuleRules $content | Should -Be @(
            "/avm/ptn/test/pattern/ @bob @carol $script:group"
            "/avm/res/test/parent/ @alice $script:group"
            "/avm/utl/test/utility/ $script:group"
        )
    }

    It 'supports an unlimited number of owners on one module' {
        $owners = 1..10 | ForEach-Object { "owner$_" }
        $modules = @((New-CodeownersModule -Owners $owners), (New-CodeownersModule -Name 'avm/ptn/test/pattern'), (New-CodeownersModule -Name 'avm/utl/test/utility'))
        $content = ConvertTo-AvmBicepCodeowners -Modules $modules -Template $script:template
        $expected = "/avm/res/test/parent/ $(($owners | ForEach-Object { "@$_" }) -join ' ') $script:group"
        Get-ModuleRules $content | Should -Contain $expected
    }

    It 'accepts both individual and @org/team-slug owner handles on the same module' {
        $modules = @((New-CodeownersModule -Owners @('Alice', '@Azure/some-team')), (New-CodeownersModule -Name 'avm/ptn/test/pattern'), (New-CodeownersModule -Name 'avm/utl/test/utility'))
        $content = ConvertTo-AvmBicepCodeowners -Modules $modules -Template $script:template
        Get-ModuleRules $content | Should -Contain "/avm/res/test/parent/ @alice @Azure/some-team $script:group"
    }

    It 'normalizes whitespace, case, and one leading at sign before deduplicating' {
        $modules = @((New-CodeownersModule -Owners @(' @ALIce ', 'alice')), (New-CodeownersModule -Name 'avm/ptn/test/pattern'), (New-CodeownersModule -Name 'avm/utl/test/utility'))
        $content = ConvertTo-AvmBicepCodeowners -Modules $modules -Template $script:template
        Get-ModuleRules $content | Should -Contain "/avm/res/test/parent/ @alice $script:group"
        $content | Should -Not -Match '@alice @alice'
    }

    It 'uses the group alone for a module with no owners' {
        $modules = @((New-CodeownersModule -Owners @()), (New-CodeownersModule -Name 'avm/ptn/test/pattern'), (New-CodeownersModule -Name 'avm/utl/test/utility'))
        $content = ConvertTo-AvmBicepCodeowners -Modules $modules -Template $script:template
        Get-ModuleRules $content | Should -Contain "/avm/res/test/parent/ $script:group"
    }

    It 'is byte-identical after module reordering' {
        $modules = @(
            (New-CodeownersModule -Name 'avm/res/test/parent-sibling')
            (New-CodeownersModule)
            (New-CodeownersModule -Name 'avm/ptn/test/pattern')
            (New-CodeownersModule -Name 'avm/utl/test/utility')
        )
        $first = ConvertTo-AvmBicepCodeowners -Modules $modules -Template $script:template
        [array]::Reverse($modules)
        $second = ConvertTo-AvmBicepCodeowners -Modules $modules -Template $script:template
        $first | Should -BeExactly $second
        $first.Contains("`r") | Should -BeFalse
        $first.EndsWith("`n") | Should -BeTrue
        $first[0] | Should -Not -Be ([char]0xFEFF)
    }

    It 'rejects an empty modules array' {
        { ConvertTo-AvmBicepCodeowners -Modules @() -Template $script:template } | Should -Throw '*At least one Bicep root module*'
    }

    It 'rejects a missing kind that has no top-level modules' {
        $modules = @((New-CodeownersModule), (New-CodeownersModule -Name 'avm/utl/test/utility' -Owners @()))
        { ConvertTo-AvmBicepCodeowners -Modules $modules -Template $script:template } | Should -Throw '*No top-level Bicep ptn modules*'
    }

    It 'rejects duplicate normalized module paths' {
        $modules = @((New-CodeownersModule), (New-CodeownersModule -Name '/avm/res/test/parent/'))
        { ConvertTo-AvmBicepCodeowners -Modules $modules -Template $script:template } | Should -Throw '*duplicate module path*'
    }

    It 'rejects wildcard, traversal, case, and whitespace paths' -ForEach @(
        'avm/res/test/*', 'avm/res/test/../escape', 'avm/res/test/white space',
        'avm/res/Test/parent', 'avm/res/test//parent',
        'avm\res\test\parent', "avm/res/test/parent`n*"
    ) {
        { ConvertTo-AvmBicepCodeowners -Modules @((New-CodeownersModule -Name $_)) -Template $script:template } | Should -Throw '*module path*'
    }

    It 'rejects malformed or executable-looking handles rather than widening fallback' -ForEach @(
        '@@alice', 'alice,bob', 'alice;bob', 'alice bob', 'a--b', '-alice', 'alice-',
        'alice@example.com', ('a' * 40), '$(throw "executed")', "alice`n* @attacker"
    ) {
        $modules = @((New-CodeownersModule -Owners @($_)), (New-CodeownersModule -Name 'avm/ptn/test/pattern'), (New-CodeownersModule -Name 'avm/utl/test/utility'))
        { ConvertTo-AvmBicepCodeowners -Modules $modules -Template $script:template } | Should -Throw '*Invalid GitHub owner handle*'
    }
}

Describe 'Template-backed static ownership preservation' {
    BeforeEach {
        $script:rendered = ConvertTo-AvmBicepCodeowners -Modules (Get-DefaultModules) -Template $script:template
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
        @{ Mutation = 'root-only'; Replacement = '/metadata.json @Azure/azure-verified-modules-engineering-owners @Azure/azure-verified-modules-module-owners' }
        @{ Mutation = 'additional owners'; Replacement = 'metadata.json @Azure/azure-verified-modules-engineering-owners @Azure/azure-verified-modules-module-owners @alice' }
        @{ Mutation = 'non-final'; Replacement = "metadata.json @Azure/azure-verified-modules-engineering-owners @Azure/azure-verified-modules-module-owners`n* @alice" }
        @{ Mutation = 'missing module owners'; Replacement = 'metadata.json @Azure/azure-verified-modules-engineering-owners' }
        @{ Mutation = 'missing engineering owners'; Replacement = 'metadata.json @Azure/azure-verified-modules-module-owners' }
    ) {
        $template = $script:template.Replace($script:metadataRule, $Replacement)
        { ConvertTo-AvmBicepCodeowners -Modules (Get-DefaultModules) -Template $template } | Should -Throw '*static ownership contract*'
        { Assert-AvmCodeownersContent -Content $script:rendered -Template $template -AllowLegacyDefault } |
            Should -Throw '*static ownership contract*'
    }

    It 'rejects changed metadata ownership or precedence in old and new content' -ForEach @(
        @{ Replacement = 'metadata.json @alice' }
        @{ Replacement = 'metadata.json @Azure/azure-verified-modules-engineering-owners @Azure/azure-verified-modules-module-owners @alice' }
        @{ Replacement = '/metadata.json @Azure/azure-verified-modules-engineering-owners @Azure/azure-verified-modules-module-owners' }
        @{ Replacement = "metadata.json @Azure/azure-verified-modules-engineering-owners @Azure/azure-verified-modules-module-owners`n* @alice" }
        @{ Replacement = "metadata.json @Azure/azure-verified-modules-engineering-owners @Azure/azure-verified-modules-module-owners`nmetadata.json @Azure/azure-verified-modules-engineering-owners @Azure/azure-verified-modules-module-owners" }
        @{ Replacement = 'metadata.json @Azure/azure-verified-modules-engineering-owners' }
        @{ Replacement = 'metadata.json @Azure/azure-verified-modules-module-owners' }
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
        $content = ConvertTo-AvmBicepCodeowners -Modules (Get-DefaultModules) -Template $template
        $content | Should -Match ([regex]::Escape('# $(throw "do not execute")'))
        { Assert-AvmCodeownersContent -Content $content -Template $template } | Should -Not -Throw
    }

    It 'refuses missing, duplicate, or inline placeholders' -ForEach @('', "__AVM_MODULE_OWNERS__`n__AVM_MODULE_OWNERS__", '# __AVM_MODULE_OWNERS__') {
        $template = $script:template.Replace('__AVM_MODULE_OWNERS__', $_)
        { ConvertTo-AvmBicepCodeowners -Modules (Get-DefaultModules) -Template $template } | Should -Throw '*placeholder*'
    }

    It 'refuses a placeholder after the final tooling override' {
        $template = $script:template.Replace("__AVM_MODULE_OWNERS__`n", '') + "__AVM_MODULE_OWNERS__`n"
        { ConvertTo-AvmBicepCodeowners -Modules (Get-DefaultModules) -Template $template } | Should -Throw '*final tooling overrides*'
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
        { ConvertTo-AvmBicepCodeowners -Modules (Get-DefaultModules) -Template $template } | Should -Throw '*3 MB*'
    }
}
