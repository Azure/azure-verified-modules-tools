[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string] $BicepPath,

    [Parameter(Mandatory)]
    [string] $SourceRepositoryPath,

    [Parameter(Mandatory)]
    [string] $WorkingRepositoryPath,

    [Parameter(Mandatory)]
    [string] $OutputPath,

    [int] $ThrottleLimit = 8,

    [string] $VerifierPath = (Join-Path $PSScriptRoot 'Test-AvmDocsParity.ps1')
)

$ErrorActionPreference = 'Stop'
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$templatePath = Join-Path $PSScriptRoot 'README.byte-parity.scriban'
$modelIndexTemplatePath = Join-Path $PSScriptRoot 'model-index.scriban'
$rootConfigPath = Join-Path $WorkingRepositoryPath 'bicepconfig.json'
$originalRootConfig = [IO.File]::ReadAllText($rootConfigPath)
$modulePaths = @(Get-ChildItem (Join-Path $SourceRepositoryPath 'avm') -Recurse -Filter main.bicep -File |
    Where-Object {
        (Test-Path (Join-Path $_.DirectoryName 'README.md')) -and
        (Test-Path (Join-Path $_.DirectoryName 'main.json'))
    } |
    ForEach-Object { [IO.Path]::GetRelativePath($SourceRepositoryPath, $_.DirectoryName).Replace('\', '/') } |
    Sort-Object)

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

try {
    if ($originalRootConfig -notmatch '"docsGeneration"\s*:\s*true') {
        $objectStart = $originalRootConfig.IndexOf('{')
        $featureConfig = @'

  "experimentalFeaturesEnabled": {
    "docsGeneration": true
  },
'@
        $enabledConfig = $originalRootConfig.Insert($objectStart + 1, $featureConfig)
        [IO.File]::WriteAllText(
            $rootConfigPath,
            $enabledConfig,
            [Text.UTF8Encoding]::new($false))
    }

    $results = @($modulePaths | ForEach-Object -Parallel {
        $modulePath = $_
        $moduleRoot = Join-Path $using:WorkingRepositoryPath $modulePath
        $moduleOutputPath = Join-Path $using:OutputPath $modulePath
        New-Item -ItemType Directory -Path $moduleOutputPath -Force | Out-Null

        try {
            $result = & $using:VerifierPath `
                -BicepPath $using:BicepPath `
                -AvmRepositoryPath $using:WorkingRepositoryPath `
                -ExpectedRepositoryPath $using:SourceRepositoryPath `
                -ModulePaths @($modulePath) `
                -TemplatePath $using:templatePath `
                -ModelIndexTemplatePath $using:modelIndexTemplatePath `
                -SkipModuleConfig `
                -GenerateInPlace `
                -PassThru

            $fragmentRoot = Join-Path $moduleRoot '.bicep-docs-parity'
            $generatedPath = Join-Path $moduleRoot 'README.md'
            Copy-Item (Join-Path $fragmentRoot 'README.stderr.txt') (Join-Path $moduleOutputPath 'README.stderr.txt') -Force
            if (Test-Path (Join-Path $fragmentRoot 'model-index.tsv')) {
                Copy-Item (Join-Path $fragmentRoot 'model-index.tsv') (Join-Path $moduleOutputPath 'model-index.tsv') -Force
            }
            if (Test-Path (Join-Path $fragmentRoot 'model-index.stderr.txt')) {
                Copy-Item (Join-Path $fragmentRoot 'model-index.stderr.txt') (Join-Path $moduleOutputPath 'model-index.stderr.txt') -Force
            }

            if (-not $result.ReadmeMatches) {
                $diffPath = Join-Path $moduleOutputPath 'README.diff.txt'
                git --no-pager diff --no-index -- (Join-Path $using:SourceRepositoryPath "$modulePath/README.md") $generatedPath 2>&1 |
                    Set-Content $diffPath
            }

            [pscustomobject]@{
                Module = $modulePath
                Matches = $result.Matches
                ReadmeMatches = $result.ReadmeMatches
                ModelMatches = $result.ModelMatches
                ExpectedParameterCount = $result.ExpectedParameterCount
                ActualParameterCount = $result.ActualParameterCount
                MissingParameters = $result.MissingParameters
                UnexpectedParameters = $result.UnexpectedParameters
                ExpectedExampleCount = $result.ExpectedExampleCount
                ActualExampleCount = $result.ActualExampleCount
                MissingExamples = $result.MissingExamples
                UnexpectedExamples = $result.UnexpectedExamples
                ExpectedSha256 = $result.ExpectedSha256
                ActualSha256 = $result.ActualSha256
                GeneratedReadme = $generatedPath
                Error = $null
            }
        } catch {
            $fragmentRoot = Join-Path $moduleRoot '.bicep-docs-parity'
            foreach ($logName in @('README.stderr.txt', 'model-index.stderr.txt')) {
                $logPath = Join-Path $fragmentRoot $logName
                if (Test-Path $logPath) {
                    Copy-Item $logPath (Join-Path $moduleOutputPath $logName) -Force
                }
            }

            [pscustomobject]@{
                Module = $modulePath
                Matches = $false
                ReadmeMatches = $false
                ModelMatches = $false
                ExpectedParameterCount = $null
                ActualParameterCount = $null
                MissingParameters = $null
                UnexpectedParameters = $null
                ExpectedExampleCount = $null
                ActualExampleCount = $null
                MissingExamples = $null
                UnexpectedExamples = $null
                ExpectedSha256 = $null
                ActualSha256 = $null
                GeneratedReadme = $null
                Error = $_.Exception.Message
            }
        }
    } -ThrottleLimit $ThrottleLimit)
} finally {
    [IO.File]::WriteAllText(
        $rootConfigPath,
        $originalRootConfig,
        [Text.UTF8Encoding]::new($false))
}

$results = @($results | Sort-Object Module)
$results | Export-Csv (Join-Path $OutputPath 'comparison.csv') -NoTypeInformation
$results | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutputPath 'comparison.json')
$semanticMismatches = @($results | Where-Object { -not $_.Error -and -not $_.ModelMatches })
$semanticMismatches | Export-Csv (Join-Path $OutputPath 'model-mismatches.csv') -NoTypeInformation

$stopwatch.Stop()
$summary = [pscustomobject]@{
    RepositoryCommit = (git -C $SourceRepositoryPath rev-parse HEAD)
    TotalModules = $results.Count
    GeneratedReadmes = @($results | Where-Object GeneratedReadme).Count
    Matches = @($results | Where-Object Matches).Count
    ReadmeMismatches = @($results | Where-Object { -not $_.ReadmeMatches }).Count
    ModelMismatches = @($results | Where-Object { -not $_.ModelMatches }).Count
    SemanticModelMismatches = $semanticMismatches.Count
    ParameterModelMismatches = @($semanticMismatches | Where-Object { $_.MissingParameters -or $_.UnexpectedParameters }).Count
    ExampleModelMismatches = @($semanticMismatches | Where-Object { $_.MissingExamples -or $_.UnexpectedExamples }).Count
    Errors = @($results | Where-Object { $_.Error }).Count
    DurationSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
    Duration = $stopwatch.Elapsed.ToString()
}
$summary | ConvertTo-Json | Set-Content (Join-Path $OutputPath 'summary.json')
$errorDetails = @($results | Where-Object Error | ForEach-Object {
    $module = $_.Module
    $stderrPath = Join-Path $OutputPath "$module/README.stderr.txt"
    $diagnostics = if (Test-Path $stderrPath) {
        @(Get-Content $stderrPath | Where-Object { $_ -match ' : Error ' })
    } else {
        @()
    }

    if ($diagnostics.Count -gt 0) {
        @("$module`:") + @($diagnostics | ForEach-Object { "  $_" })
    } else {
        "$module`: $($_.Error)"
    }
})
@(
    "Repository commit: $($summary.RepositoryCommit)"
    "Total modules compared: $($summary.TotalModules)"
    "Generated READMEs: $($summary.GeneratedReadmes)"
    "Byte-for-byte matches: $($summary.Matches)"
    "Generation errors: $($summary.Errors)"
    "Semantic model mismatches: $($summary.SemanticModelMismatches)"
    "Parameter model mismatches: $($summary.ParameterModelMismatches)"
    "Example model mismatches: $($summary.ExampleModelMismatches)"
    "Duration: $($summary.Duration)"
    ""
    "Generation errors:"
    $errorDetails
) | Set-Content (Join-Path $OutputPath 'validation.txt')
$summary | Format-List

if ($results.ReadmeMatches -contains $false) {
    exit 1
}
