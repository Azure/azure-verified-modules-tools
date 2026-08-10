function Get-AvmReservedContextAncestor {
    <#
    .SYNOPSIS
        Identify a reserved directory segment in a requested path chain.
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

    $directory = [System.IO.DirectoryInfo]::new($Path)
    while ($null -ne $directory) {
        if ($reservedNames -contains $directory.Name) {
            return [pscustomobject]@{
                ReservedName = $directory.Name
                ReservedPath = $directory.FullName
            }
        }

        $directory = $directory.Parent
    }

    return $null
}
