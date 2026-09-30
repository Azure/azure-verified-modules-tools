function Get-AvmBicepConventionScope {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $normalized = [System.IO.Path]::GetFullPath($Path).Replace('\', '/')
    $identity = [regex]::Match(
        $normalized,
        '^(?<repository>.+)/(?<module>avm/(?<type>res|ptn|utl)/(?<name>[^/]+/[^/]+)(?<child>/.*)?)$')
    if (-not $identity.Success) {
        return $null
    }

    $scopeDirectories = @(
        Get-ChildItem -LiteralPath $Path -Directory -Force |
            Where-Object { $_.Name -cmatch '^(rg|sub|mg)-scope$' } |
            Sort-Object Name -CaseSensitive |
            ForEach-Object { $_.Name }
    )

    return [pscustomobject]@{
        Path               = $Path
        RepositoryRoot     = [System.IO.Path]::GetFullPath($identity.Groups['repository'].Value)
        ModuleRelativePath = $identity.Groups['module'].Value
        ModuleType         = $identity.Groups['type'].Value
        ModuleName         = $identity.Groups['name'].Value
        IsTopLevel         = -not $identity.Groups['child'].Success
        ScopeDirectories   = $scopeDirectories
    }
}
