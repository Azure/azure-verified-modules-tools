function Get-AvmBicepScaffoldPlan {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Metadata,

        [Parameter(Mandatory)]
        [ValidateSet('resource', 'pattern', 'utility')]
        [string] $ModuleType,

        [switch] $ChildModule
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $pathInfo = Get-AvmBicepScaffoldPath -Path $Path -ModuleType $ModuleType -ChildModule:$ChildModule
    $root = $pathInfo.Path
    $kind = $pathInfo.Kind
    $group = $pathInfo.Group
    $moduleName = $pathInfo.ModuleName
    $modulePathSuffix = "$group/$moduleName"
    $initials = [System.Text.StringBuilder]::new()
    foreach ($segment in ("$group/$moduleName" -split '[-/]')) {
        if ($segment.Length -gt 0) {
            $null = $initials.Append($segment[0])
        }
    }
    $serviceInitials = $initials.ToString()

    $definitions = [System.Collections.Generic.List[object]]::new()
    $sourceTemplate = if ($ChildModule) { 'child.bicep' }
    elseif ($ModuleType -eq 'utility' -and -not $Metadata.Contains('telemetryIdPrefix')) { 'utility.bicep' }
    else { 'main.bicep' }
    $definitions.Add([pscustomobject]@{ Path = Join-Path $root 'main.bicep'; Template = $sourceTemplate; TestKind = $null })
    if (-not $ChildModule) {
        $definitions.Add([pscustomobject]@{ Path = Join-Path $root 'version.json'; Template = 'version.json'; TestKind = $null })
        $definitions.Add([pscustomobject]@{ Path = Join-Path $root 'CHANGELOG.md'; Template = 'CHANGELOG.md'; TestKind = $null })
        foreach ($testKind in @('defaults', 'waf-aligned')) {
            $testPath = Join-Path -Path $root -ChildPath 'tests' -AdditionalChildPath 'e2e', $testKind, 'main.test.bicep'
            $definitions.Add([pscustomobject]@{ Path = $testPath; Template = 'main.test.bicep'; TestKind = $testKind })
        }
    }

    $plans = [System.Collections.Generic.List[object]]::new()
    foreach ($definition in $definitions) {
        $parent = Split-Path -Path $definition.Path -Parent
        $leaf = Split-Path -Path $definition.Path -Leaf
        if (Test-Path -LiteralPath $parent -PathType Container) {
            $collisions = @(Get-ChildItem -LiteralPath $parent -Force | Where-Object { $_.Name -ieq $leaf })
            if ($collisions.Count -gt 0) {
                if ($collisions.Count -ne 1 -or $collisions[0].PSIsContainer -or $collisions[0].Name -cne $leaf) {
                    throw [System.ArgumentException]::new("Scaffold file must be a file with exact casing: $($definition.Path)")
                }
                if ($definition.Template -eq $sourceTemplate) {
                    $authoredSource = [System.IO.File]::ReadAllText($definition.Path)
                    $literals = Get-AvmBicepMetadataLiteral -Source $authoredSource
                    if ($literals.description -cne $Metadata.moduleDescription) {
                        throw [System.ArgumentException]::new(
                            "Existing main.bicep metadata description does not match metadata.json: $($definition.Path)")
                    }
                }
                continue
            }
        }
        elseif (Test-Path -LiteralPath $parent -PathType Leaf) {
            throw [System.ArgumentException]::new("Scaffold parent is a file: $parent")
        }

        $content = Get-AvmBicepScaffoldTemplate -Name $definition.Template
        switch ($definition.Template) {
            { $_ -in @('main.bicep', 'child.bicep', 'utility.bicep') } {
                foreach ($placeholder in @('<Add module name>', '<Add description>')) {
                    if (($content.Split([string[]]@($placeholder), [System.StringSplitOptions]::None)).Count -ne 2) {
                        throw [System.IO.InvalidDataException]::new(
                            "Bundled Bicep template has an invalid $placeholder placeholder: $($definition.Template)")
                    }
                }
                $content = $content.Replace('<Add module name>', (ConvertTo-AvmBicepStringValue -Value $Metadata.moduleDisplayName))
                $content = $content.Replace('<Add description>', (ConvertTo-AvmBicepStringValue -Value $Metadata.moduleDescription))
                $literals = Get-AvmBicepMetadataLiteral -Source $content
                if ($literals.name -cne $Metadata.moduleDisplayName -or $literals.description -cne $Metadata.moduleDescription) {
                    throw [System.IO.InvalidDataException]::new("Bundled Bicep template did not render valid metadata literals: $($definition.Template)")
                }
            }
            'version.json' {
                $version = ConvertFrom-Json -InputObject $content -AsHashtable -ErrorAction Stop
                if ([string]::IsNullOrWhiteSpace($version['$schema']) -or [string]::IsNullOrWhiteSpace($version.version)) {
                    throw [System.IO.InvalidDataException]::new('Bundled Bicep version.json template is invalid.')
                }
            }
            'CHANGELOG.md' {
                foreach ($placeholder in @('<moduleType>', '<modulePath>')) {
                    if (-not $content.Contains($placeholder)) {
                        throw [System.IO.InvalidDataException]::new(
                            "Bundled Bicep changelog template is missing $placeholder.")
                    }
                }
                $content = $content.Replace('<moduleType>', $kind).Replace('<modulePath>', $modulePathSuffix)
            }
            'main.test.bicep' {
                $name = if ($definition.TestKind -eq 'defaults') { 'Using only defaults' } else { 'WAF-aligned' }
                $description = if ($definition.TestKind -eq 'defaults') {
                    'This instance deploys the module with the minimum set of required parameters.'
                }
                else {
                    'This instance deploys the module in alignment with the best-practices of the Azure Well-Architected Framework.'
                }
                $replacements = [ordered]@{
                    '<TestName>'        = $name
                    '<TestDescription>' = $description
                    '<provider>'        = $group
                    '<resourceType>'    = $moduleName
                    '<serviceShort>'    = $serviceInitials + $(if ($definition.TestKind -eq 'defaults') { 'min' } else { 'waf' })
                }
                foreach ($placeholder in $replacements.Keys) {
                    if (-not $content.Contains($placeholder)) {
                        throw [System.IO.InvalidDataException]::new(
                            "Bundled Bicep test template is missing $placeholder.")
                    }
                    $content = $content.Replace($placeholder, $replacements[$placeholder])
                }
                $literals = Get-AvmBicepMetadataLiteral -Source $content
                if ($literals.name -cne $name -or $literals.description -cne $description) {
                    throw [System.IO.InvalidDataException]::new('Bundled Bicep test template did not render valid metadata literals.')
                }
            }
        }
        $plans.Add([pscustomobject]@{ Path = $definition.Path; Content = $content; Original = $null })
    }
    return $plans.ToArray()
}
