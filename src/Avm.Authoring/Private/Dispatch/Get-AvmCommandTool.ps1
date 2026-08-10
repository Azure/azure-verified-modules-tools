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
        'pre-commit/bicep' { @('bicep') }
        'pre-commit/terraform' { @('mapotf', 'terraform', 'terraform-docs') }
        'pr-check/bicep' { @('bicep') }
        'pr-check/terraform' { @('conftest', 'mapotf', 'terraform', 'terraform-docs', 'tflint') }
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

        [switch] $AllowPathFallback
    )

    $names = @(Get-AvmCommandTool -Command $Command -Ecosystem $Ecosystem)
    Write-AvmLog ('tools: resolving {0} requirement(s): {1}' -f $names.Count, ($names -join ', ')) -Level Install | Out-Null

    $resolved = [System.Collections.Generic.List[object]]::new()
    foreach ($name in $names) {
        $tool = Resolve-AvmTool -Name $name -AllowPathFallback:$AllowPathFallback
        $resolved.Add($tool)
        Write-AvmLog ('tools: ready {0}/{1} from {2}' -f $tool.Name, $tool.Version, $tool.Source) -Level Install | Out-Null
        Write-AvmLog ('tools: {0} path = {1}' -f $tool.Name, $tool.Path) -Level Verbose | Out-Null
    }

    Write-AvmLog 'tools: all requirements ready' -Level Pass | Out-Null
    return $resolved.ToArray()
}
