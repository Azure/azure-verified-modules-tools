#Requires -Version 7.4

<#
.SYNOPSIS
    PSScriptAnalyzer custom rule that flags `throw 'literal'` / `throw "literal"`.

.DESCRIPTION
    Spec section 14 ("Error handling") mandates that terminating errors use
    the typed-exception pattern:

        throw [<SpecificException>]::new(<message>, <innerException>)

    Generic string throws are reserved for prototype code and trigger this
    rule. The rule flags:

      * `throw 'one'`              (StringConstantExpressionAst)
      * `throw "two $var"`         (ExpandableStringExpressionAst)

    The rule does NOT flag:

      * bare `throw`               (no Pipeline; canonical re-throw)
      * `throw $err`               (a variable can hold an exception object)
      * `throw [Type]::new(...)`   (the canonical pattern)
      * `throw (Get-Foo)` or other expression shapes (member access, calls, etc.)

    Wired into PSScriptAnalyzer via the `-CustomRulePath` argument added by
    the `lint` Invoke-Build task (see `build/avm.build.ps1`). The rule lives
    under `Resources/CustomRules/` so it ships with the module but is loaded
    only by PSSA, not by the Avm.Authoring root manifest.

    PSSA convention: the function name must start with `Measure-` for the
    rule loader to pick it up. The diagnostic record's `RuleName` is what
    surfaces in violation reports (`AvmAvoidStringThrow`).
#>

function Measure-AvmAvoidStringThrow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.Management.Automation.Language.ScriptBlockAst]
        $ScriptBlockAst
    )

    process {
        $results = [System.Collections.Generic.List[object]]::new()

        # PSSA calls the rule once per ScriptBlockAst (file root + every nested
        # function / scriptblock). Only process at the root so each throw is
        # reported exactly once when FindAll walks descendants.
        if ($null -ne $ScriptBlockAst.Parent) {
            return $results.ToArray()
        }

        $stringAst = [System.Management.Automation.Language.StringConstantExpressionAst]
        $expandableAst = [System.Management.Automation.Language.ExpandableStringExpressionAst]

        $throws = $ScriptBlockAst.FindAll({
                param($ast)
                $ast -is [System.Management.Automation.Language.ThrowStatementAst]
            }, $true)

        foreach ($throwAst in $throws) {
            $pipeline = $throwAst.Pipeline
            if (-not $pipeline) { continue }

            $expr = $null
            if ($pipeline -is [System.Management.Automation.Language.PipelineAst]) {
                $first = $pipeline.PipelineElements | Select-Object -First 1
                if ($first -is [System.Management.Automation.Language.CommandExpressionAst]) {
                    $expr = $first.Expression
                }
            }
            if (-not $expr) { continue }
            if ($expr -isnot $stringAst -and $expr -isnot $expandableAst) { continue }

            $record = [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]@{
                Message  = "Do not 'throw' a string literal. Use 'throw [<SpecificException>]::new(<message>, <innerException>)' instead (spec section 14)."
                Extent   = $throwAst.Extent
                RuleName = 'AvmAvoidStringThrow'
                Severity = 'Warning'
            }

            $null = $results.Add($record)
        }

        return $results.ToArray()
    }
}

Export-ModuleMember -Function Measure-AvmAvoidStringThrow
