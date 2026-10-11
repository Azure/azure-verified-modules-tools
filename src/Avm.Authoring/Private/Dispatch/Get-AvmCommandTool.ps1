function Get-AvmCommandTool {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('pre-commit', 'pr-check')]
        [string] $Command,

        [Parameter(Mandatory)]
        [ValidateSet('bicep', 'terraform')]
        [string] $Ecosystem,

        [string[]] $ExcludeSteps = @()
    )

    $tools = switch ("$Command/$Ecosystem") {
        'pre-commit/bicep' { @('bicep', 'Pester') }
        'pre-commit/terraform' { @('mapotf', 'terraform', 'terraform-docs', 'Pester') }
        'pr-check/bicep' { @('bicep', 'Pester', 'powershell-yaml', 'PSRule', 'PSRule.Rules.Azure') }
        'pr-check/terraform' { @('conftest', 'mapotf', 'terraform', 'terraform-docs', 'tflint', 'Pester') }
    }

    if ($Command -eq 'pr-check' -and $ExcludeSteps.Count -gt 0) {
        $requiredBy = switch ($Ecosystem) {
            'bicep' {
                @{
                    'bicep'              = @('format', 'transform', 'lint', 'check policy', 'check convention', 'validate', 'docs')
                    'Pester'             = @('metadata', 'check convention', 'docs')
                    'powershell-yaml'    = @('check convention')
                    'PSRule'             = @('check policy')
                    'PSRule.Rules.Azure' = @('check policy')
                }
            }
            'terraform' {
                @{
                    'conftest'       = @('check policy')
                    'mapotf'         = @('transform')
                    'terraform'      = @('format', 'transform', 'lint', 'check policy', 'validate')
                    'terraform-docs' = @('docs')
                    'tflint'         = @('lint')
                    'Pester'         = @('metadata')
                }
            }
        }
        $tools = @($tools | Where-Object {
                @($requiredBy[$_] | Where-Object { $_ -notin $ExcludeSteps }).Count -gt 0
            })
    }

    return @($tools)
}

function Resolve-AvmCommandTool {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('pre-commit', 'pr-check')]
        [string] $Command,

        [Parameter(Mandatory)]
        [ValidateSet('bicep', 'terraform')]
        [string] $Ecosystem,

        [string] $ModuleRoot,

        [switch] $AllowPathFallback,

        [string[]] $ExcludeSteps = @()
    )

    $names = @(Get-AvmCommandTool -Command $Command -Ecosystem $Ecosystem -ExcludeSteps $ExcludeSteps)
    Write-AvmLog ('tools: resolving {0} requirement(s): {1}' -f $names.Count, ($names -join ', ')) -Level Install | Out-Null

    $resolved = [System.Collections.Generic.List[object]]::new()
    foreach ($name in $names) {
        $tool = Resolve-AvmTool -Name $name -ModuleRoot $ModuleRoot -AllowPathFallback:$AllowPathFallback
        if ($tool.PSObject.Properties['Kind'] -and $tool.Kind -ceq 'powershell-module') {
            $null = Import-AvmPowerShellModule -Name $name -ModuleRoot $ModuleRoot
        }
        $resolved.Add($tool)
        Write-AvmLog ('tools: ready {0}/{1} from {2}' -f $tool.Name, $tool.Version, $tool.Source) -Level Install | Out-Null
        Write-AvmLog ('tools: {0} path = {1}' -f $tool.Name, $tool.Path) -Level Verbose | Out-Null
    }

    Write-AvmLog 'tools: all requirements ready' -Level Pass | Out-Null
    return $resolved.ToArray()
}
