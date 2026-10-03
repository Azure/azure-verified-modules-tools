function Get-AvmTflintRootModuleClass {
    <#
    .SYNOPSIS
        Determine the root's module class before configuring resource-only rules.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $classes = @{ res = 'resource'; ptn = 'pattern'; utl = 'utility' }
    $identities = [System.Collections.Generic.List[string]]::new()
    $explicitId = [string]$env:AVM_MANAGED_FILES_REPO_ID
    if (-not [string]::IsNullOrWhiteSpace($explicitId)) {
        if ($explicitId -cnotmatch '^avm-(?<kind>res|ptn|utl)-[a-z0-9-]+$') {
            throw [AvmConfigurationException]::new(
                "AVM_MANAGED_FILES_REPO_ID must identify an AVM Terraform resource, pattern, or utility module.")
        }
        $identities.Add($Matches.kind)
    }

    $leaf = [System.IO.Path]::GetFileName(
        [System.IO.Path]::TrimEndingDirectorySeparator($Context.Root))
    $folderId = ConvertTo-AvmManagedFilesRepoId -Name $leaf
    if ($folderId -cmatch '^avm-(?<kind>res|ptn|utl)-[a-z0-9-]+$') {
        $identities.Add($Matches.kind)
    }
    if (Test-Path -LiteralPath (Join-Path $Context.Root '.git')) {
        $git = Get-Command -Name git -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $remote = Invoke-AvmProcess -FilePath $git.Source -ArgumentList @('config', '--get', 'remote.origin.url') `
            -WorkingDirectory $Context.Root -IgnoreExitCode
        if ($remote.ExitCode -notin @(0, 1)) {
            throw [AvmConfigurationException]::new(
                "Cannot read the Terraform repository identity: $($remote.StdErr)")
        }
        $originId = ConvertTo-AvmManagedFilesRepoId -Name (Get-AvmRepoLeafFromUrl -Url $remote.StdOut)
        if ($originId -cmatch '^avm-(?<kind>res|ptn|utl)-[a-z0-9-]+$') {
            $identities.Add($Matches.kind)
        }
    }
    $scope = if ($Context.PSObject.Properties['Scope']) { [string]$Context.Scope } else { '' }
    if ($classes.ContainsKey($scope)) {
        $identities.Add($scope)
    }

    $distinct = @($identities | Sort-Object -Unique)
    if ($distinct.Count -gt 1) {
        throw [AvmConfigurationException]::new(
            "The Terraform repository identity and declared scope disagree on module class for '$($Context.Root)'.")
    }
    $moduleClass = if ($distinct.Count -gt 0) { $classes[$distinct[0]] } else { 'resource' }
    if ($moduleClass -ne 'resource') {
        $metadata = Test-AvmModuleMetadata -Path $Context.Root -Ecosystem terraform `
            -ModuleType $moduleClass -SkipModuleVersionCheck
        if ($metadata.Status -cne 'pass') {
            $details = @($metadata.Issues | ForEach-Object { $_.Message }) -join '; '
            throw [AvmConfigurationException]::new(
                "Cannot apply TFLint module_class '$moduleClass' to '$($Context.Root)': $details")
        }
    }

    return $moduleClass
}
