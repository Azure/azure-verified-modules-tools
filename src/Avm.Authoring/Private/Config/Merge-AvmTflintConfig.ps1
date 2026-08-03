function Test-AvmHclTrivia {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text
    )

    $withoutComments = $Text
    $withoutComments = [regex]::Replace($withoutComments, '(?m)(?:#|//)[^\r\n]*(?:\r?\n|$)', '')
    $withoutComments = [regex]::Replace($withoutComments, '(?s)/\*.*?\*/', '')
    return [string]::IsNullOrWhiteSpace($withoutComments)
}

function Get-AvmTflintOverrideBlock {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $text = [System.IO.File]::ReadAllText($Path)
    $pattern = '(?ms)^[ \t]*(?<type>[A-Za-z_][A-Za-z0-9_-]*)[ \t]+"(?<label>(?:\\.|[^"])*)"[ \t]*\{(?<body>[^{}]*)\}'
    $matches = [regex]::Matches($text, $pattern)
    $blocks = New-Object System.Collections.Generic.List[object]
    $cursor = 0

    foreach ($match in $matches) {
        if (-not (Test-AvmHclTrivia -Text $text.Substring($cursor, $match.Index - $cursor))) {
            throw [AvmConfigurationException]::new(
                "TFLint override '$Path' contains unsupported HCL before block '$($match.Groups['type'].Value)'.")
        }

        $body = $match.Groups['body'].Value
        $attributes = New-Object System.Collections.Generic.List[object]
        $attributePattern = '(?m)^[ \t]*(?<name>[A-Za-z_][A-Za-z0-9_-]*)[ \t]*=[ \t]*(?<value>[^\r\n]+?)[ \t]*(?:\r?$)'
        $attributeMatches = [regex]::Matches($body, $attributePattern)
        $bodyCursor = 0
        foreach ($attributeMatch in $attributeMatches) {
            if (-not (Test-AvmHclTrivia -Text $body.Substring($bodyCursor, $attributeMatch.Index - $bodyCursor))) {
                throw [AvmConfigurationException]::new(
                    "TFLint override '$Path' contains unsupported nested HCL in block '$($match.Groups['type'].Value) ""$($match.Groups['label'].Value)""'.")
            }
            $attributes.Add([pscustomobject]@{
                    Name  = $attributeMatch.Groups['name'].Value
                    Value = $attributeMatch.Groups['value'].Value.Trim()
                })
            $bodyCursor = $attributeMatch.Index + $attributeMatch.Length
        }
        if (-not (Test-AvmHclTrivia -Text $body.Substring($bodyCursor))) {
            throw [AvmConfigurationException]::new(
                "TFLint override '$Path' contains unsupported nested HCL in block '$($match.Groups['type'].Value) ""$($match.Groups['label'].Value)""'.")
        }

        $blocks.Add([pscustomobject]@{
                Type       = $match.Groups['type'].Value
                Label      = $match.Groups['label'].Value
                Attributes = $attributes.ToArray()
                Text       = $match.Value.Trim()
            })
        $cursor = $match.Index + $match.Length
    }

    if ($blocks.Count -eq 0 -or -not (Test-AvmHclTrivia -Text $text.Substring($cursor))) {
        throw [AvmConfigurationException]::new(
            "TFLint override '$Path' contains unsupported HCL; expected labelled blocks with direct attributes.")
    }

    return $blocks.ToArray()
}

function Merge-AvmTflintConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $BasePath,

        [Parameter(Mandatory)]
        [string] $OverridePath,

        [Parameter(Mandatory)]
        [string] $DestinationPath
    )

    $merged = [System.IO.File]::ReadAllText($BasePath)
    foreach ($overrideBlock in (Get-AvmTflintOverrideBlock -Path $OverridePath)) {
        $typePattern = [regex]::Escape($overrideBlock.Type)
        $labelPattern = [regex]::Escape($overrideBlock.Label)
        $blockPattern = "(?ms)^[ \t]*$typePattern[ \t]+`"$labelPattern`"[ \t]*\{(?<body>[^{}]*)\}"
        $baseMatches = [regex]::Matches($merged, $blockPattern)

        if ($baseMatches.Count -eq 0) {
            $merged = $merged.TrimEnd() + "`n`n" + $overrideBlock.Text + "`n"
            continue
        }

        $baseMatch = $baseMatches[$baseMatches.Count - 1]
        $body = $baseMatch.Groups['body'].Value
        foreach ($attribute in $overrideBlock.Attributes) {
            $attributePattern = '(?m)^(?<indent>[ \t]*)' + [regex]::Escape($attribute.Name) + '[ \t]*=[^\r\n]*(?:\r?$)'
            $attributeMatches = [regex]::Matches($body, $attributePattern)
            $replacement = if ($attributeMatches.Count -gt 0) {
                $indent = $attributeMatches[$attributeMatches.Count - 1].Groups['indent'].Value
                "$indent$($attribute.Name) = $($attribute.Value)"
            }
            else {
                "  $($attribute.Name) = $($attribute.Value)"
            }

            if ($attributeMatches.Count -gt 0) {
                $attributeMatch = $attributeMatches[$attributeMatches.Count - 1]
                $body = $body.Remove($attributeMatch.Index, $attributeMatch.Length).Insert($attributeMatch.Index, $replacement)
            }
            else {
                $body = $body.TrimEnd() + "`n$replacement`n"
            }
        }

        $replacementBlock = $baseMatch.Value.Substring(0, $baseMatch.Groups['body'].Index - $baseMatch.Index) +
            $body + '}'
        $merged = $merged.Remove($baseMatch.Index, $baseMatch.Length).Insert($baseMatch.Index, $replacementBlock)
    }

    [System.IO.File]::WriteAllText(
        $DestinationPath,
        ($merged -replace "`r`n", "`n"),
        [System.Text.UTF8Encoding]::new($false))
}

function New-AvmTflintConfigSet {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [string] $BaseConfigDir
    )

    $names = @('avm.tflint.hcl', 'avm.tflint_example.hcl', 'avm.tflint_module.hcl')
    $overrides = @{}
    foreach ($name in $names) {
        $overrideName = $name -replace '\.hcl$', '.override.hcl'
        $overridePath = Join-Path $Root $overrideName
        if (Test-Path -LiteralPath $overridePath -PathType Leaf) {
            $overrides[$name] = $overridePath
        }
    }

    if ($overrides.Count -eq 0) {
        return [pscustomobject]@{
            ConfigDir = $BaseConfigDir
            StageDir  = $null
        }
    }

    $stageRoot = Join-Path (Get-AvmFolder -Kind Cache) 'tflint-config-stage'
    if (-not (Test-Path -LiteralPath $stageRoot)) {
        New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
    }
    $stageDir = Join-Path $stageRoot ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

    try {
        foreach ($name in $names) {
            $basePath = Join-Path $BaseConfigDir $name
            $destinationPath = Join-Path $stageDir $name
            if ($overrides.ContainsKey($name)) {
                Merge-AvmTflintConfig `
                    -BasePath $basePath `
                    -OverridePath $overrides[$name] `
                    -DestinationPath $destinationPath
            }
            else {
                Copy-Item -LiteralPath $basePath -Destination $destinationPath
            }
        }

        return [pscustomobject]@{
            ConfigDir = $stageDir
            StageDir  = $stageDir
        }
    }
    catch {
        Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}
