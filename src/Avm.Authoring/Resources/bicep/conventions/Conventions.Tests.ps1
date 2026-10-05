#Requires -Version 7.4

# Packaged Bicep convention checks. Invoke-AvmBicepCheckConvention prepares all
# compiler, git and network input before this suite runs; each test evaluates one
# rule family and records its findings in $Convention.Findings.
param(
    [Parameter(Mandatory)]
    [System.Collections.IDictionary] $Convention
)

$scopeCases = @(foreach ($scope in @($Convention.Scopes)) {
        @{ Scope = $scope; Label = $scope.ModuleRelativePath }
    })

BeforeAll {
    foreach ($rule in @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'rules') -Filter '*.ps1' -File)) {
        . $rule.FullName
    }

    function Invoke-ConventionRule {
        param(
            [Parameter(Mandatory)]
            [string] $RuleName,

            [Parameter(Mandatory)]
            [scriptblock] $RuleBlock
        )

        try {
            $ruleIssues = @(& $RuleBlock)
        }
        catch {
            $Convention.Crashes.Add([pscustomobject]@{ Rule = $RuleName; Message = $_.Exception.Message })
            throw
        }
        foreach ($issue in $ruleIssues) {
            $Convention.Findings.Add($issue)
        }
        $errors = @($ruleIssues | Where-Object { $_.Severity -eq 'error' } |
                ForEach-Object { "$($_.Code): $($_.Message)" })
        $errors | Should -HaveCount 0 -Because ($errors -join '; ')
    }
}

Describe 'Bicep conventions' {
    if ($scopeCases.Count -gt 0) {
        Context 'Module layout' {
            It '<Label> layout' -ForEach $scopeCases {
                Invoke-ConventionRule -RuleName 'Layout' -RuleBlock {
                    Test-AvmBicepConventionLayout -Root $Convention.Root -Scope $Scope
                }
            }
        }
    }

    if ($scopeCases.Count -gt 0) {
        Context 'Repository' {
            It 'publication versions and changelogs' {
                Invoke-ConventionRule -RuleName 'Publication' -RuleBlock {
                    Test-AvmBicepConventionPublication -RepositoryRoot $Convention.RepositoryRoot `
                        -PublicationInput $Convention.Publication
                }
            }
        }
    }
}
