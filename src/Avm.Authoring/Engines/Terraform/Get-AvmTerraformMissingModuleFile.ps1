function Get-AvmTerraformMissingModuleFile {
    <#
    .SYNOPSIS
        List the minimum Terraform module files that a repository's main branch lacks.
    .DESCRIPTION
        Checks the files the AVM convention rules require at the module root:
        a non-empty terraform.tf, _header.md, at least one example directory,
        and a tests directory. Returns an empty array when all are present.
    .PARAMETER Root
        Entries of the root tree from the GitHub Git trees API, with path,
        type, and size.
    .PARAMETER Examples
        Entries of the examples tree, if the root has one.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Root,

        [AllowEmptyCollection()]
        [object[]] $Examples = @()
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $find = {
        param([object[]] $Entries, [string] $Type, [string] $Path)
        @($Entries | Where-Object {
                $_ -is [System.Collections.IDictionary] -and $_['type'] -ceq $Type -and (-not $Path -or $_['path'] -ceq $Path)
            })
    }
    $missing = @(
        if (@(& $find $Root 'blob' 'terraform.tf' | Where-Object { [long]$_['size'] -gt 0 }).Count -eq 0) { 'terraform.tf' }
        if (@(& $find $Root 'blob' '_header.md').Count -eq 0) { '_header.md' }
        if (@(& $find $Examples 'tree').Count -eq 0) { 'examples/<name>/' }
        if (@(& $find $Root 'tree' 'tests').Count -eq 0) { 'tests/' }
    )
    return [string[]]$missing
}