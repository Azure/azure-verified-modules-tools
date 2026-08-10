function Get-AvmReservedContextAncestor {
    <#
    .SYNOPSIS
        Identify a requested path that is inside a reserved module folder.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    Set-StrictMode -Version 3.0

    $reservedNames = @(
        'examples',
        'modules',
        'tests',
        '.agents',
        '.avm',
        '.git',
        '.github',
        '.terraform',
        '.vscode'
    )

    $requested = [System.IO.DirectoryInfo]::new($Path)
    foreach ($depth in 0..1) {
        $reservedDirectory = if ($depth -eq 0) { $requested } else { $requested.Parent }
        if ($null -eq $reservedDirectory -or $reservedNames -notcontains $reservedDirectory.Name) {
            continue
        }

        $candidateRoot = $reservedDirectory.Parent
        if ($null -eq $candidateRoot) {
            continue
        }

        $signature = Get-AvmContextRootSignature -Path $candidateRoot.FullName
        if (
            $signature.HasTerraformSource -or
            $signature.HasBicepSource -or
            $signature.HasBicepMonorepo
        ) {
            return [pscustomobject]@{
                ReservedName = $reservedDirectory.Name
                ModuleRoot   = $candidateRoot.FullName
            }
        }
    }

    return $null
}
