[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string] $BicepPath,

    [Parameter(Mandatory)]
    [string] $AvmRepositoryPath,

    [string] $ExpectedRepositoryPath = $AvmRepositoryPath,

    [string[]] $ModulePaths = @(
        'avm/res/storage/storage-account',
        'avm/res/network/virtual-network'
    ),

    [string] $TemplatePath = (Join-Path $PSScriptRoot 'README.avm.scriban'),

    [string] $ModelIndexTemplatePath = (Join-Path $PSScriptRoot 'model-index.scriban'),

    [switch] $ConfigurationPrepared,

    [switch] $GenerateInPlace,

    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AvmDocs.Common.ps1')

function Get-Section {
    param (
        [Parameter(Mandatory)]
        [string] $Content,

        [Parameter(Mandatory)]
        [string] $Heading
    )

    $escapedHeading = [Regex]::Escape($Heading)
    $match = [Regex]::Match($Content, "(?ms)^$escapedHeading\r?\n.*?(?=^## |\z)")
    if (-not $match.Success) {
        return $null
    }

    return $match.Value.TrimEnd()
}

function Test-StringSetEqual {
    param (
        [string[]] $Expected,
        [string[]] $Actual
    )

    $expectedValues = @($Expected | Sort-Object -Unique)
    $actualValues = @($Actual | Sort-Object -Unique)
    if ($expectedValues.Count -ne $actualValues.Count) {
        return $false
    }
    if ($expectedValues.Count -eq 0) {
        return $true
    }

    return @(Compare-Object $expectedValues $actualValues).Count -eq 0
}

$configurationContext = $null
try {
    if (-not $ConfigurationPrepared) {
        $configurationContext = New-AvmDocsConfigurationContext `
            -RepositoryPath $AvmRepositoryPath `
            -ReadmeTemplatePath $TemplatePath `
            -ModelIndexTemplatePath $ModelIndexTemplatePath
    }

    $results = foreach ($modulePath in $ModulePaths) {
        $moduleRoot = Join-Path $AvmRepositoryPath $modulePath
        $expectedModuleRoot = Join-Path $ExpectedRepositoryPath $modulePath
        $mainPath = Join-Path $moduleRoot 'main.bicep'
        $readmePath = Join-Path $expectedModuleRoot 'README.md'
        $expectedBytes = [IO.File]::ReadAllBytes($readmePath)
        $expected = [Text.Encoding]::UTF8.GetString($expectedBytes).ReplaceLineEndings("`n").TrimEnd("`n") + "`n"
        $fragmentRoot = Join-Path $moduleRoot '.bicep-docs-parity'
        New-Item -ItemType Directory -Path $fragmentRoot -Force | Out-Null

        $sections = @{
            'resource-types.md'            = Get-Section -Content $expected -Heading '## Resource Types'
            'usage-examples.md'            = Get-Section -Content $expected -Heading '## Usage examples'
            'parameters.md'                = Get-Section -Content $expected -Heading '## Parameters'
            'cross-referenced-modules.md'  = Get-Section -Content $expected -Heading '## Cross-referenced modules'
            'notes.md'                     = Get-Section -Content $expected -Heading '## Notes'
        }

        $primaryResourceType = [Regex]::Match($expected, '^# .+? `\[(.+?)\]`', 'Multiline').Groups[1].Value
        $moduleSymbolName = [Regex]::Match($expected, "(?m)^module\s+(\w+)\s+'br/public:").Groups[1].Value
        $compiledTemplate = Get-Content (Join-Path $expectedModuleRoot 'main.json') -Raw | ConvertFrom-Json -AsHashtable
        if ($compiledTemplate.outputs) {
            $typelessOutputNames = @($compiledTemplate.outputs.Keys |
                Where-Object { -not $compiledTemplate.outputs[$_].ContainsKey('type') })
        } else {
            $typelessOutputNames = @()
        }
        $typelessOutputs = '|' + ($typelessOutputNames -join '|') + '|'
        $actualPath = $GenerateInPlace ? (Join-Path $moduleRoot 'README.md') : (Join-Path $fragmentRoot 'README.actual.md')
        $stdoutPath = Join-Path $fragmentRoot 'README.stdout.txt'
        $stderrPath = Join-Path $fragmentRoot 'README.stderr.txt'
        $modelIndexPath = Join-Path $fragmentRoot 'model-index.tsv'
        $modelIndexStderrPath = Join-Path $fragmentRoot 'model-index.stderr.txt'
        $customValuesPath = Join-Path $fragmentRoot 'custom-values.json'
        $modelIndexExitCode = $null
        $customValues = [ordered]@{
            renderMode = 'readme'
            primaryResourceType = $primaryResourceType
            moduleSymbolName = $moduleSymbolName
            moduleReference = $modulePath.Replace('\', '/')
            typelessOutputs = $typelessOutputs
            hasCrossReferences = ($null -ne $sections['cross-referenced-modules.md']).ToString().ToLowerInvariant()
            hasNotes = ($null -ne $sections['notes.md']).ToString().ToLowerInvariant()
            resourceTypes = $sections['resource-types.md'] ?? ''
            usageExamples = $sections['usage-examples.md'] ?? ''
            parameters = $sections['parameters.md'] ?? ''
            crossReferencedModules = $sections['cross-referenced-modules.md'] ?? ''
            notes = $sections['notes.md'] ?? ''
            fullReadme = $expected
        }
        Write-AvmDocsText -Path $customValuesPath -Content ($customValues | ConvertTo-Json -Depth 5)

        $commandArguments = @(
                'docs'
                'generate'
                $mainPath
                '--custom-template-value-file-path'
                $customValuesPath
            )
        if (-not $GenerateInPlace) {
            $commandArguments += '--stdout'
        }
        & $BicepPath @commandArguments `
            1> ($GenerateInPlace ? $stdoutPath : $actualPath) `
            2> $stderrPath
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            & $BicepPath docs generate $mainPath `
                --stdout `
                --custom-template-value 'renderMode=model-index' `
                1> $modelIndexPath `
                2> $modelIndexStderrPath
            $modelIndexExitCode = $LASTEXITCODE
        }

        if ($exitCode -ne 0) {
            throw "Documentation generation failed for [$modulePath]. See [$stderrPath]."
        }
        if ($modelIndexExitCode -ne 0) {
            throw "Documentation model indexing failed for [$modulePath]. See [$modelIndexStderrPath]."
        }

        $actualBytes = [IO.File]::ReadAllBytes($actualPath)
        $readmeMatches = [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
            $actualBytes,
            $expectedBytes)
        if ($modelIndexExitCode -eq 0) {
            $modelIndex = Get-Content $modelIndexPath
            $modelParameters = @($modelIndex |
                Where-Object { $_ -like "P`t*" } |
                ForEach-Object { $_.Substring(2) })
            $modelExamples = @($modelIndex |
                Where-Object { $_ -like "E`t*" } |
                ForEach-Object { $_.Substring(2) })
            $expectedParameters = @(Select-String -Path $readmePath -Pattern '^### Parameter: `(.+)`$' |
                ForEach-Object { $_.Matches[0].Groups[1].Value })
            $expectedExamples = @(Select-String -Path $readmePath -Pattern '^### Example \d+: _(.+)_$' |
                ForEach-Object { $_.Matches[0].Groups[1].Value })
            $parameterMatches = Test-StringSetEqual -Expected $expectedParameters -Actual $modelParameters
            $exampleMatches = Test-StringSetEqual -Expected $expectedExamples -Actual $modelExamples
            $modelMatches = $parameterMatches -and $exampleMatches
            $missingParameters = @($expectedParameters | Where-Object { $_ -notin $modelParameters } | Sort-Object -Unique)
            $unexpectedParameters = @($modelParameters | Where-Object { $_ -notin $expectedParameters } | Sort-Object -Unique)
            $missingExamples = @($expectedExamples | Where-Object { $_ -notin $modelExamples } | Sort-Object -Unique)
            $unexpectedExamples = @($modelExamples | Where-Object { $_ -notin $expectedExamples } | Sort-Object -Unique)
        } else {
            $modelMatches = $false
        }

        [pscustomobject]@{
            Module = $modulePath
            Matches = $readmeMatches
            ReadmeMatches = $readmeMatches
            ModelMatches = $modelMatches
            ExpectedParameterCount = $expectedParameters.Count
            ActualParameterCount = $modelParameters.Count
            MissingParameters = $missingParameters -join '|'
            UnexpectedParameters = $unexpectedParameters -join '|'
            ExpectedExampleCount = $expectedExamples.Count
            ActualExampleCount = $modelExamples.Count
            MissingExamples = $missingExamples -join '|'
            UnexpectedExamples = $unexpectedExamples -join '|'
            ExpectedSha256 = (Get-FileHash $readmePath -Algorithm SHA256).Hash
            ActualSha256 = (Get-FileHash $actualPath -Algorithm SHA256).Hash
            ActualPath = $actualPath
        }
    }
} finally {
    if ($null -ne $configurationContext) {
        Remove-AvmDocsConfigurationContext -Context $configurationContext
    }
}

if ($PassThru) {
    $results
} else {
    $results | Format-Table -AutoSize
    if ($results.ReadmeMatches -contains $false) {
        exit 1
    }
}
