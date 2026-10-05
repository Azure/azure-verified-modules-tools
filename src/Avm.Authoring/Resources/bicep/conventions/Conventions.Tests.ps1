#Requires -Version 7.4

# Packaged Bicep convention checks. Invoke-AvmBicepCheckConvention prepares all
# compiler, git and network input before this suite runs; each test evaluates one
# rule family and records its findings in $Convention.Findings.
param(
    [Parameter(Mandatory)]
    [System.Collections.IDictionary] $Convention
)

$compiledCases = @(foreach ($module in @($Convention.CompiledModules)) {
        @{ Module = $module; Label = $module.Scope.ModuleRelativePath }
    })
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
    if ($compiledCases.Count -gt 0) {
        Context 'Compiled templates' {
            It 'resource API versions' {
                Invoke-ConventionRule -RuleName 'ApiVersion' -RuleBlock {
                    Test-AvmBicepConventionApiVersion -Root $Convention.Root `
                        -Modules @($Convention.CompiledModules) -ApiSpecs $Convention.ApiSpecs `
                        -ApiSpecsUnavailableReason $Convention.ApiSpecsUnavailableReason
                }
            }
        }
    }

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
        Context 'Versions' {
            It '<Label> version' -ForEach $scopeCases {
                Invoke-ConventionRule -RuleName 'Version' -RuleBlock {
                    Test-AvmBicepConventionVersion -Root $Convention.Root -Scope $Scope
                }
            }
        }

        Context 'E2e test files' {
            It '<Label> test files' -ForEach $scopeCases {
                Invoke-ConventionRule -RuleName 'TestFile' -RuleBlock {
                    Test-AvmBicepConventionTestFile -Root $Convention.Root -Scope $Scope `
                        -ServiceShortIndex $Convention.ServiceShortIndex `
                        -CompiledTestFiles $Convention.CompiledTests
                }
            }
        }

        Context 'Repository' {
            It 'child module publishing' {
                Invoke-ConventionRule -RuleName 'ChildPublish' -RuleBlock {
                    Test-AvmBicepConventionChildPublish -RepositoryRoot $Convention.RepositoryRoot `
                        -Scopes @($Convention.Scopes)
                }
            }

            It 'publication versions and changelogs' {
                Invoke-ConventionRule -RuleName 'Publication' -RuleBlock {
                    Test-AvmBicepConventionPublication -RepositoryRoot $Convention.RepositoryRoot `
                        -PublicationInput $Convention.Publication
                }
            }
        }
    }
}
