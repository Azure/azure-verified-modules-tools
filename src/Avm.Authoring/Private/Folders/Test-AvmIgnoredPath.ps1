function Test-AvmIgnoredPath {
    <#
    .SYNOPSIS
        Report whether a path lives inside a build-artifact directory that
        module discovery must skip.

    .DESCRIPTION
        AVM module repositories carry generated trees that are gitignored but
        still present on disk: '.terraform/' populated by 'terraform init',
        '.git/', '.avm/' and the like, plus 'node_modules/'. Discovery that
        walks a module tree has to ignore them, because their contents are
        neither authored nor fixable by the module author.

        A path is ignored when any segment of its path relative to $Root
        begins with '.' or equals 'node_modules'. The same predicate is applied
        inline by Get-AvmTerraformFile and Invoke-AvmTerraformTest.

        $Root itself is never ignored, even when it sits below such a
        directory: the caller has already chosen it as the walk origin.

    .PARAMETER Root
        Absolute path the walk started from. Segments at or above it are not
        considered.

    .PARAMETER Path
        The path to test, at or below $Root.

    .OUTPUTS
        [bool] true when the path should be skipped.

    .EXAMPLE
        PS> Test-AvmIgnoredPath -Root 'C:\repo' -Path 'C:\repo\modules\slot\.terraform\modules'
        True
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [string] $Path
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $relative = [System.IO.Path]::GetRelativePath($Root, $Path)
    foreach ($segment in ($relative -split '[\\/]')) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -eq '.' -or $segment -eq '..') {
            continue
        }

        if ($segment.StartsWith('.') -or $segment -eq 'node_modules') {
            return $true
        }
    }

    return $false
}
