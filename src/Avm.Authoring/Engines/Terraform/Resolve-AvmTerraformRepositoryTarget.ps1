function Resolve-AvmTerraformRepositoryTarget {
    <#
    .SYNOPSIS
        Resolve the local directory and GitHub repository name for Terraform avm init.
    .DESCRIPTION
        An existing clone is identified by its origin remote. Otherwise the
        directory name is the repository name; when it is not a valid AVM
        Terraform repository name, an interactive user is asked for the name
        and the repository directory is created beneath the given path.
    .PARAMETER Path
        Repository directory, or its parent when prompting for the name.
    .PARAMETER ModuleType
        Module type the repository name must match.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [ValidateSet('resource', 'pattern', 'utility')]
        [string] $ModuleType
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $pattern = '^terraform-(?<provider>[a-z0-9]+)-avm-(?<kind>res|ptn|utl)-(?<suffix>[a-z0-9]+(?:-[a-z0-9]+)*)$'
    $example = 'terraform-azure-avm-res-storage-storageaccount'
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $root = $full
    $name = $null
    if (Test-Path -LiteralPath (Join-Path -Path $full -ChildPath '.git')) {
        $origin = Invoke-AvmGit -ArgumentList @('config', '--get', 'remote.origin.url') -WorkingDirectory $full -IgnoreExitCode
        if ($origin.ExitCode -eq 0) {
            $url = $origin.StdOut.Trim()
            $originMatch = [regex]::Match($url, '^(?:https://github\.com/|git@github\.com:)Azure/(?<name>[^/]+?)(?:\.git)?/?$')
            if (-not $originMatch.Success) {
                throw [System.ArgumentException]::new("$full is a clone of '$url', not of an Azure GitHub repository.")
            }
            $name = $originMatch.Groups['name'].Value
        }
    }
    if (-not $name) {
        $leaf = Split-Path -Path $full -Leaf
        if ($leaf -cmatch $pattern) {
            $name = $leaf
        }
        elseif (Test-AvmInteractiveHost) {
            $name = ([string](Read-Host -Prompt "Repository name (for example $example)")).Trim()
            $root = Join-Path -Path $full -ChildPath $name
        }
        else {
            throw [System.ArgumentException]::new(
                "The -Path folder name must be the repository name, for example $example.")
        }
    }

    $nameMatch = [regex]::Match($name, $pattern)
    if (-not $nameMatch.Success) {
        throw [System.ArgumentException]::new(
            "'$name' is not an AVM Terraform repository name. Use terraform-<provider>-avm-<res|ptn|utl>-<name>, for example $example.")
    }
    $kind = $nameMatch.Groups['kind'].Value
    $expected = @{ resource = 'res'; pattern = 'ptn'; utility = 'utl' }[$ModuleType]
    if ($kind -cne $expected) {
        throw [System.ArgumentException]::new(
            "Repository $name is an avm-$kind module, which does not match -ModuleType $ModuleType.")
    }
    return [pscustomobject][ordered]@{
        Root       = $root
        Name       = $name
        ModuleName = "avm-$kind-$($nameMatch.Groups['suffix'].Value)"
    }
}
