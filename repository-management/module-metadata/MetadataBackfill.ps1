function Assert-AvmMetadataBackfillCapability {
    [CmdletBinding()]
    param()

    $commands = [ordered]@{
        'Get-AvmModuleMetadata' = @('LegacyRecord', 'Override', 'OwnerGitHubHandle', 'ChildModule', 'SkipModuleVersionCheck')
        'Initialize-AvmModuleMetadata' = @('InputObject', 'ChildModule', 'UpdateSource', 'WhatIf', 'SkipModuleVersionCheck')
        'Test-AvmModuleMetadata'       = @('ChildModule', 'CheckSource', 'SkipModuleVersionCheck')
    }
    foreach ($name in $commands.Keys) {
        $command = Get-Command -Name $name -Module Avm.Authoring -ErrorAction SilentlyContinue
        if (-not $command -or @($commands[$name] | Where-Object { -not $command.Parameters.ContainsKey($_) }).Count -gt 0) {
            throw [System.InvalidOperationException]::new("Metadata backfill requires a published Avm.Authoring release containing $name and the shared metadata API. Publish/install that release before enabling backfill; this adapter never downloads module code or schemas.")
        }
    }
}

function Get-AvmMetadataBackfillPlan {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][ValidateSet('bicep', 'terraform')][string] $Ecosystem,
        [object[]] $LegacyRecord = @(),
        [switch] $UpdateSource
    )

    $modules = @(Get-AvmMetadataBackfillModule -Root $Root -Ecosystem $Ecosystem -Repository $Repository)
    $plans = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($module in $modules) {
        $parameters = @{
            Ecosystem = $Ecosystem
            ModuleType = $module.ModuleType
            ChildModule = $null -ne $module.ParentPath
            SkipModuleVersionCheck = $true
        }
        try {
            $rows = @(Get-AvmMetadataBackfillLegacyRecord -Record $LegacyRecord -Module $module -Repository $Repository -Ecosystem $Ecosystem)
            $values = @{}
            if ($Ecosystem -eq 'terraform' -and
                @($rows | Where-Object { $_['ModuleDescription'] -or $_['Description'] }).Count -eq 0) {
                $description = Get-AvmMetadataBackfillDescription -Root $Root -ModulePath $module.Path
                if ($description) { $values.moduleDescription = $description }
            }
            $metadata = Get-AvmModuleMetadata @parameters -Path $module.FullPath -ModuleId $module.ModuleId `
                -LegacyRecord $rows -Override $values
            if ($metadata.Status -ne 'pass') {
                throw [System.ArgumentException]::new(($metadata.Issues.Message -join ' '))
            }
            $fileExists = Test-Path -LiteralPath (Join-Path $module.FullPath 'metadata.json') -PathType Leaf
            $plan = Initialize-AvmModuleMetadata @parameters -Path $module.FullPath `
                -InputObject $metadata.Metadata -UpdateSource:($UpdateSource -and -not $fileExists) -WhatIf
            $plans.Add([pscustomobject]@{
                    Path = $module.Path
                    FullPath = $module.FullPath
                    Parameters = $parameters
                    Metadata = $metadata.Metadata
                    UpdateSource = $UpdateSource -and -not $fileExists
                    PlannedFiles = $plan.PlannedFiles
                })
        }
        catch {
            $errors.Add("$($module.Path): $($_.Exception.Message)")
        }
    }
    if ($errors.Count -gt 0) {
        throw [System.ArgumentException]::new("Metadata could not be created from the available information. No files were written.`n$($errors -join "`n")")
    }
    return $plans.ToArray()
}

function Read-AvmMetadataBackfillJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    $document = $null
    try {
        $json = [System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes($Path))
        $document = [System.Text.Json.JsonDocument]::Parse($json)
        if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
            throw [System.ArgumentException]::new("Expected a JSON object in '$Path'.")
        }
        $pending = [System.Collections.Generic.Stack[System.Text.Json.JsonElement]]::new()
        $pending.Push($document.RootElement)
        while ($pending.Count -gt 0) {
            $element = $pending.Pop()
            if ($element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
                $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($property in $element.EnumerateObject()) {
                    if (-not $names.Add($property.Name)) {
                        throw [System.ArgumentException]::new("Duplicate JSON property '$($property.Name)' in '$Path'.")
                    }
                    $pending.Push($property.Value)
                }
            }
            elseif ($element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
                foreach ($item in $element.EnumerateArray()) {
                    $pending.Push($item)
                }
            }
        }
        return ConvertFrom-Json -InputObject $json -AsHashtable -Depth 64
    }
    catch [System.Text.Json.JsonException] {
        throw [System.ArgumentException]::new("Expected strict JSON in '$Path': $($_.Exception.Message)", $_.Exception)
    }
    finally {
        if ($null -ne $document) {
            $document.Dispose()
        }
    }
}

function Assert-AvmMetadataBackfillShape {
    param(
        [Parameter(Mandatory)][object] $Value,
        [Parameter(Mandatory)][string[]] $Required,
        [string[]] $Optional = @(),
        [Parameter(Mandatory)][string] $Label
    )

    if ($Value -isnot [System.Collections.IDictionary]) {
        throw [System.ArgumentException]::new("$Label must be an object.")
    }
    foreach ($key in $Required) {
        if (@($Value.Keys) -cnotcontains $key) {
            throw [System.ArgumentException]::new("$Label requires '$key'.")
        }
    }
    foreach ($key in $Value.Keys) {
        if (($Required + $Optional) -cnotcontains $key) {
            throw [System.ArgumentException]::new("$Label contains unsupported property '$key'.")
        }
    }
    if ($Value.Contains('schemaVersion') -and
        (($Value.schemaVersion -isnot [int] -and $Value.schemaVersion -isnot [long]) -or $Value.schemaVersion -ne 1)) {
        throw [System.ArgumentException]::new("$Label schemaVersion must be the integer 1.")
    }
}

function Resolve-AvmMetadataBackfillRoot {
    param([Parameter(Mandatory)][string] $Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or $item.PSProvider.Name -ne 'FileSystem') {
        throw [System.ArgumentException]::new('RepositoryRoot must be an existing filesystem directory.')
    }
    $ancestor = $item
    while ($null -ne $ancestor) {
        if ($ancestor.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw [System.ArgumentException]::new("Reparse points are not supported in the checkout path: $($ancestor.FullName)")
        }
        $ancestor = $ancestor.Parent
    }
    return $item.FullName
}

function Resolve-AvmMetadataBackfillPath {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $RelativePath,
        [switch] $AllowMissingLeaf
    )

    if ($RelativePath -ceq '.') {
        return $Root
    }
    if ([System.IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '[\\:\x00-\x1f]' -or
        $RelativePath.StartsWith('/', [System.StringComparison]::Ordinal)) {
        throw [System.ArgumentException]::new("Unsafe relative path '$RelativePath'; use checkout-relative forward-slash paths.")
    }
    $segments = $RelativePath.Split('/')
    $current = $Root
    for ($index = 0; $index -lt $segments.Count; $index++) {
        $segment = $segments[$index]
        if ($segment -notmatch '^[A-Za-z0-9_.-]+$' -or $segment -in @('.', '..') -or $segment.EndsWith('.')) {
            throw [System.ArgumentException]::new("Unsafe path segment in '$RelativePath'.")
        }
        $items = @(Get-ChildItem -LiteralPath $current -Force | Where-Object { $_.Name -ieq $segment })
        if ($items.Count -eq 0 -and $AllowMissingLeaf -and $index -eq $segments.Count - 1) {
            return Join-Path -Path $current -ChildPath $segment
        }
        if ($items.Count -ne 1 -or $items[0].Name -cne $segment) {
            throw [System.ArgumentException]::new("Path '$RelativePath' is missing, ambiguous, or has incorrect casing.")
        }
        if ($items[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw [System.ArgumentException]::new("Reparse path '$RelativePath' is not allowed.")
        }
        if ($index -lt $segments.Count - 1 -and -not $items[0].PSIsContainer) {
            throw [System.ArgumentException]::new("Path '$RelativePath' traverses a file.")
        }
        $current = $items[0].FullName
    }
    return $current
}

function Get-AvmMetadataBackfillModule {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][ValidateSet('bicep', 'terraform')][string] $Ecosystem,
        [Parameter(Mandatory)][string] $Repository
    )

    if ($Repository -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$') {
        throw [System.ArgumentException]::new('Repository must be an explicit owner/repository identity, not a URL.')
    }
    $rootPath = Resolve-AvmMetadataBackfillRoot -Path $Root
    $modules = [System.Collections.Generic.List[object]]::new()
    $excluded = @('examples', 'tests', 'test', 'build', 'out', 'dist', 'node_modules')
    $kinds = @{ res = 'resource'; ptn = 'pattern'; utl = 'utility' }
    if ($Ecosystem -eq 'terraform') {
        if ($Repository -cnotmatch '/terraform-[a-z0-9]+-(?<id>avm-(?<kind>res|ptn|utl)-[a-z0-9-]+)$') {
            throw [System.ArgumentException]::new('Terraform Repository must identify an avm-res-, avm-ptn-, or avm-utl- repository.')
        }
        $moduleId = $Matches.id
        $moduleType = $kinds[$Matches.kind]
        $paths = [System.Collections.Generic.List[string]]::new()
        $paths.Add('.')
        $childrenPath = Join-Path -Path $rootPath -ChildPath 'modules'
        if (Test-Path -LiteralPath $childrenPath) {
            $childrenPath = Resolve-AvmMetadataBackfillPath -Root $rootPath -RelativePath 'modules'
            if (-not (Test-Path -LiteralPath $childrenPath -PathType Container)) {
                throw [System.ArgumentException]::new('Terraform modules must be a directory.')
            }
            foreach ($child in Get-ChildItem -LiteralPath $childrenPath -Directory -Force | Sort-Object -Property Name -CaseSensitive) {
                if ($child.Name.StartsWith('.') -or $child.Name -in $excluded) {
                    continue
                }
                $paths.Add("modules/$($child.Name)")
            }
        }
        foreach ($relative in $paths) {
            $directory = Resolve-AvmMetadataBackfillPath -Root $rootPath -RelativePath $relative
            $sources = @(Get-ChildItem -LiteralPath $directory -File | Where-Object { $_.Name -clike '*.tf' -and $_.Name -cne 'main.metadata.tf' })
            if ($sources.Count -eq 0) {
                if ($relative -ceq '.') {
                    throw [System.ArgumentException]::new('Terraform checkout has no root .tf source.')
                }
                continue
            }
            $modules.Add([pscustomobject]@{
                    Path       = $relative
                    FullPath   = $directory
                    ModuleId   = $moduleId
                    ModuleType = $moduleType
                    ParentPath = if ($relative -ceq '.') { $null } else { '.' }
                })
        }
    }
    else {
        foreach ($kind in @('res', 'ptn', 'utl')) {
            $relative = "avm/$kind"
            if (-not (Test-Path -LiteralPath (Join-Path -Path $rootPath -ChildPath 'avm' -AdditionalChildPath $kind))) {
                continue
            }
            $null = Resolve-AvmMetadataBackfillPath -Root $rootPath -RelativePath $relative
            $pending = [System.Collections.Generic.Queue[string]]::new()
            $pending.Enqueue($relative)
            while ($pending.Count -gt 0) {
                $relative = $pending.Dequeue()
                $directory = Resolve-AvmMetadataBackfillPath -Root $rootPath -RelativePath $relative
                $items = @(Get-ChildItem -LiteralPath $directory -Force)
                if (@($items | Where-Object { $_.Name -ieq 'main.bicep' }).Count -gt 0) {
                    $null = Resolve-AvmMetadataBackfillPath -Root $rootPath -RelativePath "$relative/main.bicep"
                    $segments = $relative.Split('/')
                    if ($segments.Count -lt 4) {
                        throw [System.ArgumentException]::new("Unsupported Bicep module path '$relative'; expected avm/kind/group/name.")
                    }
                    $modules.Add([pscustomobject]@{
                            Path       = $relative
                            FullPath   = $directory
                            ModuleId   = $relative
                            ModuleType = $kinds[$kind]
                            ParentPath = if ($segments.Count -eq 4) { $null } else { $segments[0..3] -join '/' }
                        })
                }
                foreach ($child in $items | Where-Object { $_.PSIsContainer } | Sort-Object -Property Name -CaseSensitive) {
                    if (-not $child.Name.StartsWith('.') -and $child.Name -notin $excluded -and $child.Name -ine 'modules') {
                        $pending.Enqueue("$relative/$($child.Name)")
                    }
                }
            }
        }
    }
    if ($modules.Count -eq 0) {
        throw [System.ArgumentException]::new('No supported source modules were discovered in this checkout.')
    }
    foreach ($module in $modules) {
        if ($null -ne $module.ParentPath -and @($modules.Path) -cnotcontains $module.ParentPath) {
            throw [System.ArgumentException]::new("Module '$($module.Path)' has no discovered family root '$($module.ParentPath)'.")
        }
        foreach ($file in Get-ChildItem -LiteralPath $module.FullPath -Force) {
            if ($file.Name -ieq 'metadata.json' -or $file.Name -ieq 'main.bicep' -or $file.Name -ilike '*.tf') {
                $fileRelative = if ($module.Path -ceq '.') { $file.Name } else { "$($module.Path)/$($file.Name)" }
                $null = Resolve-AvmMetadataBackfillPath -Root $rootPath -RelativePath $fileRelative
                if ($file.PSIsContainer) {
                    throw [System.ArgumentException]::new("Expected a source/metadata file at '$fileRelative'.")
                }
                if ($file.Name -ieq 'metadata.json' -and $file.Name -cne 'metadata.json') {
                    throw [System.ArgumentException]::new("metadata.json has incorrect casing at '$fileRelative'.")
                }
                if (($file.Name -ieq 'main.metadata.tf' -and $file.Name -cne 'main.metadata.tf') -or
                    ($file.Name -ilike '*.tf' -and $file.Name -cnotlike '*.tf')) {
                    throw [System.ArgumentException]::new("Terraform source has unsupported casing at '$fileRelative'.")
                }
            }
        }
    }
    $modules.Sort([System.Comparison[object]] {
            param($left, $right)
            [System.StringComparer]::Ordinal.Compare($left.Path, $right.Path)
        })
    return $modules.ToArray()
}





function Get-AvmMetadataBackfillDescription {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $ModulePath,
        [System.Collections.IDictionary] $Source
    )

    if ($Source) {
        Assert-AvmMetadataBackfillShape -Value $Source -Required @('path', 'paragraph') -Label 'descriptionSource'
        if ($Source.path -isnot [string] -or ($Source.paragraph -isnot [int] -and $Source.paragraph -isnot [long]) -or $Source.paragraph -lt 1) {
            throw [System.ArgumentException]::new('descriptionSource requires a checkout-relative path and a one-based integer paragraph.')
        }
        $relative = $Source.path
    }
    else {
        $relative = if ($ModulePath -ceq '.') { '_header.md' } else { "$ModulePath/_header.md" }
        $candidate = Resolve-AvmMetadataBackfillPath -Root $Root -RelativePath $relative -AllowMissingLeaf
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return
        }
    }
    $path = Resolve-AvmMetadataBackfillPath -Root $Root -RelativePath $relative
    if ([System.IO.Path]::GetExtension($path) -cnotin @('.md', '.txt')) {
        throw [System.ArgumentException]::new('Description sources must be Markdown or text files.')
    }
    $text = (Get-Content -LiteralPath $path -Raw).Replace("`r`n", "`n").Trim("`n")
    $paragraphs = @([regex]::Split($text, '\n[\t ]*\n') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($Source) {
        if ($Source.paragraph -gt $paragraphs.Count) {
            throw [System.ArgumentException]::new("Description paragraph $($Source.paragraph) is missing from '$relative'.")
        }
        $paragraph = $paragraphs[$Source.paragraph - 1]
    }
    else {
        $prose = @($paragraphs | Where-Object { $_ -notmatch '(?m)^[\t ]*(?:#|[-*+] |\d+\. |>|```|~~~)|[<>`|]|\[[^\]]*\]\(' })
        if ($prose.Count -eq 0) {
            return
        }
        $paragraph = $prose[0]
    }
    if ($paragraph -match '(?m)^[\t ]*(?:#|[-*+] |\d+\. |>|```|~~~)|[<>`|]|\[[^\]]*\]\(') {
        if ($Source) {
            throw [System.ArgumentException]::new("Selected description paragraph in '$relative' is not plain prose; supply moduleDescription explicitly.")
        }
        return
    }
    return $paragraph
}

function Get-AvmMetadataBackfillLegacyRecord {
    param(
        [object[]] $Record = @(),
        [Parameter(Mandatory)][object] $Module,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $Ecosystem
    )

    foreach ($row in $Record) {
        $matched = if ($Ecosystem -eq 'bicep') {
            $row['ModuleName'] -ceq $Module.Path -or $row['ModuleId'] -ceq $Module.Path
        }
        elseif ($Module.Path -ceq '.') {
            ([string]::IsNullOrWhiteSpace([string]$row['ModulePath']) -or $row['ModulePath'] -ceq '.') -and
            ($row['ModuleId'] -ceq $Module.ModuleId -or $row['ModuleName'] -ceq $Module.ModuleId -or
            $row['ModuleName'] -ceq ($Repository.Split('/')[1]) -or $row['RepoURL'] -ceq "https://github.com/$Repository")
        }
        else {
            $row['ModulePath'] -ceq $Module.Path -and $row['RepoURL'] -ceq "https://github.com/$Repository"
        }
        if ($matched) {
            $row
        }
    }
}
