#Requires -Version 7.4

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ModuleCatalog.Configuration.ps1')

function ConvertTo-AvmCatalogJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][object] $Value)

    return (ConvertTo-Json -InputObject $Value -Depth 100).Replace("`r`n", "`n") + "`n"
}

function Read-AvmCatalogJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    $text = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false, $true))
    $document = [System.Text.Json.JsonDocument]::Parse($text)
    $document.Dispose()
    return ConvertFrom-Json -InputObject $text -AsHashtable -NoEnumerate -Depth 100
}

function Get-AvmCatalogKey {
    [CmdletBinding()]
    param([string] $Ecosystem, [string] $Repository, [string] $ModulePath)

    return '{0}:{1}:{2}' -f $Ecosystem, $Repository.ToLowerInvariant(), $ModulePath
}

function Get-AvmCatalogOrdinal {
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]] $Values)

    $sorted = [string[]]@($Values)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    return ,$sorted
}

function New-AvmCatalogIdentity {
    [CmdletBinding()]
    param(
        [ValidateSet('bicep', 'terraform')][string] $Ecosystem,
        [string] $Repository,
        [string] $ModulePath,
        [System.Collections.IDictionary] $Configuration = (Read-AvmCatalogConfiguration)
    )

    $kinds = @{ res = 'resource'; ptn = 'pattern'; utl = 'utility' }
    $provider = $null
    if ($Ecosystem -eq 'bicep') {
        $match = [regex]::Match($ModulePath, '^avm/(?<kind>res|ptn|utl)/[a-z0-9-]+/[a-z0-9-]+(/[a-z0-9-]+)*$')
        if (-not $match.Success -or $Repository -cne $Configuration.repositories.bicep) {
            throw [System.ArgumentException]::new("Unsupported Bicep identity: $Repository, $ModulePath")
        }
        $name = $ModulePath
        $repositoryId = $Repository.Split('/')[1]
        $repoUrl = "https://github.com/$Repository/tree/main/$ModulePath"
        $reference = "br/public:${ModulePath}:X.Y.Z"
    }
    else {
        $match = [regex]::Match($Repository, '^Azure/terraform-(?<provider>azurerm|azapi|azure)-(?<id>avm-(?<kind>res|ptn|utl)-[a-z0-9-]+)$')
        if (-not $match.Success -or $ModulePath -cnotmatch '^(\.|modules/[a-z0-9_-]+)$') {
            throw [System.ArgumentException]::new("Unsupported Terraform identity: $Repository, $ModulePath")
        }
        $provider = $match.Groups['provider'].Value
        $repositoryId = $match.Groups['id'].Value
        $name = $repositoryId
        $repoUrl = "https://github.com/$Repository"
        $reference = "https://registry.terraform.io/modules/Azure/$repositoryId/$provider/latest"
        if ($ModulePath -ne '.') {
            $name += "//$ModulePath"
            $repoUrl += "/tree/HEAD/$ModulePath"
            $reference += '/submodules/' + $ModulePath.Substring('modules/'.Length)
        }
    }

    return [pscustomobject]@{
        Key          = Get-AvmCatalogKey -Ecosystem $Ecosystem -Repository $Repository -ModulePath $ModulePath
        Ecosystem    = $Ecosystem
        Repository   = $Repository
        RepositoryId = $repositoryId
        ModulePath   = $ModulePath
        ModuleName   = $name
        ModuleType   = $kinds[$match.Groups['kind'].Value]
        Provider     = $provider
        RepoURL      = $repoUrl
        Reference    = $reference
        ParentModule = $null
        FamilyModule = $ModulePath
        Directory    = $null
        Metadata     = $null
    }
}

function Get-AvmCatalogSources {
    [CmdletBinding()]
    param(
        [string] $BicepRoot,
        [string] $TerraformRoot,
        [System.Collections.IDictionary] $Configuration = (Read-AvmCatalogConfiguration)
    )

    $sources = [System.Collections.Generic.List[object]]::new()
    foreach ($root in @($BicepRoot, $TerraformRoot)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            throw [System.IO.DirectoryNotFoundException]::new("Source snapshot is missing: $root")
        }
        $links = @(Get-ChildItem -LiteralPath $root -Recurse -Force |
                Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint })
        if ($links.Count -gt 0 -or ((Get-Item -LiteralPath $root).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw [System.IO.InvalidDataException]::new("Source snapshots must not contain links: $root")
        }
    }

    $bicepPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $bicepByPath = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $BicepRoot -Recurse -File -Force)) {
        $relative = [System.IO.Path]::GetRelativePath($BicepRoot, $file.FullName).Replace('\', '/')
        if ($relative -notmatch '^avm/(res|ptn|utl)/' -or
            $relative -match '(^|/)(tests|examples|modules|\.test|\.git|\.github|\.avm|\.terraform|\.vscode)(/|$)') {
            continue
        }
        if ($file.Name -ieq 'main.bicep' -or $file.Name -ieq 'metadata.json') {
            $null = $bicepPaths.Add($relative.Substring(0, $relative.LastIndexOf('/')))
        }
    }
    foreach ($modulePath in (Get-AvmCatalogOrdinal -Values @($bicepPaths))) {
        $identity = New-AvmCatalogIdentity -Ecosystem bicep -Repository $Configuration.repositories.bicep -ModulePath $modulePath -Configuration $Configuration
        $directory = Join-Path $BicepRoot $modulePath
        $mainPath = Join-Path $directory 'main.bicep'
        if (-not (Test-Path -LiteralPath $mainPath -PathType Leaf) -or (Get-Item -LiteralPath $mainPath).Name -cne 'main.bicep') {
            throw [System.IO.InvalidDataException]::new("Bicep module has no main.bicep: $modulePath")
        }
        $identity.Directory = $directory
        $ancestor = $modulePath
        while ($ancestor.Contains('/')) {
            $ancestor = $ancestor.Substring(0, $ancestor.LastIndexOf('/'))
            if ($bicepByPath.ContainsKey($ancestor)) {
                $identity.ParentModule = $ancestor
                $identity.FamilyModule = $bicepByPath[$ancestor].FamilyModule
                break
            }
        }
        $bicepByPath[$modulePath] = $identity
        $sources.Add($identity)
    }

    $terraformDirectories = @{}
    foreach ($directory in @(Get-ChildItem -LiteralPath $TerraformRoot -Directory)) {
        if ($directory.Name -cmatch '^terraform-(azurerm|azapi|azure)-avm-(res|ptn|utl)-[a-z0-9-]+$') {
            $terraformDirectories[$directory.Name] = $directory
        }
    }
    foreach ($name in (Get-AvmCatalogOrdinal -Values @($terraformDirectories.Keys))) {
        $directory = $terraformDirectories[$name]
        $scopes = [System.Collections.Generic.List[object]]::new()
        $scopes.Add(@{ Path = '.'; Directory = $directory.FullName })
        $childrenPath = Join-Path $directory.FullName 'modules'
        if (Test-Path -LiteralPath $childrenPath -PathType Container) {
            $children = @{}
            foreach ($child in @(Get-ChildItem -LiteralPath $childrenPath -Directory)) {
                $children[$child.Name] = $child
            }
            foreach ($childName in (Get-AvmCatalogOrdinal -Values @($children.Keys))) {
                $child = $children[$childName]
                $scopes.Add(@{ Path = "modules/$($child.Name)"; Directory = $child.FullName })
            }
        }
        $hasRoot = $false
        foreach ($scope in $scopes) {
            $files = @(Get-ChildItem -LiteralPath $scope.Directory -File -Force)
            $hasSource = @($files | Where-Object { $_.Name -cmatch '\.tf(\.json)?$' }).Count -gt 0
            $hasMetadata = @($files | Where-Object { $_.Name -ieq 'metadata.json' }).Count -gt 0
            if (-not $hasSource) {
                if ($hasMetadata) {
                    throw [System.IO.InvalidDataException]::new("Metadata has no Terraform source: $name/$($scope.Path)")
                }
                continue
            }
            if ($scope.Path -eq '.') {
                $hasRoot = $true
            }
            elseif (-not $hasRoot) {
                throw [System.IO.InvalidDataException]::new("Terraform child has no source-bearing family root: $name/$($scope.Path)")
            }
            $identity = New-AvmCatalogIdentity -Ecosystem terraform -Repository "Azure/$name" -ModulePath $scope.Path -Configuration $Configuration
            $identity.Directory = $scope.Directory
            if ($scope.Path -ne '.') {
                $identity.ParentModule = '.'
                $identity.FamilyModule = '.'
            }
            $sources.Add($identity)
        }
    }

    $byKey = @{}
    foreach ($source in $sources) {
        if ($byKey.ContainsKey($source.Key)) {
            throw [System.IO.InvalidDataException]::new("Duplicate module identity: $($source.Key)")
        }
        $byKey[$source.Key] = $source
        $metadataFiles = @(Get-ChildItem -LiteralPath $source.Directory -Force |
                Where-Object { $_.Name -ieq 'metadata.json' })
        if ($metadataFiles.Count -gt 0) {
            $result = Test-AvmModuleMetadata -Path $source.Directory -Ecosystem $source.Ecosystem `
                -ModuleType $source.ModuleType -ChildModule:($null -ne $source.ParentModule) `
                -CheckSource:($source.Ecosystem -eq 'bicep') -SkipModuleVersionCheck
            if ($result.Status -cne 'pass') {
                $messages = @($result.Issues | ForEach-Object { $_.Message }) -join '; '
                throw [System.IO.InvalidDataException]::new("Invalid present metadata for $($source.Key): $messages")
            }
            $source.Metadata = $result.Metadata
        }
    }
    foreach ($source in $sources) {
        if ($null -ne $source.Metadata -and $null -ne $source.ParentModule) {
            $familyKey = Get-AvmCatalogKey -Ecosystem $source.Ecosystem -Repository $source.Repository -ModulePath $source.FamilyModule
            if ($null -eq $byKey[$familyKey].Metadata) {
                throw [System.IO.InvalidDataException]::new("Cannot adopt child $($source.Key): family root metadata is missing.")
            }
        }
    }
    return ,$sources.ToArray()
}

function Read-AvmCatalogCsv {
    [CmdletBinding()]
    param([string] $Path)

    $reader = [System.IO.StringReader]::new([System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false, $true)))
    $parser = [Microsoft.VisualBasic.FileIO.TextFieldParser]::new($reader)
    try {
        $parser.SetDelimiters(',')
        $parser.HasFieldsEnclosedInQuotes = $true
        $parser.TrimWhiteSpace = $false
        $headers = $parser.ReadFields()
        if ($null -eq $headers -or $headers.Count -eq 0) {
            throw [System.IO.InvalidDataException]::new("CSV has no header: $Path")
        }
        $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($header in $headers) {
            if ([string]::IsNullOrWhiteSpace($header) -or -not $names.Add($header)) {
                throw [System.IO.InvalidDataException]::new("CSV has an empty or duplicate column: $Path")
            }
        }
        foreach ($required in @('ModuleName', 'ModuleDisplayName', 'RepoURL', 'ModuleStatus', 'Description')) {
            if (-not $names.Contains($required)) {
                throw [System.IO.InvalidDataException]::new("CSV is missing $required`: $Path")
            }
        }
        $rows = [System.Collections.Generic.List[object]]::new()
        while (-not $parser.EndOfData) {
            $fields = $parser.ReadFields()
            if ($fields.Count -ne $headers.Count) {
                throw [System.IO.InvalidDataException]::new("CSV row has $($fields.Count) fields, expected $($headers.Count): $Path")
            }
            $row = [ordered]@{}
            for ($index = 0; $index -lt $headers.Count; $index++) {
                $row[$headers[$index]] = $fields[$index]
            }
            $rows.Add($row)
        }
        return [pscustomobject]@{ Headers = $headers; Rows = $rows; OriginalRowCount = $rows.Count }
    }
    finally {
        $parser.Dispose()
        $reader.Dispose()
    }
}

function ConvertTo-AvmCatalogCsv {
    [CmdletBinding()]
    param([string[]] $Headers, [AllowEmptyCollection()][object[]] $Rows)

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($values in @(@{ Values = $Headers }) + @($Rows | ForEach-Object {
                $row = $_
                @{ Values = @($Headers | ForEach-Object { [string]$row[$_] }) }
            })) {
        $escaped = foreach ($value in $values.Values) {
            $text = ([string]$value).Replace("`r`n", "`n").Replace("`r", "`n")
            if ($text.IndexOfAny([char[]]@(',', '"', "`n")) -ge 0) {
                '"' + $text.Replace('"', '""') + '"'
            }
            else {
                $text
            }
        }
        $lines.Add($escaped -join ',')
    }
    return ($lines -join "`n") + "`n"
}

function Get-AvmCatalogLegacyIdentity {
    [CmdletBinding()]
    param(
        [System.Collections.IDictionary] $Row,
        [string] $Ecosystem,
        [System.Collections.IDictionary] $Configuration = (Read-AvmCatalogConfiguration)
    )

    if ($Ecosystem -eq 'bicep') {
        return New-AvmCatalogIdentity -Ecosystem bicep -Repository $Configuration.repositories.bicep -ModulePath $Row.ModuleName -Configuration $Configuration
    }
    $match = [regex]::Match([string]$Row.RepoURL, '^https://github\.com/(?<repository>Azure/terraform-(azurerm|azapi|azure)-avm-(res|ptn|utl)-[a-z0-9-]+)(/tree/[^/]+/(?<path>modules/[a-z0-9_-]+))?/?$')
    if (-not $match.Success) {
        throw [System.ArgumentException]::new('Legacy RepoURL does not identify a supported Terraform repository and module path.')
    }
    $path = if ($match.Groups['path'].Success) { $match.Groups['path'].Value } else { '.' }
    $identity = New-AvmCatalogIdentity -Ecosystem terraform -Repository $match.Groups['repository'].Value -ModulePath $path -Configuration $Configuration
    if ($Row.ModuleName -cne $identity.ModuleName) {
        throw [System.ArgumentException]::new('Legacy ModuleName and RepoURL disagree; an explicit identity correction is required.')
    }
    if ($path -ne '.') {
        $identity.ParentModule = '.'
        $identity.FamilyModule = '.'
    }
    return $identity
}

function Get-AvmCatalogLegacyCanonicalType {
    [CmdletBinding()]
    param([System.Collections.IDictionary] $Row, [object] $Identity)

    $canonical = [string]$Row['CanonicalType']
    if (-not $canonical -and $Identity.ModuleType -eq 'resource') {
        if ($Row['ProviderNamespace'] -and $Row['ResourceType']) {
            $canonical = '{0}/{1}' -f $Row['ProviderNamespace'], $Row['ResourceType']
        }
    }
    elseif (-not $canonical -and $Identity.Ecosystem -eq 'bicep') {
        $canonical = $Identity.ModulePath.Substring('avm/ptn/'.Length)
    }
    $pattern = if ($Identity.ModuleType -eq 'resource') { '^Microsoft\.[A-Z]\w+(/[a-zA-Z]\w+)+$' } else { '^[a-z0-9-]+(/[a-z0-9-]+)+$' }
    if (-not $canonical -or $canonical -cnotmatch $pattern) {
        throw [System.ArgumentException]::new('Legacy data cannot determine canonicalType without a reviewed mapping.')
    }
    return $canonical
}

function New-AvmCatalogRecord {
    [CmdletBinding()]
    param([object] $Identity, [System.Collections.IDictionary] $Data, [string] $MetadataSource)

    $canonical = $Data.canonicalType
    $split = $canonical.IndexOf('/')
    return [ordered]@{
        ecosystem               = $Identity.Ecosystem
        moduleType              = $Identity.ModuleType
        moduleStatus            = $null
        moduleName              = $Identity.ModuleName
        modulePath              = $Identity.ModulePath
        repository              = $Identity.Repository
        repoURL                 = $Identity.RepoURL
        parentModule            = $Identity.ParentModule
        familyModule            = $Identity.FamilyModule
        provider                = $Identity.Provider
        canonicalType           = $canonical
        providerNamespace       = if ($Identity.ModuleType -eq 'resource') { $canonical.Substring(0, $split) } else { $null }
        resourceType            = if ($Identity.ModuleType -eq 'resource') { $canonical.Substring($split + 1) } else { $null }
        metadataSource          = $MetadataSource
        moduleDisplayName       = [string]$Data.moduleDisplayName
        moduleDescription       = [string]$Data.moduleDescription
        alternativeNames        = @($Data.alternativeNames)
        comments                = [string]$Data.comments
        tier                    = $Data.tier
        owners                  = $Data.owners
        telemetryIdPrefix       = $Data.telemetryIdPrefix
        publicRegistryReference = $Identity.Reference
        registry                = $null
    }
}

function Get-AvmCatalogInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $BicepRoot,
        [Parameter(Mandatory)][string] $TerraformRoot,
        [Parameter(Mandatory)][string] $LegacyPath,
        [ValidateSet('dual-source', 'metadata-only')][string] $BicepMode = 'dual-source',
        [ValidateSet('dual-source', 'metadata-only')][string] $TerraformMode = 'dual-source',
        [System.Collections.IDictionary] $Configuration = (Read-AvmCatalogConfiguration)
    )

    $csvOutputs = @($Configuration.outputs | Where-Object { $_.kind -ceq 'csv' })
    $sources = Get-AvmCatalogSources -BicepRoot $BicepRoot -TerraformRoot $TerraformRoot -Configuration $Configuration
    $sourcesByKey = @{}
    foreach ($source in $sources) {
        $sourcesByKey[$source.Key] = $source
    }
    $tables = [ordered]@{}
    $itemsByKey = @{}
    $missing = [ordered]@{}
    $unresolved = [System.Collections.Generic.List[object]]::new()
    $modes = @{ bicep = $BicepMode; terraform = $TerraformMode }
    foreach ($source in $sources) {
        if ($null -eq $source.Metadata) {
            $missing[$source.Key] = [ordered]@{
                ecosystem = $source.Ecosystem; repository = $source.Repository
                modulePath = $source.ModulePath; reason = 'metadata-not-present'
            }
        }
    }

    foreach ($output in $csvOutputs) {
        $table = Read-AvmCatalogCsv -Path (Join-Path $LegacyPath $output.file)
        foreach ($column in @('Tier', 'CanonicalType')) {
            if ($table.Headers -contains $column -and $table.Headers -cnotcontains $column) {
                throw [System.IO.InvalidDataException]::new("Reserved catalog column must use exact casing: $column in $($output.file)")
            }
            if ($table.Headers -cnotcontains $column) {
                $table.Headers += $column
                foreach ($row in $table.Rows) {
                    $row[$column] = ''
                }
            }
        }
        $tables[$output.file] = $table
        foreach ($row in $table.Rows) {
            $identity = $null
            try {
                $identity = Get-AvmCatalogLegacyIdentity -Row $row -Ecosystem $output.ecosystem -Configuration $Configuration
                if ($identity.ModuleType -cne $output.moduleType) {
                    throw [System.ArgumentException]::new('Legacy module kind disagrees with its CSV.')
                }
                if ($sourcesByKey.ContainsKey($identity.Key)) {
                    $identity = $sourcesByKey[$identity.Key]
                }
                elseif ($identity.Ecosystem -eq 'bicep' -and $row['ParentModule'] -and $row['ParentModule'] -ne 'n/a') {
                    $parent = [string]$row['ParentModule']
                    if (-not $identity.ModulePath.StartsWith("$parent/", [StringComparison]::Ordinal)) {
                        throw [System.ArgumentException]::new('Legacy ParentModule is not an ancestor of ModuleName.')
                    }
                    $identity.ParentModule = $parent
                    $identity.FamilyModule = $parent
                }
                if ($itemsByKey.ContainsKey($identity.Key)) {
                    throw [System.IO.InvalidDataException]::new("Duplicate legacy identity: $($identity.Key)")
                }
                if ($null -ne $identity.Metadata) {
                    $itemsByKey[$identity.Key] = [pscustomobject]@{ Identity = $identity; Row = $row; File = $output.file; Record = $null }
                    continue
                }
                $missing[$identity.Key] = [ordered]@{
                    ecosystem = $identity.Ecosystem; repository = $identity.Repository
                    modulePath = $identity.ModulePath
                    reason = if ($identity.Directory) { 'metadata-not-present' } else { 'module-source-not-found' }
                }
                $canonical = Get-AvmCatalogLegacyCanonicalType -Row $row -Identity $identity
                $row['CanonicalType'] = $canonical
                $owners = [ordered]@{ individuals = @(); team = '' }
                $handles = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach ($column in @('PrimaryModuleOwnerGHHandle', 'SecondaryModuleOwnerGHHandle')) {
                    $handle = [string]$row[$column]
                    if ($handle) {
                        if ($handle -notmatch '^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$' -or $handle.Length -gt 39) {
                            throw [System.ArgumentException]::new("Legacy $column is not a GitHub handle.")
                        }
                        if ($handles.Add($handle)) {
                            $owners.individuals += [ordered]@{ githubHandle = $handle }
                        }
                    }
                }
                $team = [string]$row['ModuleOwnersGHTeam']
                if ($team -and $team -ne 'same as parent') {
                    if ($team -cnotmatch '^@[A-Za-z0-9-]+/[a-z0-9]+(-[a-z0-9]+)*$') {
                        throw [System.ArgumentException]::new('Legacy ModuleOwnersGHTeam is not a GitHub team handle.')
                    }
                    $owners.team = $team
                }
                $tier = if ($row['Tier']) { $row['Tier'] } else { $null }
                if ($null -ne $tier -and $tier -cnotin @('core', 'maintained')) {
                    throw [System.ArgumentException]::new('Legacy Tier requires a reviewed core/maintained value.')
                }
                $data = [ordered]@{
                    canonicalType = $canonical
                    moduleDisplayName = [string]$row.ModuleDisplayName
                    moduleDescription = [string]$row.Description
                    alternativeNames = @(([string]$row['AlternativeNames'] -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    comments = [string]$row['Comments']
                    tier = $tier
                    owners = $owners
                    telemetryIdPrefix = if ($row['TelemetryIdPrefix']) { [string]$row['TelemetryIdPrefix'] } else { $null }
                }
                $itemsByKey[$identity.Key] = [pscustomobject]@{
                    Identity = $identity; Row = $row; File = $output.file
                    Record = New-AvmCatalogRecord -Identity $identity -Data $data -MetadataSource legacy
                }
            }
            catch [System.ArgumentException] {
                $unresolved.Add([ordered]@{
                        file = $output.file; moduleName = [string]$row.ModuleName
                        ecosystem = $output.ecosystem; reason = $_.Exception.Message
                    })
            }
        }
    }

    foreach ($source in $sources) {
        if ($null -eq $source.Metadata) {
            continue
        }
        $familyKey = Get-AvmCatalogKey -Ecosystem $source.Ecosystem -Repository $source.Repository -ModulePath $source.FamilyModule
        $rootMetadata = $sourcesByKey[$familyKey].Metadata
        $metadata = $source.Metadata
        $data = [ordered]@{
            canonicalType = $metadata.canonicalType
            moduleDisplayName = $metadata.moduleDisplayName
            moduleDescription = $metadata.moduleDescription
            alternativeNames = @(if ($rootMetadata.Contains('alternativeNames')) { $rootMetadata.alternativeNames })
            comments = if ($rootMetadata.Contains('comments')) { [string]$rootMetadata.comments } else { '' }
            tier = $rootMetadata.tier
            owners = [ordered]@{
                individuals = @($rootMetadata.owners.individuals | ForEach-Object { [ordered]@{ githubHandle = $_.githubHandle } })
                team = if ($rootMetadata.owners.Contains('team')) { [string]$rootMetadata.owners.team } else { '' }
            }
            telemetryIdPrefix = if ($metadata.Contains('telemetryIdPrefix')) { $metadata.telemetryIdPrefix } else { $null }
        }
        if (-not $itemsByKey.ContainsKey($source.Key)) {
            $output = @($csvOutputs | Where-Object { $_.ecosystem -eq $source.Ecosystem -and $_.moduleType -eq $source.ModuleType })[0]
            $row = [ordered]@{}
            foreach ($header in $tables[$output.file].Headers) {
                $row[$header] = ''
            }
            $tables[$output.file].Rows.Add($row)
            $itemsByKey[$source.Key] = [pscustomobject]@{ Identity = $source; Row = $row; File = $output.file; Record = $null }
        }
        $itemsByKey[$source.Key].Record = New-AvmCatalogRecord -Identity $source -Data $data -MetadataSource metadata
    }

    foreach ($item in $itemsByKey.Values) {
        if ($item.Record.metadataSource -eq 'legacy' -and $null -ne $item.Identity.ParentModule) {
            $familyKey = Get-AvmCatalogKey -Ecosystem $item.Identity.Ecosystem -Repository $item.Identity.Repository -ModulePath $item.Identity.FamilyModule
            if ($itemsByKey.ContainsKey($familyKey)) {
                $item.Record.owners = $itemsByKey[$familyKey].Record.owners
                $item.Record.tier = $itemsByKey[$familyKey].Record.tier
            }
            elseif ([string]$item.Row['ModuleOwnersGHTeam'] -eq 'same as parent') {
                $unresolved.Add([ordered]@{
                        file = $item.File; moduleName = $item.Identity.ModuleName
                        ecosystem = $item.Identity.Ecosystem; reason = 'Legacy parent ownership cannot be resolved.'
                    })
            }
        }
    }
    $strictMissing = @($missing.Values | Where-Object { $modes[$_.ecosystem] -eq 'metadata-only' })
    $strictUnresolved = @($unresolved | Where-Object { $modes[$_.ecosystem] -eq 'metadata-only' })
    if ($strictMissing.Count -gt 0 -or $strictUnresolved.Count -gt 0) {
        throw [System.IO.InvalidDataException]::new("Metadata-only mode has $($strictMissing.Count) missing modules and $($strictUnresolved.Count) unresolved legacy entries.")
    }

    $marOutput = Get-AvmCatalogOutput -Configuration $Configuration -Kind mar
    $mar = Read-AvmCatalogJson -Path (Join-Path $LegacyPath $marOutput.file)
    if ($mar -isnot [array]) {
        throw [System.IO.InvalidDataException]::new("$($marOutput.file) must remain an array of module-name strings.")
    }
    foreach ($name in $mar) {
        if ($name -isnot [string] -or $name -cnotmatch '^avm/(res|ptn|utl)/[a-z0-9/-]+$') {
            throw [System.IO.InvalidDataException]::new("$($marOutput.file) contains an unsupported module name.")
        }
    }
    return [pscustomobject]@{
        Configuration = $Configuration
        Sources = $sources
        Items = @((Get-AvmCatalogOrdinal -Values @($itemsByKey.Keys)) | ForEach-Object { $itemsByKey[$_] })
        Tables = $tables
        Mar = Get-AvmCatalogOrdinal -Values $mar
        Report = [ordered]@{
            schemaVersion = 1
            modes = [ordered]@{ bicep = $BicepMode; terraform = $TerraformMode }
            missingMetadata = @((Get-AvmCatalogOrdinal -Values @($missing.Keys)) | ForEach-Object { $missing[$_] })
            unresolvedLegacy = $unresolved.ToArray()
            parity = [ordered]@{ bicepOnly = @(); terraformOnly = @() }
        }
    }
}

function Resolve-AvmCatalogOwnerProfiles {
    [CmdletBinding()]
    param([System.Collections.IDictionary] $Owners, [System.Collections.IDictionary] $Cache)

    if ($Cache['users'] -isnot [System.Collections.IDictionary] -or $Cache['teams'] -isnot [System.Collections.IDictionary]) {
        throw [System.IO.InvalidDataException]::new('GitHub cache requires users and teams dictionaries.')
    }
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($owner in $Owners.individuals) {
        $handle = $owner.githubHandle
        if (-not $Cache.users.Contains($handle)) {
            throw [System.IO.InvalidDataException]::new("GitHub profile cache is missing owner $handle.")
        }
        $profile = $Cache.users[$handle]
        if ($profile.login -ine $handle -or $profile.type -cnotin @('User', 'Bot') -or
            -not $profile.Contains('name') -or ($null -ne $profile.name -and $profile.name -isnot [string])) {
            throw [System.IO.InvalidDataException]::new("GitHub profile cache does not validate owner $handle.")
        }
        $names.Add([string]$profile.name)
    }
    if ($Owners.team) {
        $team = [string]$Owners.team
        $parts = $team.Substring(1).Split('/')
        if ($parts[0] -cne 'Azure' -or -not $Cache.teams.Contains($team)) {
            throw [System.IO.InvalidDataException]::new("GitHub team cache is missing Azure owner team $team.")
        }
        $entry = $Cache.teams[$team]
        if ($entry.slug -cne $parts[1] -or $entry.organization -cne 'Azure') {
            throw [System.IO.InvalidDataException]::new("GitHub team cache does not validate $team.")
        }
    }
    return ,$names.ToArray()
}

function ConvertTo-AvmCatalogTierConfiguration {
    [CmdletBinding()]
    param([System.Collections.IDictionary] $Configuration, [object] $Inventory)

    $copy = ConvertFrom-Json -InputObject (ConvertTo-AvmCatalogJson -Value $Configuration) -AsHashtable -Depth 100
    $tiers = @{}
    foreach ($item in $Inventory.Items) {
        if ($item.Record.ecosystem -ne 'terraform' -or $item.Record.modulePath -ne '.' -or $item.Record.metadataSource -ne 'metadata') {
            continue
        }
        $id = $item.Identity.RepositoryId
        if ($tiers.ContainsKey($id) -and $tiers[$id] -cne $item.Record.tier) {
            throw [System.IO.InvalidDataException]::new("Provider variants of $id have conflicting tiers; repository groups cannot represent provider-specific membership.")
        }
        $tiers[$id] = $item.Record.tier
    }
    if ($tiers.Count -eq 0) {
        return $copy
    }
    $groups = @{}
    foreach ($number in 1..3) {
        $name = "azure-verified-modules-tier-$number"
        $found = @($copy.repositoryGroups | Where-Object { $_.name -ceq $name })
        if ($found.Count -ne 1 -or $found[0].repositories -isnot [array]) {
            throw [System.IO.InvalidDataException]::new("Expected exactly one tier group with a repositories array: $name")
        }
        if (@($found[0].repositories | Where-Object { $_ -isnot [string] -or $_.Contains('*') }).Count -gt 0) {
            throw [System.IO.InvalidDataException]::new("Wildcard or invalid tier membership cannot be regenerated safely: $name")
        }
        $groups[$number] = $found[0]
    }
    foreach ($missing in $Inventory.Report.missingMetadata) {
        if ($missing.ecosystem -eq 'terraform' -and $missing.modulePath -eq '.') {
            $source = New-AvmCatalogIdentity -Ecosystem terraform -Repository $missing.repository -ModulePath '.'
            if (-not $tiers.ContainsKey($source.RepositoryId)) {
                continue
            }
            $target = if ($tiers[$source.RepositoryId] -eq 'core') { 1 } else { 2 }
            $memberships = @(1..3 | Where-Object { $groups[$_].repositories -contains $source.RepositoryId })
            if ($memberships.Count -ne 1 -or $memberships[0] -ne $target) {
                throw [System.IO.InvalidDataException]::new("Tier update would change unadopted provider variant $($source.Repository); migrate the variants together.")
            }
        }
    }
    foreach ($number in 1..3) {
        $remaining = @($groups[$number].repositories | Where-Object { -not $tiers.ContainsKey($_) })
        $adopted = @($tiers.Keys | Where-Object { ($number -eq 1 -and $tiers[$_] -eq 'core') -or ($number -eq 2 -and $tiers[$_] -eq 'maintained') })
        $sortedAdopted = Get-AvmCatalogOrdinal -Values $adopted
        $groups[$number].repositories = @($remaining) + $sortedAdopted
    }
    return $copy
}

function New-AvmCatalogBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Inventory,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Registry,
        [Parameter(Mandatory)][System.Collections.IDictionary] $GitHub,
        [Parameter(Mandatory)][System.Collections.IDictionary] $RepositoryConfiguration,
        [string] $SchemaPath
    )

    $configuration = $Inventory.Configuration
    $catalogOutput = Get-AvmCatalogOutput -Configuration $configuration -Kind catalog
    if (-not $SchemaPath) {
        $SchemaPath = Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..'))) $catalogOutput.schema
    }
    $schema = Read-AvmCatalogJson -Path $SchemaPath
    $modules = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $canonicalTypes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in $Inventory.Items) {
        $null = $canonicalTypes.Add($item.Record.canonicalType)
    }
    foreach ($canonical in (Get-AvmCatalogOrdinal -Values @($canonicalTypes))) {
        $modules[$canonical] = [ordered]@{ bicep = @(); terraform = @() }
    }
    foreach ($item in $Inventory.Items) {
        $record = $item.Record
        if (-not $Registry.Contains($item.Identity.Key)) {
            throw [System.IO.InvalidDataException]::new("Registry snapshot is incomplete: $($item.Identity.Key)")
        }
        $record.registry = $Registry[$item.Identity.Key]
        $record.moduleStatus = if ($record.owners.individuals.Count -eq 0 -and -not $record.owners.team) {
            'Orphaned'
        }
        elseif ($record.registry.status -eq 'available') {
            'Available'
        }
        else {
            'Proposed'
        }
        if ($record.ecosystem -eq 'bicep' -and $record.registry.marRegistered -isnot [bool]) {
            throw [System.IO.InvalidDataException]::new("Bicep registry snapshot lacks MAR registration: $($item.Identity.Key)")
        }
        if ($record.ecosystem -eq 'terraform' -and $null -ne $record.registry.marRegistered) {
            throw [System.IO.InvalidDataException]::new("Terraform registry snapshot has Bicep-only registration: $($item.Identity.Key)")
        }
        if ($record.ecosystem -eq 'terraform' -and $record.modulePath -ne '.' -and $record.registry.status -eq 'available') {
            $record.publicRegistryReference = 'https://registry.terraform.io/modules/Azure/{0}/{1}/{2}/submodules/{3}' -f
                $item.Identity.RepositoryId, $record.provider, $record.registry.currentVersion, $record.modulePath.Substring('modules/'.Length)
        }
        if ($record.metadataSource -eq 'metadata') {
            $names = Resolve-AvmCatalogOwnerProfiles -Owners $record.owners -Cache $GitHub
            $owners = @($record.owners.individuals)
            $values = @{
                ModuleDisplayName = $record.moduleDisplayName
                AlternativeNames = $record.alternativeNames -join ', '
                ModuleName = $record.moduleName
                ParentModule = if ($null -eq $record.parentModule) { 'n/a' } elseif ($record.ecosystem -eq 'terraform') { $item.Identity.RepositoryId } else { $record.parentModule }
                ModuleStatus = $record.moduleStatus
                RepoURL = $record.repoURL
                PublicRegistryReference = $record.publicRegistryReference
                TelemetryIdPrefix = [string]$record.telemetryIdPrefix
                PrimaryModuleOwnerGHHandle = if ($owners.Count -gt 0) { $owners[0].githubHandle } else { '' }
                PrimaryModuleOwnerDisplayName = if ($names.Count -gt 0) { $names[0] } else { '' }
                SecondaryModuleOwnerGHHandle = if ($owners.Count -gt 1) { $owners[1].githubHandle } else { '' }
                SecondaryModuleOwnerDisplayName = if ($names.Count -gt 1) { $names[1] } else { '' }
                ModuleOwnersGHTeam = $record.owners.team
                Description = $record.moduleDescription
                Comments = $record.comments
                FirstPublishedIn = [string]$record.registry.firstPublishedIn
                ProviderNamespace = [string]$record.providerNamespace
                ResourceType = [string]$record.resourceType
                Tier = $record.tier
                CanonicalType = $record.canonicalType
            }
            foreach ($column in @($item.Row.Keys)) {
                if ($values.ContainsKey($column)) {
                    $item.Row[$column] = $values[$column]
                }
            }
        }
        $modules[$record.canonicalType][$record.ecosystem] += $record
    }
    $catalog = [ordered]@{ '$schema' = $schema['$id']; schemaVersion = 1; modules = $modules }
    $json = ConvertTo-AvmCatalogJson -Value $catalog
    if (-not (Test-Json -Json $json -SchemaFile $SchemaPath -ErrorAction Stop)) {
        throw [System.IO.InvalidDataException]::new('Generated module catalog failed its packaged output schema.')
    }
    $tierConfiguration = ConvertTo-AvmCatalogTierConfiguration -Configuration $RepositoryConfiguration -Inventory $Inventory
    $report = $Inventory.Report
    $report.parity.bicepOnly = @($modules.Keys | Where-Object { $modules[$_].terraform.Count -eq 0 })
    $report.parity.terraformOnly = @($modules.Keys | Where-Object { $modules[$_].bicep.Count -eq 0 })
    $report['counts'] = [ordered]@{
        catalogEntries = $Inventory.Items.Count
        adoptedEntries = @($Inventory.Items | Where-Object { $_.Record.metadataSource -eq 'metadata' }).Count
        legacyRows = [ordered]@{}
        csvRows = [ordered]@{}
    }
    $files = [ordered]@{}
    foreach ($output in $configuration.outputs | Where-Object { $_.kind -ceq 'csv' }) {
        $file = $output.file
        $table = $Inventory.Tables[$file]
        $files[$output.bundlePath] = ConvertTo-AvmCatalogCsv -Headers $table.Headers -Rows $table.Rows.ToArray()
        $report.counts.legacyRows[$file] = $table.OriginalRowCount
        $report.counts.csvRows[$file] = $table.Rows.Count
    }
    $files[(Get-AvmCatalogOutput -Configuration $configuration -Kind mar).bundlePath] = ConvertTo-AvmCatalogJson -Value @($Inventory.Mar)
    $files[$catalogOutput.bundlePath] = $json
    $files[(Get-AvmCatalogOutput -Configuration $configuration -Kind migration-report).bundlePath] = ConvertTo-AvmCatalogJson -Value $report
    $files[(Get-AvmCatalogOutput -Configuration $configuration -Kind tier-configuration).bundlePath] = ConvertTo-AvmCatalogJson -Value $tierConfiguration
    return [pscustomobject]@{ Configuration = $configuration; Files = $files; Catalog = $catalog; Report = $report; RepositoryConfiguration = $tierConfiguration }
}

function Write-AvmCatalogBundle {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][object] $Bundle,
        [Parameter(Mandatory)][string] $OutputPath,
        [System.Collections.IDictionary] $Configuration = (Read-AvmCatalogConfiguration)
    )

    $destination = [System.IO.Path]::GetFullPath($OutputPath)
    if (Test-Path -LiteralPath $destination) {
        throw [System.IO.IOException]::new("Output must be a new directory to prevent partial or stale results: $destination")
    }
    $allowed = [System.Collections.Generic.HashSet[string]]::new([string[]]$Configuration.outputs.bundlePath, [StringComparer]::Ordinal)
    foreach ($relative in $Bundle.Files.Keys) {
        if (-not $allowed.Contains($relative) -or
            $Bundle.Files[$relative] -isnot [string] -or $Bundle.Files[$relative].Contains("`r")) {
            throw [System.IO.InvalidDataException]::new("Unexpected catalog output path or encoding: $relative")
        }
        foreach ($output in $Configuration.outputs | Where-Object { $_.kind -cne 'publication-plan' }) {
            if (-not $Bundle.Files.Contains($output.bundlePath)) {
                throw [System.IO.InvalidDataException]::new("Required catalog output is missing: $($output.bundlePath)")
            }
        }
    }
    if (-not $PSCmdlet.ShouldProcess($destination, 'Write validated module catalog bundle')) {
        return
    }
    $parent = [System.IO.Path]::GetDirectoryName($destination)
    $null = [System.IO.Directory]::CreateDirectory($parent)
    $staging = Join-Path $parent ('.catalog-' + [guid]::NewGuid().ToString('N'))
    $null = [System.IO.Directory]::CreateDirectory($staging)
    try {
        foreach ($relative in $Bundle.Files.Keys) {
            $path = Join-Path $staging $relative
            $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($path))
            [System.IO.File]::WriteAllText($path, $Bundle.Files[$relative], [System.Text.UTF8Encoding]::new($false))
        }
        [System.IO.Directory]::Move($staging, $destination)
    }
    finally {
        if ([System.IO.Directory]::Exists($staging)) {
            [System.IO.Directory]::Delete($staging, $true)
        }
    }
    return $destination
}
