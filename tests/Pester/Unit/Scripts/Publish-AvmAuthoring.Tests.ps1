#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Spec section 17 line 548 compliance regression guard for the publish script.
# These tests AST-parse `scripts/Publish-AvmAuthoring.ps1` and assert the
# `$ApiKey` parameter is `[SecureString]` (not `[string]`), the boundary
# conversion is present at the `Publish-PSResource -ApiKey` call site, and no
# regression introduces a `[string]`-typed ApiKey parameter or a direct
# `-ApiKey $ApiKey` argument-binding shape.
#
# Mirrors the Slice K path-shape regression test pattern in
# `tests/Pester/Unit/Private/Assets/Resolve-AvmPinnedAsset.Tests.ps1`
# (Describe 'Resolve-AvmPinnedAsset spec section 6 path-shape compliance').

BeforeAll {
    $script:ScriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))) 'scripts' 'Publish-AvmAuthoring.ps1'

    if (-not (Test-Path -LiteralPath $script:ScriptPath)) {
        throw "Publish-AvmAuthoring.ps1 not found at expected path '$script:ScriptPath'."
    }

    $script:ParseTokens = $null
    $script:ParseErrors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath,
        [ref] $script:ParseTokens,
        [ref] $script:ParseErrors
    )

    # Locate the script-level param block. Publish-AvmAuthoring.ps1 declares
    # [CmdletBinding(SupportsShouldProcess = $true)] then a script param().
    $script:ParamBlock = $script:Ast.ParamBlock

    if ($null -ne $script:ParamBlock) {
        $script:ApiKeyParam = $script:ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'ApiKey' } |
            Select-Object -First 1
    }
}

Describe 'Publish-AvmAuthoring.ps1 spec section 17 SecureString compliance' {

    It 'parses without errors' {
        @($script:ParseErrors).Count | Should -Be 0
    }

    It 'declares a script-level param() block with an ApiKey parameter' {
        $script:ParamBlock | Should -Not -BeNullOrEmpty
        $script:ApiKeyParam | Should -Not -BeNullOrEmpty
    }

    It 'types the ApiKey parameter as [SecureString], not [string]' {
        # Spec section 17 line 548: the publish script accepts the API key as
        # [SecureString] ONLY. The previous shape ([string]) is the deviation
        # Slice M closes.
        $typeName = $script:ApiKeyParam.StaticType.FullName
        $typeName | Should -Be 'System.Security.SecureString'
        $typeName | Should -Not -Be 'System.String'
    }

    It 'marks the ApiKey parameter as Mandatory' {
        $mandatoryAttr = $script:ApiKeyParam.Attributes |
            Where-Object { $_.TypeName.FullName -eq 'Parameter' -or $_.TypeName.FullName -eq 'System.Management.Automation.ParameterAttribute' }
        $mandatoryAttr | Should -Not -BeNullOrEmpty

        # Walk the [Parameter(...)] named arguments and find Mandatory = $true.
        $mandatoryArg = $mandatoryAttr.NamedArguments |
            Where-Object { $_.ArgumentName -eq 'Mandatory' } |
            Select-Object -First 1
        $mandatoryArg | Should -Not -BeNullOrEmpty
        $mandatoryArg.Argument.SafeGetValue() | Should -BeTrue
    }

    It 'converts the SecureString at the Publish-PSResource boundary via ConvertFrom-SecureString -AsPlainText' {
        # The PSResourceGet API takes a plain [string] -ApiKey. The boundary
        # conversion MUST be ConvertFrom-SecureString -AsPlainText (or the
        # equivalent [System.Net.NetworkCredential]::new('', $key).Password
        # idiom). We pin the canonical form here so anyone removing the
        # conversion (which would re-introduce a [string]-typed parameter for
        # the script) trips this test.
        $commandAsts = $script:Ast.FindAll({
            param($ast)
            $ast -is [System.Management.Automation.Language.CommandAst]
        }, $true)

        $convertCalls = $commandAsts | Where-Object {
            $first = $_.CommandElements[0]
            ($first -is [System.Management.Automation.Language.StringConstantExpressionAst]) -and
            ($first.Value -eq 'ConvertFrom-SecureString')
        }
        @($convertCalls).Count | Should -BeGreaterThan 0

        $hasAsPlainText = $false
        foreach ($call in $convertCalls) {
            foreach ($el in $call.CommandElements) {
                if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and
                    $el.ParameterName -eq 'AsPlainText') {
                    $hasAsPlainText = $true
                }
            }
        }
        $hasAsPlainText | Should -BeTrue
    }

    It 'does not pass the SecureString directly as -ApiKey to Publish-PSResource' {
        # Regression guard: a future edit that swaps `-ApiKey $plainApiKey` for
        # `-ApiKey $ApiKey` would silently bind a [SecureString] to
        # PSResourceGet's [string] -ApiKey parameter, which the runtime
        # would .ToString() into the literal "System.Security.SecureString"
        # and PSGallery would reject. Pin the boundary explicitly.
        $commandAsts = $script:Ast.FindAll({
            param($ast)
            $ast -is [System.Management.Automation.Language.CommandAst]
        }, $true)

        $publishCalls = $commandAsts | Where-Object {
            $first = $_.CommandElements[0]
            ($first -is [System.Management.Automation.Language.StringConstantExpressionAst]) -and
            ($first.Value -eq 'Publish-PSResource')
        }
        @($publishCalls).Count | Should -BeGreaterThan 0

        foreach ($call in $publishCalls) {
            $elems = $call.CommandElements
            for ($i = 0; $i -lt $elems.Count; $i++) {
                $el = $elems[$i]
                if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and
                    $el.ParameterName -eq 'ApiKey') {
                    $valueAst = if ($i + 1 -lt $elems.Count) { $elems[$i + 1] } else { $null }
                    $valueAst | Should -Not -BeNullOrEmpty
                    if ($valueAst -is [System.Management.Automation.Language.VariableExpressionAst]) {
                        $valueAst.VariablePath.UserPath | Should -Not -Be 'ApiKey' -Because 'Publish-PSResource -ApiKey must receive the converted plain-text variable, not the SecureString parameter directly (PSResourceGet has no SecureString overload).'
                    }
                }
            }
        }
    }

    It 'nulls out the plain-text variable in a finally block after Publish-PSResource' {
        # Belt-and-braces: the plain-text window is bounded to the try/finally.
        # If a future edit drops the finally, the plain-text string lingers in
        # the function frame until GC. Pin the pattern.
        $tryStatements = $script:Ast.FindAll({
            param($ast)
            $ast -is [System.Management.Automation.Language.TryStatementAst]
        }, $true)
        @($tryStatements).Count | Should -BeGreaterThan 0

        $hasPlainApiKeyNullOut = $false
        foreach ($try in $tryStatements) {
            foreach ($catchClause in $try.Finally.Statements) {
                if ($catchClause.ToString() -match '\$plainApiKey\s*=\s*\$null') {
                    $hasPlainApiKeyNullOut = $true
                }
            }
        }
        $hasPlainApiKeyNullOut | Should -BeTrue
    }
}
