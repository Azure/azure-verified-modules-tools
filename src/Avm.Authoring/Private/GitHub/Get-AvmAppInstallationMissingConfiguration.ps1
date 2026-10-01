function Get-AvmAppInstallationMissingConfiguration {
    <#
    .SYNOPSIS
        Return the app installation files on the operations repository's main branch that do not list a repository.
    .PARAMETER Repository
        Module repository name without the organization.
    .PARAMETER OperationsRepository
        Repository holding the app configuration files, as owner/name.
    .PARAMETER ConfigurationPath
        App configuration files to check.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Repository,

        [string] $OperationsRepository = 'microsoft/github-operations',

        [string[]] $ConfigurationPath = @(
            'apps/azure/azure-verified-modules.yaml',
            'apps/azure/terraform-cloud.yaml'
        )
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($path in $ConfigurationPath) {
        $file = Invoke-AvmGitHubApi -Endpoint "repos/$OperationsRepository/contents/$($path)?ref=main"
        $text = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(([string]$file['content'] -replace '\s', '')))
        if (-not (Get-AvmAppInstallationListContent -Content $text -Repository $Repository).Listed) {
            $missing.Add($path)
        }
    }
    return $missing.ToArray()
}
