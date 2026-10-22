#Requires -Version 7.4

[CmdletBinding()]
param(
  [array]$repoFilter = @(),
  [array]$validProviders = @("azure", "azurerm", "azapi"),
  [string]$outputDirectory = "."
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$syncRoot = Join-Path $PSScriptRoot '..' '..' '..'
$manifest = Join-Path $syncRoot '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
$null = Import-Module -Name $manifest -Scope Local -Force -ErrorAction Stop
. (Join-Path $syncRoot 'scripts' 'lib' 'RetryHelpers.ps1')
. (Join-Path $syncRoot 'scripts' 'lib' 'RepoTree.ps1')
. (Join-Path $syncRoot 'scripts' 'lib' 'RepositoryDiscovery.ps1')
. (Join-Path $syncRoot 'scripts' 'lib' 'RepositoryMetadata.ps1')

Write-Host "Generating matrix for AVM repositories"

$repos = [System.Collections.Generic.List[object]]::new()

Write-Host "Getting repositories from app installation"

$installedRepositories = @(Get-RepositoryInstalledRepositories)

$issues = [System.Collections.Generic.List[object]]::new()

foreach ($installedRepository in $installedRepositories | Sort-Object -Property name)
{
  $identity = Get-RepositoryTerraformModuleIdentity -Name $installedRepository.name -ValidProviders $validProviders
  if ($null -eq $identity)
  {
    Write-Host "Skipping $($installedRepository.name) as it does not match the Terraform AVM module naming convention..."
    continue
  }

  if ($installedRepository.archived)
  {
    Write-Host "Skipping $($installedRepository.name) as it is archived in GitHub..."
    continue
  }

  $moduleName = $identity.ModuleName
  if ($repoFilter.Count -gt 0 -and $repoFilter -notcontains $moduleName)
  {
    continue
  }
  $moduleType = $identity.ModuleType
  try
  {
    $metadata = Get-RepositoryModuleMetadata -Repository $installedRepository.full_name `
      -DefaultBranch $installedRepository.default_branch -ModuleType $moduleType
  }
  catch
  {
    $issue = @{
      repoId = $installedRepository.name
      message = "Skipping $($installedRepository.name): $($_.Exception.Message)"
      severity = "error"
    }
    Write-Warning $issue.message
    $issues.Add($issue)
    continue
  }
  if ($metadata.Status -eq 'missing')
  {
    $issue = @{
      repoId   = $installedRepository.name
      message  = "$($installedRepository.name) has no root metadata.json on its default branch. Initialize metadata.json; direct collaborator cleanup will be skipped until ownership is available."
      severity = "warning"
    }
    Write-Warning $issue.message
    $issues.Add($issue)
  }

  $repos.Add(@{
    repoId              = $moduleName
    repoName            = $installedRepository.name
    repoFullName        = $installedRepository.full_name
    repoUrl             = $installedRepository.html_url
    repoType            = "avm"
    repoSubType         = $moduleType
    repoMetaData        = $metadata.Metadata
  })
}

if ($issues.Count -gt 0)
{
  $issuesJson = ConvertTo-Json -InputObject $issues.ToArray() -Depth 100
  $issuesJson | Set-Content -LiteralPath (Join-Path $outputDirectory 'issues.log.json') -Encoding utf8NoBOM
}

Write-Host "Found $($repos.Count) repositories"

return $repos | Sort-Object -Property repoId
