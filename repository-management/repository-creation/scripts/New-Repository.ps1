#Requires -Version 7.4

[CmdletBinding(SupportsShouldProcess)]
param (
  [string]$tempPath = (Join-Path $PWD.Path 'out' 'repository-creation'),
  [string]$openSourceRepoUrl = "https://github.com/microsoft/github-operations",
  [string]$moduleProvider = "azure",
  [string]$moduleName,
  [string]$moduleDisplayName,
  [string]$moduleDescription,
  [string]$canonicalType,
  [string]$telemetryIdPrefix,
  [string]$resourceProviderNamespace,
  [string]$resourceType,
  [string]$moduleAlternativeNames = "",
  [string]$ownerPrimaryGitHubHandle,
  [string]$ownerSecondaryGitHubHandle = "",
  [string[]]$ownerGitHubHandles = @(),
  [string]$ownerTeam,
  [switch]$planOnly,
  [switch]$skipRepoCreation,
  [switch]$skipCreateAppInstallationRequest,
  [string[]]$yamlFilePaths = @(
    "./apps/azure/azure-verified-modules.yaml",
    "./apps/azure/terraform-cloud.yaml"
  )
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = "SilentlyContinue"

$moduleNameRegex = "^avm-(res|ptn|utl)-[a-z-]+$"
$moduleMatch = [regex]::Match($moduleName, $moduleNameRegex)
if (-not $moduleMatch.Success) {
  throw [System.ArgumentException]::new("Module name must be in the format '$moduleNameRegex'.")
}

if ([string]::IsNullOrWhiteSpace($moduleDisplayName)) {
  throw [System.ArgumentException]::new('Module display name must be provided.')
}

if($moduleDisplayName.Length -ge 250) {
  throw [System.ArgumentException]::new("Module display name must be under 250 characters (was $($moduleDisplayName.Length)).")
}

. (Join-Path $PSScriptRoot 'RepositoryCreation.ps1')
$authoringModule = Import-AvmRepositoryCreationModule
$moduleType = @{ res = 'resource'; ptn = 'pattern'; utl = 'utility' }[$moduleMatch.Groups[1].Value]
$repositoryName = "terraform-$moduleProvider-$moduleName"
$repositoryUrl = "https://github.com/Azure/$repositoryName"
$metadata = $null
$metadataPlan = $null

if (!$skipRepoCreation) {
  if ($moduleType -eq 'resource' -and
      (-not [string]::IsNullOrWhiteSpace($resourceProviderNamespace) -or -not [string]::IsNullOrWhiteSpace($resourceType))) {
    if ([string]::IsNullOrWhiteSpace($resourceProviderNamespace) -or [string]::IsNullOrWhiteSpace($resourceType)) {
      throw [System.ArgumentException]::new('Supply both resourceProviderNamespace and resourceType, or an explicit canonicalType.')
    }
    $resourceCanonicalType = "$resourceProviderNamespace/$resourceType"
    if (-not [string]::IsNullOrWhiteSpace($canonicalType) -and $canonicalType -cne $resourceCanonicalType) {
      throw [System.ArgumentException]::new('canonicalType conflicts with resourceProviderNamespace/resourceType.')
    }
    $canonicalType = $resourceCanonicalType
  }
  $metadataArguments = @{
    AuthoringModule = $authoringModule
    ModuleDisplayName = $moduleDisplayName
    ModuleDescription = $moduleDescription
    CanonicalType = $canonicalType
    TelemetryIdPrefix = if (-not [string]::IsNullOrWhiteSpace($telemetryIdPrefix)) { $telemetryIdPrefix }
    elseif ($moduleMatch.Groups[1].Value -ceq 'utl') { $telemetryIdPrefix }
    else {
        & $authoringModule.ExportedCommands['New-AvmTelemetryIdPrefix'] -Ecosystem terraform -Kind $moduleMatch.Groups[1].Value `
            -KnownPrefix (Get-AvmRepositoryCatalogTelemetryPrefix -AuthoringModule $authoringModule) -SkipModuleVersionCheck
    }
    OwnerGitHubHandles = @(
      if (-not [string]::IsNullOrEmpty($ownerPrimaryGitHubHandle)) { $ownerPrimaryGitHubHandle }
      if (-not [string]::IsNullOrEmpty($ownerSecondaryGitHubHandle)) { $ownerSecondaryGitHubHandle }
      $ownerGitHubHandles
    )
    OwnerTeam = $ownerTeam
    AlternativeNames = @(
      $moduleAlternativeNames -split ',' |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_.Length -gt 0 } |
        Select-Object -Unique
    )
  }
  $metadata = New-AvmRepositoryMetadataInput @metadataArguments
  $metadataPlan = New-AvmRepositoryContent -AuthoringModule $authoringModule -RepositoryName $repositoryName `
    -Metadata $metadata -ModuleType $moduleType -WorkPath $tempPath -PlanOnly
}

if ($planOnly -or -not $PSCmdlet.ShouldProcess($repositoryUrl, 'Run requested repository creation and app publication')) {
  return [pscustomobject]@{
    Status = 'plan'
    RepositoryUrl = $repositoryUrl
    Metadata = if ($null -ne $metadataPlan) { $metadataPlan.Metadata } else { $null }
    InitialPush = if ($null -ne $metadataPlan) { $metadataPlan.InitialPush } else { $null }
  }
}

& (Join-Path $PSScriptRoot 'Test-Tooling.ps1') -AuthoringModule $authoringModule

if (!$skipRepoCreation) {
  $portalSetup = {
    param($repository, $repositoryUrl)

    Write-Host ""
    Write-Host "Created $repositoryUrl" -ForegroundColor Green
    Write-Host "Azure locks new repositories down until open source portal setup completes." -ForegroundColor Yellow
    Write-Host "Complete the portal setup and elevate with JIT before the initial push." -ForegroundColor Yellow
    Write-Host ""

    Write-Host "Open https://repos.opensource.microsoft.com/orgs/Azure/repos/$repositoryName" -ForegroundColor Yellow
    if(!$env:CODESPACES) {
      Write-Host "Hit Enter to open the open source portal in your browser now" -ForegroundColor Yellow
      Read-Host
      Start-Process "https://repos.opensource.microsoft.com/orgs/Azure/repos/$repositoryName"
    }

    $response = ""
    while ($response -ne "yes" -and $response -ne "no") {
      Write-Host "Do you see the 'Complete Setup' link? Type 'yes' or 'no' and hit Enter:" -ForegroundColor Yellow
      $response = Read-Host
    }

    if($response -eq "yes") {
      Write-Host "Click 'Complete Setup' to finish the repository configuration" -ForegroundColor Yellow
      Write-Host "Uncheck 'Repository template' and 'Add .gitignore' so the module content is not overwritten" -ForegroundColor Yellow
      Write-Host "Elevate your permissions with JIT and then come back here to continue" -ForegroundColor Yellow

      Write-Host ""
      Write-Host "You can copy and paste the following settings..." -ForegroundColor Yellow
      Write-Host ""
      Write-Host "Classification:" -ForegroundColor Cyan
      Write-Host "Production"
      Write-Host ""
      Write-Host "Service tree:" -ForegroundColor Cyan
      Write-Host "Azure Verified Modules (AVM)"
      Write-Host ""
      Write-Host "Type of open source project:" -ForegroundColor Cyan
      Write-Host "Sample code"
      Write-Host ""
      Write-Host "License:" -ForegroundColor Cyan
      Write-Host "MIT"
      Write-Host ""
      Write-Host "Project name:" -ForegroundColor Cyan
      Write-Host "Azure Verified Module (Terraform) for '$moduleName'"
      Write-Host ""
      Write-Host "Project version:" -ForegroundColor Cyan
      Write-Host "1"
      Write-Host ""
      Write-Host "Project description:" -ForegroundColor Cyan
      Write-Host "Azure Verified Module (Terraform) for '$moduleName'. Part of AVM project - https://aka.ms/avm"
      Write-Host ""
      Write-Host "Business goals:" -ForegroundColor Cyan
      Write-Host "Create IaC module accelerating Azure deployment using Microsoft best practice."
      Write-Host ""
      Write-Host "Will this be used in a Microsoft product or service?:" -ForegroundColor Cyan
      Write-Host "Open source, can be leveraged in Microsoft services."
      Write-Host ""
    }

    if($response -eq "no") {
      Write-Host "Click the 'Compliance' tab and fill out the 3 sections." -ForegroundColor Yellow
      Write-Host "Elevate your permissions with JIT and then come back here to continue" -ForegroundColor Yellow
    }

    $response = ""
    while ($response -ne "yes") {
      Write-Host "Once the form is complete and you have elevated with JIT, type 'yes' and hit Enter to continue:" -ForegroundColor Yellow
      $response = Read-Host
    }
  }

  $creation = New-AvmRepositoryContent -AuthoringModule $authoringModule -RepositoryName $repositoryName `
    -Metadata $metadata -ModuleType $moduleType -WorkPath $tempPath -OnRepositoryCreated $portalSetup -Confirm:$false
  Write-Host ""
  Write-Host "Initialized metadata.json and published repository $moduleName" -ForegroundColor Green
}
Write-Host ""
Write-Host "Repository URL:" -ForegroundColor Cyan
Write-Host $repositoryUrl

$ownerMention = ""

if ($ownerPrimaryGitHubHandle -ne "") {
  $ownerMention = "@$ownerPrimaryGitHubHandle "
}

if (!$skipCreateAppInstallationRequest -and $PSCmdlet.ShouldProcess($repositoryName, 'Request GitHub app installation')) {
  Write-Host "Creating app installation request..." -ForegroundColor Yellow
  Install-Module powershell-yaml -Force
  $appRoot = Join-Path ($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($tempPath)) ([guid]::NewGuid().ToString('N'))
  $appPublished = $false
  try {
    $null = New-Item -ItemType Directory -Path $appRoot -Force
    $process = @{ AuthoringModule = $authoringModule; WorkingDirectory = $appRoot }
    $null = Invoke-AvmRepositoryCreationProcess @process -Tool gh -ArgumentList @(
      'repo', 'fork', '--clone', '--default-branch-only', $openSourceRepoUrl
    )
    $appRepoName = $openSourceRepoUrl.TrimEnd('/').Split('/')[-1]
    $appOrgAndRepoName = $openSourceRepoUrl.TrimEnd('/').Split('/')[-2..-1] -join '/'
    $process.WorkingDirectory = Join-Path $appRoot $appRepoName
    $null = Invoke-AvmRepositoryCreationProcess @process -Tool gh -ArgumentList @('repo', 'set-default', $appOrgAndRepoName)
    $null = Invoke-AvmRepositoryCreationProcess @process -Tool git -ArgumentList @('fetch', 'upstream')
    $null = Invoke-AvmRepositoryCreationProcess @process -Tool git -ArgumentList @('reset', '--hard', 'upstream/main')
    $null = Invoke-AvmRepositoryCreationProcess @process -Tool git -ArgumentList @('checkout', '-b', "chore/app-install-avm/$moduleName")

    foreach ($yamlFilePath in $yamlFilePaths) {
      $filePath = [System.IO.Path]::GetFullPath((Join-Path $process.WorkingDirectory $yamlFilePath))
      $relativePath = [System.IO.Path]::GetRelativePath($process.WorkingDirectory, $filePath)
      if ($relativePath -eq '..' -or $relativePath.StartsWith("..$([System.IO.Path]::DirectorySeparatorChar)") -or
          [System.IO.Path]::IsPathRooted($relativePath)) {
        throw [System.ArgumentException]::new("App configuration must remain inside its staging checkout: $yamlFilePath")
      }
      if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new("YAML file not found: $yamlFilePath")
      }
      $yamlData = Get-Content -LiteralPath $filePath -Raw | ConvertFrom-Yaml
      $yamlData.repositories = @(@($yamlData.repositories) + $repositoryName | Sort-Object)
      $yamlData | ConvertTo-Yaml -Options WithIndentedSequences | Set-Content -LiteralPath $filePath -Force
      $null = Invoke-AvmRepositoryCreationProcess @process -Tool git -ArgumentList @('add', '--', $relativePath)
    }
    $null = Invoke-AvmRepositoryCreationProcess @process -Tool git -ArgumentList @('commit', '-m', "chore: add $moduleName metadata")
    $null = Invoke-AvmRepositoryCreationProcess @process -Tool git -ArgumentList @('push', '--set-upstream', 'origin', "chore/app-install-avm/$moduleName")
    $prUrl = (Invoke-AvmRepositoryCreationProcess @process -Tool gh -ArgumentList @(
      'pr', 'create', '--title', "chore: app install avm $moduleName",
      '--body', "This PR requests an app install for the $moduleName module."
    )).StdOut.Trim()
    $appPublished = $true
    Write-Host "Created app installation request PR: $prUrl" -ForegroundColor Cyan
  }
  catch {
    throw [System.InvalidOperationException]::new(
      "App installation request failed for $repositoryUrl. Inspect '$appRoot' before retrying. $($_.Exception.Message)",
      $_.Exception
    )
  }
  finally {
    if ($appPublished) {
      Remove-Item -LiteralPath $appRoot -Force -Recurse
    }
  }
}

$completionMessage = @"
$($ownerMention)The module repository has now been created. You can find it at $repositoryUrl.

The final step of repository configuration is still in progress, but you will be able to start developing your code immediately.

Once the app installation request is approved, your repo will be configured with an environment called ``test``.
Monitor the issue above for updates on the app installation request.
This provides secrets for the test workflows and grants access to an Azure subscription and allows you to run your tests.
If you do not see this environment in your repository after 48 hours, please let us know.

Thanks!
"@

Write-Host ""
Write-Host $completionMessage -ForegroundColor Green
