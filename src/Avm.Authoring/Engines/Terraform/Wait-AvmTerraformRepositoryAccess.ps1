function Wait-AvmTerraformRepositoryAccess {
    <#
    .SYNOPSIS
        Wait for the operator to finish open source portal setup or JIT elevation.
    .DESCRIPTION
        Portal setup is complete once the repository is visible and public.
        Elevation is complete once the caller has administrator permission.
        Returns the repository when the requirement is met. Otherwise writes
        the instructions and, in an interactive session, re-checks GitHub each
        time the operator confirms. Returns $null when the session is not
        interactive or the operator stops, so a later run can resume.
    .PARAMETER Repository
        Repository as owner/name.
    .PARAMETER ModuleName
        Module name used in the portal answers.
    .PARAMETER Requirement
        PortalSetup or Elevation.
    .PARAMETER AlwaysPrompt
        Show the instructions and wait for confirmation even when GitHub
        already reports the requirement as met.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)]
        [string] $Repository,

        [Parameter(Mandatory)]
        [string] $ModuleName,

        [Parameter(Mandatory)]
        [ValidateSet('PortalSetup', 'Elevation')]
        [string] $Requirement,

        [switch] $AlwaysPrompt
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $test = if ($Requirement -eq 'PortalSetup') {
        { param($repository) $null -ne $repository -and [string]$repository['visibility'] -eq 'public' }
    }
    else {
        {
            param($repository)
            $null -ne $repository -and $repository['permissions'] -is [System.Collections.IDictionary] -and
            $repository['permissions']['admin'] -eq $true
        }
    }
    $current = Invoke-AvmGitHubApi -Endpoint "repos/$Repository" -AllowNotFound
    if (-not $AlwaysPrompt -and (& $test $current)) {
        return $current
    }

    $portal = "https://repos.opensource.microsoft.com/orgs/Azure/repos/$(($Repository -split '/')[-1])"
    $lines = if ($Requirement -eq 'PortalSetup') {
        @(
            "Complete the open source portal setup for $($Repository):"
            "  1. Open $portal"
            "  2. Select 'Complete Setup' (or the Compliance tab) and enter:"
            '       Classification: Production'
            '       Service tree: Azure Verified Modules (AVM)'
            '       Type of open source project: Sample code'
            '       License: MIT'
            "       Project name: Azure Verified Module (Terraform) for '$ModuleName'"
            '       Project version: 1'
            "       Project description: Azure Verified Module (Terraform) for '$ModuleName'. Part of AVM project - https://aka.ms/avm"
            '       Business goals: Create IaC module accelerating Azure deployment using Microsoft best practice.'
            '       Used in a Microsoft product or service: Open source, can be leveraged in Microsoft services.'
            "     Uncheck 'Repository template' and 'Add .gitignore'."
            "  3. Select 'Elevate your access' to elevate with just-in-time (JIT) access."
            '  All answers: https://azure.github.io/Azure-Verified-Modules/contributing/terraform/repository-setup/'
        )
    }
    else {
        @(
            "Elevate your access to $Repository with just-in-time (JIT) access:"
            "  Open $portal and select 'Elevate your access'."
            '  Administrator access is needed to grant team access and publish the initial commit.'
        )
    }
    foreach ($line in $lines) {
        Write-AvmLog $line -Level Info
    }
    if (-not (Test-AvmInteractiveHost)) {
        return $null
    }

    while ($true) {
        $answer = ([string](Read-Host -Prompt "Type 'yes' when this is done, or 'no' to stop")).Trim()
        if ($answer -imatch '^(n|no|q|quit|stop)$') {
            return $null
        }
        if ($answer -inotmatch '^(y|yes)$') {
            continue
        }
        $current = Invoke-AvmGitHubApi -Endpoint "repos/$Repository" -AllowNotFound
        if (& $test $current) {
            return $current
        }
        $pending = if ($Requirement -eq 'PortalSetup') {
            "$Repository is not public and visible to you yet. Finish the portal setup, then type 'yes'."
        }
        else {
            "You do not have administrator access to $Repository yet. Elevate with JIT, then type 'yes'."
        }
        Write-AvmLog $pending -Level Warning
    }
}
