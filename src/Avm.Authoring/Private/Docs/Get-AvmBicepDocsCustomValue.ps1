function Get-AvmBicepDocsCustomValue {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $ModulePath,

        [Parameter(Mandatory)]
        [string] $ToolPath,

        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [System.Collections.Generic.Dictionary[string, object]] $CompiledTemplateCache
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $items = @(Get-ChildItem -LiteralPath $ModulePath -Force)
    $readmes = @($items | Where-Object { $_.Name -ieq 'README.md' })
    $sidecars = @($items | Where-Object { $_.Name -ieq 'README.notes.md' })
    foreach ($file in @($readmes + $sidecars)) {
        if ($file.PSIsContainer -or ($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or
            ($file.Name -cne 'README.md' -and $file.Name -cne 'README.notes.md')) {
            throw [AvmConfigurationException]::new(
                "Bicep documentation needs exactly cased, regular README files in '$ModulePath'.")
        }
    }
    if ($readmes.Count -gt 1 -or $sidecars.Count -gt 1) {
        throw [AvmConfigurationException]::new(
            "Bicep documentation found ambiguous README files in '$ModulePath'.")
    }

    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    $notes = ''
    if ($sidecars.Count -eq 1) {
        $bytes = [System.IO.File]::ReadAllBytes($sidecars[0].FullName)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and
            $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) {
            throw [AvmConfigurationException]::new(
                "Bicep Notes sidecar must be UTF-8 without BOM: $($sidecars[0].FullName)")
        }
        try {
            $notes = $utf8.GetString($bytes)
        }
        catch [System.Text.DecoderFallbackException] {
            throw [AvmConfigurationException]::new(
                "Bicep Notes sidecar must contain valid UTF-8: $($sidecars[0].FullName)")
        }
        if ($notes.Contains("`r")) {
            throw [AvmConfigurationException]::new(
                "Bicep Notes sidecar must use LF line endings: $($sidecars[0].FullName)")
        }
    }
    elseif ($readmes.Count -eq 1) {
        $bytes = [System.IO.File]::ReadAllBytes($readmes[0].FullName)
        try {
            $existing = $utf8.GetString($bytes)
        }
        catch [System.Text.DecoderFallbackException] {
            throw [AvmConfigurationException]::new(
                "Bicep README must contain valid UTF-8: $($readmes[0].FullName)")
        }
        if ($null -ne (Get-AvmLegacyReadmeNote -Content $existing)) {
            throw [AvmConfigurationException]::new(
                "The README in '$ModulePath' has authored Notes but no README.notes.md. Run 'avm docs export-notes -Path `"$ModulePath`"' first; documentation generation never copies Notes from an existing README.")
        }
    }
    $banners = @{}
    foreach ($name in @('DEPRECATED.md', 'MOVED-TO-AVM.md')) {
        $bannerMatches = @($items | Where-Object { $_.Name -ieq $name })
        if ($bannerMatches.Count -gt 1) {
            throw [AvmConfigurationException]::new(
                "Bicep documentation found ambiguous '$name' files in '$ModulePath'.")
        }
        $lines = @()
        if ($bannerMatches.Count -eq 1) {
            $file = $bannerMatches[0]
            if ($file.PSIsContainer -or $file.Name -cne $name -or
                ($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                throw [AvmConfigurationException]::new(
                    "Bicep documentation needs a regular, exactly cased '$name' in '$ModulePath'.")
            }
            try {
                $lines = [System.IO.File]::ReadAllLines($file.FullName, $utf8)
            }
            catch [System.Text.DecoderFallbackException] {
                throw [AvmConfigurationException]::new(
                    "Bicep documentation banner must contain valid UTF-8: $($file.FullName)")
            }
        }
        $banners[$name] = ConvertTo-Json -InputObject $lines -Compress
    }

    $normalized = [System.IO.Path]::GetFullPath($ModulePath).Replace('\', '/')
    $reference = [regex]::Match($normalized, '(?:^|/)(avm/(?:res|ptn|utl)/.+)$')
    $moduleReference = if ($reference.Success) { $reference.Groups[1].Value } else { '' }
    $segments = $moduleReference.Split('/')
    $moduleName = if ($segments.Count -ge 4) { $segments[3] } else {
        [System.IO.Path]::GetFileName([System.IO.Path]::GetFullPath($ModulePath))
    }
    $specialNames = @{
        'public-ip-addresses' = 'publicIPAddresses'
        'public-ip-prefixes'  = 'publicIPPrefixes'
    }
    if ($specialNames.ContainsKey($moduleName)) {
        $symbol = $specialNames[$moduleName]
    }
    else {
        $nameParts = $moduleName.Split('-', [System.StringSplitOptions]::RemoveEmptyEntries)
        $symbol = $nameParts[0].ToLowerInvariant()
        for ($index = 1; $index -lt $nameParts.Length; $index++) {
            $symbol += [cultureinfo]::GetCultureInfo('en-US').TextInfo.ToTitleCase($nameParts[$index])
        }
    }

    $headerType = ''
    if ($segments.Count -ge 4 -and $segments[1] -in @('ptn', 'utl')) {
        $textInfo = [cultureinfo]::GetCultureInfo('en-US').TextInfo
        $parent = $textInfo.ToTitleCase(($segments[2] -replace '[^0-9A-Z]', ' ')) -replace ' '
        $childName = $segments[3..($segments.Count - 1)] -join ' '
        $child = $textInfo.ToTitleCase(($childName -replace '[^0-9A-Z]', ' ')) -replace ' '
        $headerType = "$parent/$child"
    }
    $metadataPath = Join-Path $ModulePath 'metadata.json'
    if ([System.IO.File]::Exists($metadataPath)) {
        try {
            $metadata = $utf8.GetString([System.IO.File]::ReadAllBytes($metadataPath)) |
                ConvertFrom-Json -AsHashtable -ErrorAction Stop
        }
        catch {
            throw [AvmConfigurationException]::new(
                "Cannot read Bicep module metadata '$metadataPath': $($_.Exception.Message)")
        }
        if ($metadata -isnot [System.Collections.IDictionary]) {
            throw [AvmConfigurationException]::new(
                "Bicep module metadata must contain a JSON object: $metadataPath")
        }
        if ($metadata['canonicalType'] -is [string] -and
            -not [string]::IsNullOrWhiteSpace($metadata['canonicalType']) -and
            $segments.Count -ge 4 -and $segments[1] -eq 'res' -and
            $metadata['canonicalType'] -cne 'helper') {
            $headerType = $metadata['canonicalType']
        }
    }

    $typelessOutputs = @()
    $compiledPath = Join-Path $ModulePath 'main.json'
    $sourcePath = [System.IO.Path]::GetFullPath((Join-Path $ModulePath 'main.bicep'))
    $cached = if ($null -ne $CompiledTemplateCache -and
        $CompiledTemplateCache.ContainsKey($sourcePath)) {
        $CompiledTemplateCache[$sourcePath]
    }
    else { $null }
    if ($null -ne $cached) {
        $compiled = $cached.Template
    }
    else {
        $compiledJson = if ([System.IO.File]::Exists($compiledPath)) {
            $utf8.GetString([System.IO.File]::ReadAllBytes($compiledPath))
        }
        else {
            Get-AvmBicepCompiledJson -SourcePath $sourcePath -ToolPath $ToolPath
        }
        try {
            $compiled = $compiledJson | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        }
        catch {
            throw [AvmConfigurationException]::new(
                "Cannot read compiled Bicep module '$compiledPath': $($_.Exception.Message)")
        }
    }
    if ($compiled -isnot [System.Collections.IDictionary]) {
        throw [AvmConfigurationException]::new(
            "Compiled Bicep module must be a JSON object: $compiledPath")
    }
    $descriptionSuffix = ''
    if ($compiled['metadata'] -is [System.Collections.IDictionary] -and
        $compiled['metadata'].Contains('description')) {
        if ($compiled['metadata']['description'] -isnot [string]) {
            throw [AvmConfigurationException]::new(
                "Compiled Bicep description must be a string in '$compiledPath'.")
        }
        $descriptionSuffix = [regex]::Match(
            $compiled['metadata']['description'], '\n+$').Value
    }
    if ($compiled['outputs'] -is [System.Collections.IDictionary]) {
        $typelessOutputs = @($compiled['outputs'].psbase.Keys | Where-Object {
                -not $compiled['outputs'][$_].ContainsKey('type')
            })
    }
    $resourceTypes = @(Get-AvmBicepDocsResourceType -Template $compiled)
    if ($segments.Count -ge 4 -and $segments[1] -eq 'res') {
        $slug = $segments[-1].Replace('-', '').Replace('_', '').ToLowerInvariant()
        $names = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        $null = $names.Add($slug)
        $null = $names.Add($slug + 's')
        if ($slug.EndsWith('y', [System.StringComparison]::Ordinal)) {
            $null = $names.Add($slug.Substring(0, $slug.Length - 1) + 'ies')
        }
        $matchingTypes = @($resourceTypes | Where-Object {
                $lastSegment = ($_.Type -split '/')[-1].Replace('-', '').Replace('_', '')
                $names.Contains($lastSegment)
            } | Select-Object -ExpandProperty Type -Unique)
        if ($matchingTypes.Count -eq 1) {
            $headerType = $matchingTypes[0]
        }
    }
    $roleNames = Get-AvmBicepDocsRoleName -Template $compiled -SourcePath $compiledPath
    $compiledDetails = Get-AvmBicepDocsCompiledParameter `
        -Template $compiled -SourcePath $compiledPath
    $references = @(Get-AvmBicepDocsReference -ModulePath $ModulePath -RepositoryRoot $RepositoryRoot)
    $compiledParameters = if ($compiled['parameters'] -is [System.Collections.IDictionary]) {
        $compiled['parameters']
    }
    else { @{} }
    $compiledOutputs = if ($compiled['outputs'] -is [System.Collections.IDictionary]) {
        $compiled['outputs']
    }
    else { @{} }
    $requiredParameters = @(
        if ($null -ne $cached) {
            $cached.Required
        }
        else {
            Get-AvmBicepDocsRequiredParameter -Template $compiled -SourcePath $compiledPath
        }
    )
    if ($null -ne $CompiledTemplateCache -and $null -eq $cached) {
        $CompiledTemplateCache[$sourcePath] = [pscustomobject]@{
            Template = $compiled
            Required = [string[]]$requiredParameters
        }
    }
    $examples = Get-AvmBicepDocsExample -ModulePath $ModulePath `
        -RepositoryRoot $RepositoryRoot -ToolPath $ToolPath `
        -CompiledTemplate $compiled -RequiredParameters $requiredParameters `
        -CompiledTemplateCache $CompiledTemplateCache
    $scopeChildren = @($items | Where-Object {
            $_.PSIsContainer -and $_.Name -clike '*-scope'
        } | Sort-Object -Culture 'en-US' -Property Name | ForEach-Object {
            if ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                throw [AvmConfigurationException]::new(
                    "Bicep documentation does not follow linked scope directories: $($_.FullName)")
            }
            $_.Name
        })

    return @{
        moduleReference    = $moduleReference
        moduleSymbol       = $symbol
        headerType         = $headerType
        descriptionSuffix  = $descriptionSuffix
        isVersioned        = if ([System.IO.File]::Exists((Join-Path $ModulePath 'version.json'))) {
            'true'
        }
        else { 'false' }
        typelessOutputs    = '|' + ($typelessOutputs -join '|') + '|'
        resourceTypes      = ConvertTo-Json -InputObject $resourceTypes -Compress -Depth 5
        roleNames          = ConvertTo-Json -InputObject $roleNames -Compress -Depth 5
        references         = ConvertTo-Json -InputObject $references -Compress -Depth 5
        compiledParameters = ConvertTo-Json -InputObject $compiledParameters -Compress -Depth 99
        compiledOutputs    = ConvertTo-Json -InputObject $compiledOutputs -Compress -Depth 99
        compiledDetails    = ConvertTo-Json -InputObject $compiledDetails -Compress -Depth 50
        examples           = ConvertTo-Json -InputObject $examples -Compress -Depth 99
        scopeChildren      = ConvertTo-Json -InputObject $scopeChildren -Compress
        deprecatedLines    = $banners['DEPRECATED.md']
        movedLines         = $banners['MOVED-TO-AVM.md']
        hasNotes           = if ($sidecars.Count -gt 0) { 'true' } else { 'false' }
        notes              = $notes
    }
}
