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

    [switch] $SkipModuleConfig,

    [switch] $GenerateInPlace,

    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'

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

function Write-Utf8Lf {
    param (
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Content
    )

    $normalized = $Content.ReplaceLineEndings("`n")
    [IO.File]::WriteAllText($Path, $normalized, [Text.UTF8Encoding]::new($false))
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

function ConvertTo-ScribanLiteral {
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Content
    )

    $openToken = "__SCRIBAN_OPEN_$([Guid]::NewGuid().ToString('N'))__"
    $closeToken = "__SCRIBAN_CLOSE_$([Guid]::NewGuid().ToString('N'))__"
    return $Content.Replace('{{', $openToken).Replace('}}', $closeToken).Replace($openToken, "{{ '{{' }}").Replace($closeToken, "{{ '}}' }}")
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

    foreach ($entry in $sections.GetEnumerator()) {
        Write-Utf8Lf `
            -Path (Join-Path $fragmentRoot $entry.Key) `
            -Content (ConvertTo-ScribanLiteral ($entry.Value ?? ''))
    }
    Write-Utf8Lf `
        -Path (Join-Path $fragmentRoot 'full-readme.md') `
        -Content (ConvertTo-ScribanLiteral $expected)

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
    $moduleConfigPath = Join-Path $moduleRoot 'bicepconfig.json'
    $createdModuleConfig = -not $SkipModuleConfig -and -not (Test-Path $moduleConfigPath)
    $modelIndexExitCode = $null
    if ($createdModuleConfig) {
        Write-Utf8Lf -Path $moduleConfigPath -Content @'
{
  "experimentalFeaturesEnabled": {
    "docsGeneration": true
  }
}
'@
    }

    try {
        $commandArguments = @(
            'docs'
            ($GenerateInPlace ? 'generate' : 'output')
            $mainPath
            '--template-file'
            $TemplatePath
            '--template-root'
            $moduleRoot
            '--set'
            "primaryResourceType=$primaryResourceType"
            '--set'
            "moduleSymbolName=$moduleSymbolName"
            '--set'
            "moduleReference=$($modulePath.Replace('\', '/'))"
            '--set'
            "typelessOutputs=$typelessOutputs"
            '--set'
            "hasCrossReferences=$(($null -ne $sections['cross-referenced-modules.md']).ToString().ToLowerInvariant())"
            '--set'
            "hasNotes=$(($null -ne $sections['notes.md']).ToString().ToLowerInvariant())"
        )
        if ($GenerateInPlace) {
            $commandArguments += @('--output-file', 'README.md')
        }

        & $BicepPath @commandArguments `
            1> ($GenerateInPlace ? $stdoutPath : $actualPath) `
            2> $stderrPath
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            & $BicepPath docs output $mainPath `
                --template-file $ModelIndexTemplatePath `
                1> $modelIndexPath `
                2> $modelIndexStderrPath
            $modelIndexExitCode = $LASTEXITCODE
        }
    } finally {
        if ($createdModuleConfig) {
            Remove-Item -LiteralPath $moduleConfigPath -Force
        }
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

if ($PassThru) {
    $results
} else {
    $results | Format-Table -AutoSize
    if ($results.ReadmeMatches -contains $false) {
        exit 1
    }
}
