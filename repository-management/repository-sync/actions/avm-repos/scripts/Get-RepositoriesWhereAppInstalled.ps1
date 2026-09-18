#Requires -Version 7.4

[CmdletBinding()]
param(
  [array]$repoFilter = @(),
  [array]$validProviders = @("azure", "azurerm", "azapi"),
  [array]$reposToSkip = @(
    "terraform-azurerm-avm-template",
    "avm-terraform-governance",
    "bicep-registry-modules",
    "terraform-azure-modules",
    "ALZ-PowerShell-Module",
    "Azure-Verified-Modules",
    "Azure-Verified-Modules-Grept",
    "avmtester",
    "tflint-ruleset-avm",
    "policy-library-avm",
    "mapotf",
    "azure-verified-modules-tools",
    "avm-gh-app",
    "avm-container-images-cicd-agents-and-runners",
    "Azure-Verified-Modules-Workflows"
  ),
  [array]$additionalReposToSkip = @(),
  [string]$outputDirectory = "."
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$syncRoot = Join-Path $PSScriptRoot '..' '..' '..'
$manifest = Join-Path $syncRoot '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
$null = Import-Module -Name $manifest -Scope Local -Force -ErrorAction Stop
. (Join-Path $syncRoot 'scripts' 'lib' 'RetryHelpers.ps1')
. (Join-Path $syncRoot 'scripts' 'lib' 'RepoTree.ps1')
. (Join-Path $syncRoot 'scripts' 'lib' 'RepositoryMetadata.ps1')

Write-Host "Generating matrix for AVM repositories"

$repos = [System.Collections.Generic.List[object]]::new()

Write-Host "Getting repositories from app installation"

$itemsPerPage = 100
$page = 1
$incompleteResults = $true

$installedRepositories = @()

while ($incompleteResults)
{
  $result = Invoke-RepositorySyncProcess -Command gh -Arguments @(
    'api', '--hostname', 'github.com', '--method', 'GET',
    "/installation/repositories?per_page=$itemsPerPage&page=$page"
  )
  if ($result.ExitCode -ne 0) {
    throw [System.InvalidOperationException]::new("Cannot list the app's repositories: $($result.StdErr)")
  }
  $response = $result.StdOut | ConvertFrom-Json
  $installedRepositories += $response.repositories
  $incompleteResults = $page * $itemsPerPage -lt $response.total_count
  $page++
}

$issues = [System.Collections.Generic.List[object]]::new()

$moduleTypes = @{
  "res"      = "resource"
  "ptn"      = "pattern"
  "utl"      = "utility"
}

$finalReposToSkip = $reposToSkip + $additionalReposToSkip
$providerPattern = ($validProviders | ForEach-Object { [regex]::Escape($_) }) -join '|'
$repositoryPattern = "^terraform-($providerPattern)-(?<module>avm-(?<kind>res|ptn|utl)-[a-z0-9-]+)$"

Write-Host "Skipping repositories: $(ConvertTo-Json $finalReposToSkip)"

foreach ($installedRepository in $installedRepositories | Sort-Object -Property name)
{
  if ($finalReposToSkip -contains $installedRepository.name)
  {
    Write-Host "Skipping $($installedRepository.name) as it is in the skip list..."
    continue
  }

  if ($installedRepository.archived)
  {
    Write-Host "Skipping $($installedRepository.name) as it is archived in GitHub..."
    continue
  }

  $nameMatch = [regex]::Match($installedRepository.name, $repositoryPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if (!$nameMatch.Success)
  {
    $issue = @{
      repoId   = $installedRepository.name
      message  = "Skipping $($installedRepository.name) as it does not match the required naming convention: terraform-($providerPattern)-avm-(res|ptn|utl)-..."
      severity = "error"
    }
    Write-Warning $issue.message
    $issues.Add($issue)
    continue
  }

  $moduleName = $nameMatch.Groups['module'].Value
  if ($repoFilter.Count -gt 0 -and $repoFilter -notcontains $moduleName)
  {
    continue
  }
  $moduleType = $moduleTypes[$nameMatch.Groups['kind'].Value]
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
