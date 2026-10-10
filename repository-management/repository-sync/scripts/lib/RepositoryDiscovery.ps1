#Requires -Version 7.4

. (Join-Path $PSScriptRoot '..' '..' '..' 'shared' 'TestTenant.ps1')

function Get-RepositoryInstalledRepositories {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    $repositories = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $expectedCount = $null
    $page = 1
    do {
        $result = Invoke-RepositorySyncProcess -Command gh -Arguments @(
            'api', '--hostname', 'github.com', '--method', 'GET',
            "/installation/repositories?per_page=100&page=$page"
        )
        if ($result.ExitCode -ne 0) {
            throw [System.InvalidOperationException]::new("Cannot list the app's repositories: $($result.StdErr)")
        }
        $response = $result.StdOut | ConvertFrom-Json
        if (-not $response.PSObject.Properties['repositories'] -or
            -not $response.PSObject.Properties['total_count'] -or $response.total_count -lt 0) {
            throw [System.IO.InvalidDataException]::new('GitHub returned an invalid app repository list.')
        }
        if ($null -eq $expectedCount) {
            $expectedCount = $response.total_count
        }
        elseif ($expectedCount -ne $response.total_count) {
            throw [System.IO.InvalidDataException]::new('The app repository list changed during pagination. Retry discovery.')
        }
        $items = @($response.repositories)
        if ($items.Count -gt 100 -or ($items.Count -eq 0 -and $repositories.Count -lt $expectedCount)) {
            throw [System.IO.InvalidDataException]::new('GitHub returned an incomplete app repository list.')
        }
        foreach ($repository in $items) {
            if (-not $repository.PSObject.Properties['full_name'] -or
                [string]::IsNullOrWhiteSpace($repository.full_name) -or -not $seen.Add($repository.full_name)) {
                throw [System.IO.InvalidDataException]::new('GitHub returned an invalid or duplicate installed repository.')
            }
            $repositories.Add($repository)
        }
        $page++
    } while (($page - 1) * 100 -lt $expectedCount)
    if ($repositories.Count -ne $expectedCount) {
        throw [System.IO.InvalidDataException]::new('GitHub app repository count does not match its total.')
    }

    $identityOwners = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($repository in $repositories) {
        if ($repository.full_name -inotmatch '^[A-Za-z0-9-]+/terraform-(azure|azurerm|azapi)-avm-(res|ptn|utl)-[a-z0-9]+(-[a-z0-9]+)*$') {
            continue
        }
        $identityName = Get-AvmTestIdentityName -Repository $repository.full_name
        if ($identityOwners.ContainsKey($identityName)) {
            throw [System.InvalidOperationException]::new(
                "Repositories '$($identityOwners[$identityName])' and '$($repository.full_name)' normalize to the same test identity '$identityName'; repository sync is blocked."
            )
        }
        $identityOwners.Add($identityName, $repository.full_name)
    }

    return $repositories.ToArray()
}

function Get-RepositoryTerraformModuleIdentity {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [string[]] $ValidProviders = @('azure', 'azurerm', 'azapi')
    )

    $providerPattern = ($ValidProviders | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $pattern = "^terraform-($providerPattern)-(?<module>avm-(?<kind>res|ptn|utl)-[a-z0-9-]+)$"
    $nameMatch = [regex]::Match($Name, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $nameMatch.Success) {
        return $null
    }
    $moduleTypes = @{ res = 'resource'; ptn = 'pattern'; utl = 'utility' }
    return @{
        ModuleName = $nameMatch.Groups['module'].Value
        ModuleType = $moduleTypes[$nameMatch.Groups['kind'].Value]
    }
}
