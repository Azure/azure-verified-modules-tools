function Invoke-AvmBicepDocs {
    <#
    .SYNOPSIS
        Generate README documentation for a Bicep module by walking its
        compiled ARM JSON.

    .DESCRIPTION
        Engine implementation called by Invoke-AvmDocs when the module
        context is Ecosystem='bicep'. The engine:

          1. Resolves the module's template file (defaults to 'main.bicep'
             next to README.md).
          2. Compiles it to ARM JSON via Convert-AvmBicepToArm (which
             shells out to 'bicep build --stdout').
          3. Renders the Resource Types section via
             Format-AvmBicepResourceTypesSection and injects it into
             README.md via Merge-AvmReadmeSection.
          4. Renders the Parameters section (category-grouped summary
             tables) via Format-AvmBicepParametersSection and injects
             it into README.md via Merge-AvmReadmeSection.
          5. Renders the Outputs section via Format-AvmBicepOutputsSection
             and injects it into README.md via Merge-AvmReadmeSection.

        This is the first slice of the ARM-JSON walker that replaces the
        legacy Set-ModuleReadMe.ps1 from Azure/bicep-registry-modules.
        Sections rendered today: Resource Types, Parameters (summary
        tables only — the per-parameter '### Parameter:' detail blocks
        and UDT recursion are reserved for a follow-on slice), and
        Outputs. Usage Examples, Cross-references, Navigation, and Data
        Collection sections are reserved for follow-on slices.

        If README.md does not exist, a minimal skeleton ('# <module>') is
        created before the Outputs section is injected.

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='bicep'.

    .PARAMETER AllowPathFallback
        Pass through to Resolve-AvmTool when locating the bicep binary.

    .PARAMETER TemplateFile
        Template path (relative to module root) to compile. Defaults to
        'main.bicep'.

    .PARAMETER OutputFile
        README path (relative to module root) to inject into. Defaults
        to 'README.md'.

    .OUTPUTS
        pscustomobject with Engine, Tool, ToolPath, ToolSource, Status,
        FilesProcessed, Changed.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Noun mirrors the avm CLI verb (avm docs).')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Context,

        [switch] $AllowPathFallback,

        [string] $TemplateFile = 'main.bicep',

        [string] $OutputFile = 'README.md'
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Context.Ecosystem -ne 'bicep') {
        throw [System.ArgumentException]::new(
            "Invoke-AvmBicepDocs requires a bicep context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $templatePath = Join-Path $Context.Root $TemplateFile
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        throw [AvmConfigurationException]::new(
            ("Bicep template not found: [{0}]. Pass -TemplateFile to point at a different .bicep entry point." -f $templatePath))
    }

    $compiled = Convert-AvmBicepToArm -BicepFilePath $templatePath -AllowPathFallback:$AllowPathFallback

    $resourceTypesBody = Format-AvmBicepResourceTypesSection -Arm $compiled.Arm
    $parametersBody = Format-AvmBicepParametersSection -Arm $compiled.Arm
    $outputsBody = Format-AvmBicepOutputsSection -Arm $compiled.Arm

    $readmePath = Join-Path $Context.Root $OutputFile
    $beforeHash = if (Test-Path -LiteralPath $readmePath) {
        (Get-FileHash -LiteralPath $readmePath -Algorithm SHA256).Hash
    }
    else {
        ''
    }

    if (Test-Path -LiteralPath $readmePath) {
        $existing = @(Get-Content -LiteralPath $readmePath -Encoding utf8)
    }
    else {
        $moduleName = Split-Path -Path $Context.Root -Leaf
        $existing = @("# $moduleName", '')
    }

    $merged = Merge-AvmReadmeSection -Content $existing -Heading '## Resource Types' -NewBody $resourceTypesBody
    $merged = Merge-AvmReadmeSection -Content $merged -Heading '## Parameters' -NewBody $parametersBody
    $merged = Merge-AvmReadmeSection -Content $merged -Heading '## Outputs' -NewBody $outputsBody

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $payload = ($merged -join "`n").TrimEnd("`n") + "`n"
    [System.IO.File]::WriteAllText($readmePath, $payload, $utf8NoBom)

    $afterHash = (Get-FileHash -LiteralPath $readmePath -Algorithm SHA256).Hash
    $changed = if ($beforeHash -ne $afterHash) { , $OutputFile } else { @() }

    return [pscustomobject][ordered]@{
        Engine         = 'bicep'
        Tool           = ('{0}/{1}' -f $compiled.ToolName, $compiled.ToolVersion)
        ToolPath       = $compiled.ToolPath
        ToolSource     = $compiled.ToolSource
        Status         = 'pass'
        FilesProcessed = 1
        Changed        = $changed
    }
}
