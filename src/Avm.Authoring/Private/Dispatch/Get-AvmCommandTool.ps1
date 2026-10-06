function Get-AvmCommandTool {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('pre-commit', 'pr-check')]
        [string] $Command,

        [Parameter(Mandatory)]
        [ValidateSet('bicep', 'terraform')]
        [string] $Ecosystem
    )

    $tools = switch ("$Command/$Ecosystem") {
        'pre-commit/bicep' { @('bicep', 'Pester') }
        'pre-commit/terraform' { @('mapotf', 'terraform', 'terraform-docs', 'Pester') }
        'pr-check/bicep' { @('bicep', 'Pester', 'powershell-yaml', 'PSRule', 'PSRule.Rules.Azure') }
        'pr-check/terraform' { @('conftest', 'mapotf', 'terraform', 'terraform-docs', 'tflint', 'Pester') }
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

        [switch] $AllowPathFallback
    )

    $names = @(Get-AvmCommandTool -Command $Command -Ecosystem $Ecosystem)
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
