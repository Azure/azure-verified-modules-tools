#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
#Requires -Modules @{ ModuleName = 'PSScriptAnalyzer'; ModuleVersion = '1.21.0' }

# Spec section 14 mandates the typed-exception throw pattern. This file
# tests the custom PSSA rule `AvmAvoidStringThrow` that enforces it. The
# rule lives at src/Avm.Authoring/Resources/CustomRules/AvmAvoidStringThrow.psm1
# and is wired into `./build.ps1 lint` via the -CustomRulePath argument.

BeforeAll {
    $script:repoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', '..', '..')).Path
    $script:rulePath = Join-Path -Path $script:repoRoot -ChildPath 'src' -AdditionalChildPath 'Avm.Authoring', 'Resources', 'CustomRules', 'AvmAvoidStringThrow.psm1'

    function script:Invoke-AvmRule {
        param(
            [Parameter(Mandatory = $true)]
            [string]
            $Script
        )
        $records = Invoke-ScriptAnalyzer `
            -ScriptDefinition $Script `
            -CustomRulePath $script:rulePath `
            -IncludeRule 'Measure-AvmAvoidStringThrow'
        return @($records)
    }
}

Describe 'AvmAvoidStringThrow' {
    It 'rule file exists on disk at the expected location' {
        Test-Path -LiteralPath $script:rulePath | Should -BeTrue
    }

    It 'is discoverable by PSScriptAnalyzer via -CustomRulePath' {
        $rules = Get-ScriptAnalyzerRule -CustomRulePath $script:rulePath -ErrorAction Stop
        $matchedRules = @($rules | Where-Object { $_.RuleName -eq 'Measure-AvmAvoidStringThrow' })
        $matchedRules.Count | Should -Be 1
    }

    Context 'flags string-literal throws' {
        It 'flags a single-quoted string throw' {
            $records = @(script:Invoke-AvmRule -Script "throw 'oops'")
            $records.Count | Should -Be 1
            $records[0].RuleName | Should -Be 'AvmAvoidStringThrow'
            $records[0].Severity | Should -Be 'Warning'
            $records[0].Message  | Should -Match 'string literal'
        }

        It 'flags a double-quoted expandable string throw' {
            $records = @(script:Invoke-AvmRule -Script 'throw "boom $foo"')
            $records.Count | Should -Be 1
            $records[0].RuleName | Should -Be 'AvmAvoidStringThrow'
        }

        It 'flags every string throw in a multi-statement script' {
            $source = @'
throw 'first'
function Foo { throw "second" }
'@
            $records = @(script:Invoke-AvmRule -Script $source)
            $records.Count | Should -Be 2
        }

        It 'flags a string throw nested inside a catch block' {
            $source = "try { Get-Process } catch { throw 'wrapped' }"
            $records = @(script:Invoke-AvmRule -Script $source)
            $records.Count | Should -Be 1
        }
    }

    Context 'allows the canonical typed-exception pattern' {
        It 'allows throw of a constructed exception with a message' {
            $records = @(script:Invoke-AvmRule -Script "throw [System.IO.IOException]::new('boom')")
            $records.Count | Should -Be 0
        }

        It 'allows throw of a constructed exception with a message and inner exception' {
            $source = "throw [System.InvalidOperationException]::new('boom', `$inner)"
            $records = @(script:Invoke-AvmRule -Script $source)
            $records.Count | Should -Be 0
        }
    }

    Context 'allows other non-literal throw shapes' {
        It 'allows a bare re-throw inside a catch block' {
            $records = @(script:Invoke-AvmRule -Script "try { Get-Process } catch { throw }")
            $records.Count | Should -Be 0
        }

        It 'allows throwing the caught error variable' {
            $source = "try { Get-Process } catch { throw `$_ }"
            $records = @(script:Invoke-AvmRule -Script $source)
            $records.Count | Should -Be 0
        }

        It 'allows throwing a pre-constructed exception held in a variable' {
            $source = @'
$ex = [System.ArgumentException]::new('bad')
throw $ex
'@
            $records = @(script:Invoke-AvmRule -Script $source)
            $records.Count | Should -Be 0
        }
    }
}
