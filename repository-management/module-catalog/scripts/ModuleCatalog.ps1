#Requires -Version 7.4

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ModuleCatalog.Configuration.ps1')
. (Join-Path $PSScriptRoot 'ModuleCatalog.Lifecycle.ps1')
. (Join-Path $PSScriptRoot 'ModuleCatalog.CsvRows.ps1')

function Write-AvmCatalogProgress {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Progress must always reach the workflow log and is never consumed as pipeline output.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string] $Message,
        [int] $Current = -1,
        [int] $Total = -1
    )

    $stamp = [datetime]::UtcNow.ToString('HH:mm:ss')
    if ($Total -ge 0) {
        $percent = if ($Total -gt 0) { [Math]::Floor(($Current / $Total) * 100) } else { 100 }
        Write-Host ('[{0}] {1} ({2}/{3}, {4}%)' -f $stamp, $Message, $Current, $Total, $percent)
        return
    }
    Write-Host ('[{0}] {1}' -f $stamp, $Message)
}

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
        $reference = "https://registry.terraform.io/modules/Azure/$repositoryId"
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
        Deprecated   = $false
        SourcePending = $false
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
        $mainFile = @(Get-ChildItem -LiteralPath $directory -File | Where-Object { $_.Name -ieq 'main.bicep' })
        $hasMain = $mainFile.Count -gt 0
        if ($hasMain -and $mainFile[0].Name -cne 'main.bicep') {
            throw [System.IO.InvalidDataException]::new("Bicep module has no main.bicep: $modulePath")
        }
        $identity.SourcePending = -not $hasMain
        $identity.Directory = $directory
        $identity.Deprecated = Test-AvmCatalogDeprecationMarker -Path $directory
        $ancestor = $modulePath
        while ($ancestor.Contains('/')) {
            $ancestor = $ancestor.Substring(0, $ancestor.LastIndexOf('/'))
            if ($bicepByPath.ContainsKey($ancestor)) {
                $identity.ParentModule = $ancestor
                $identity.FamilyModule = $bicepByPath[$ancestor].FamilyModule
                $identity.Deprecated = $identity.Deprecated -or $bicepByPath[$ancestor].Deprecated
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
            if (-not $hasSource -and -not $hasMetadata) {
                continue
            }
            if ($scope.Path -eq '.') {
                $hasRoot = $true
            }
            elseif (-not $hasRoot) {
                throw [System.IO.InvalidDataException]::new("Terraform child has no source-bearing family root: $name/$($scope.Path)")
            }
            $identity = New-AvmCatalogIdentity -Ecosystem terraform -Repository "Azure/$name" -ModulePath $scope.Path -Configuration $Configuration
            $identity.SourcePending = -not $hasSource
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
                -SkipModuleVersionCheck
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

function New-AvmCatalogRecord {
    [CmdletBinding()]
    param([object] $Identity, [System.Collections.IDictionary] $Data)

    $canonical = $Data.canonicalType
    $armResource = $Identity.ModuleType -eq 'resource' -and $canonical -cne 'helper'
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
        providerNamespace       = if ($armResource) { $canonical.Substring(0, $split) } else { $null }
        resourceType            = if ($armResource) { $canonical.Substring($split + 1) } else { $null }
        metadataSource          = 'metadata'
        moduleDisplayName       = [string]$Data.moduleDisplayName
        moduleDescription       = [string]$Data.moduleDescription
        alternativeNames        = @($Data.alternativeNames)
        comments                = [string]$Data.comments
        owners                  = @($Data.owners)
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
        [System.Collections.IDictionary] $Configuration = (Read-AvmCatalogConfiguration)
    )

    $csvOutputs = @($Configuration.outputs | Where-Object { $_.kind -ceq 'csv' })
    $sources = Get-AvmCatalogSources -BicepRoot $BicepRoot -TerraformRoot $TerraformRoot -Configuration $Configuration
    $sourcesByKey = @{}
    foreach ($source in $sources) {
        $sourcesByKey[$source.Key] = $source
    }
    $sourcesByAlias = @{}
    foreach ($source in $sources) {
        if ($source.Ecosystem -cne 'terraform' -or $null -eq $source.Metadata) {
            continue
        }
        $alias = 'terraform|{0}|{1}' -f $source.RepositoryId, $source.ModulePath
        if ($sourcesByAlias.ContainsKey($alias)) {
            $sourcesByAlias[$alias] = $null
            continue
        }
        $sourcesByAlias[$alias] = $source
    }
    $tables = [ordered]@{}
    $existingRows = @{}
    $itemsByKey = @{}
    $missing = [ordered]@{}
    $rowReasons = [ordered]@{}
    $renames = [System.Collections.Generic.List[object]]::new()
    $unresolved = [System.Collections.Generic.List[object]]::new()
    foreach ($source in $sources) {
        if ($null -eq $source.Metadata) {
            $missing[$source.Key] = [ordered]@{
                ecosystem = $source.Ecosystem; repository = $source.Repository
                modulePath = $source.ModulePath; reason = 'metadata-not-present'
            }
        }
    }

    foreach ($output in $csvOutputs) {
        $table = Read-AvmCatalogCsv -Path (Join-Path $LegacyPath $output.sourceFile)
        $generatedTable = [pscustomobject]@{
            Headers = $table.Headers
            Rows = [System.Collections.Generic.List[object]]::new()
            OriginalRowCount = $table.OriginalRowCount
            SourceRows = Get-AvmCatalogCsvRowSnapshot -Rows $table.Rows.ToArray()
        }
        $tables[$output.sourceFile] = $generatedTable
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
                elseif ($identity.Ecosystem -ceq 'terraform') {
                    $alias = 'terraform|{0}|{1}' -f $identity.RepositoryId, $identity.ModulePath
                    if ($sourcesByAlias.ContainsKey($alias) -and $null -ne $sourcesByAlias[$alias]) {
                        $moved = $sourcesByAlias[$alias]
                        $renames.Add([ordered]@{
                                sourceFile = $output.sourceFile
                                moduleName = [string]$identity.ModuleName
                                fromRepoURL = [string]$identity.RepoURL
                                toRepoURL = [string]$moved.RepoURL
                            })
                        $identity = $moved
                    }
                }
                if ($existingRows.ContainsKey($identity.Key)) {
                    throw [System.IO.InvalidDataException]::new("Duplicate legacy identity: $($identity.Key)")
                }
                $existingRows[$identity.Key] = [pscustomobject]@{ Row = $row; File = $output.sourceFile }
                if ($null -ne $identity.Metadata) {
                    if ($identity.Metadata.canonicalType -cne 'helper') {
                        $generatedTable.Rows.Add($row)
                    }
                    continue
                }
                $reason = if ($identity.Directory) { 'metadata-not-present' } else { 'module-source-not-found' }
                $rowReasons['{0}|{1}' -f $output.sourceFile, [string]$row.ModuleName] = $reason
                $missing[$identity.Key] = [ordered]@{
                    ecosystem = $identity.Ecosystem; repository = $identity.Repository
                    modulePath = $identity.ModulePath
                    reason = $reason
                }
            }
            catch [System.ArgumentException] {
                $rowReasons['{0}|{1}' -f $output.sourceFile, [string]$row.ModuleName] = 'unresolved-identity'
                $unresolved.Add([ordered]@{
                        file = $output.sourceFile; moduleName = [string]$row.ModuleName
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
            owners = @($rootMetadata.owners)
            telemetryIdPrefix = if ($metadata.Contains('telemetryIdPrefix')) { $metadata.telemetryIdPrefix } else { $null }
        }
        if ($existingRows.ContainsKey($source.Key)) {
            $existing = $existingRows[$source.Key]
            $row = $existing.Row
            $file = $existing.File
        }
        else {
            $output = @($csvOutputs | Where-Object { $_.ecosystem -eq $source.Ecosystem -and $_.moduleType -eq $source.ModuleType })[0]
            $row = [ordered]@{}
            foreach ($header in $tables[$output.sourceFile].Headers) {
                $row[$header] = ''
            }
            if ($metadata.canonicalType -cne 'helper') {
                $tables[$output.sourceFile].Rows.Add($row)
            }
            $file = $output.sourceFile
        }
        $itemsByKey[$source.Key] = [pscustomobject]@{
            Identity = $source; Row = $row; File = $file
            Record = New-AvmCatalogRecord -Identity $source -Data $data
        }
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
        RowRemovalReasons = $rowReasons
        RowRenames = $renames.ToArray()
        Report = [ordered]@{
            schemaVersion = 1
            missingMetadata = @((Get-AvmCatalogOrdinal -Values @($missing.Keys)) | ForEach-Object { $missing[$_] })
            unresolvedLegacy = $unresolved.ToArray()
            parity = [ordered]@{ bicepOnly = @(); terraformOnly = @() }
        }
    }
}

function Resolve-AvmCatalogOwnerProfiles {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]] $Owners,
        [System.Collections.IDictionary] $Cache,
        [System.Collections.Generic.List[string]] $Missing
    )

    if ($Cache['users'] -isnot [System.Collections.IDictionary] -or $Cache['teams'] -isnot [System.Collections.IDictionary]) {
        throw [System.IO.InvalidDataException]::new('GitHub cache requires users and teams dictionaries.')
    }
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($handle in @($Owners | Where-Object { -not $_.StartsWith('@') })) {
        if (-not $Cache.users.Contains($handle)) {
            throw [System.IO.InvalidDataException]::new("GitHub profile cache is missing owner $handle.")
        }
        $profile = $Cache.users[$handle]
        if ($null -eq $profile) {
            if ($null -ne $Missing) {
                $Missing.Add($handle)
            }
            $names.Add('')
            continue
        }
        if ($profile.login -ine $handle -or $profile.type -cnotin @('User', 'Bot') -or
            -not $profile.Contains('name') -or ($null -ne $profile.name -and $profile.name -isnot [string])) {
            throw [System.IO.InvalidDataException]::new("GitHub profile cache does not validate owner $handle.")
        }
        $names.Add([string]$profile.name)
    }
    foreach ($team in @($Owners | Where-Object { $_.StartsWith('@') })) {
        $parts = $team.Substring(1).Split('/')
        if ($parts[0] -cne 'Azure' -or -not $Cache.teams.Contains($team)) {
            throw [System.IO.InvalidDataException]::new("GitHub team cache is missing Azure owner team $team.")
        }
        $entry = $Cache.teams[$team]
        if ($null -eq $entry) {
            if ($null -ne $Missing) {
                $Missing.Add($team)
            }
            continue
        }
        if ($entry.slug -cne $parts[1] -or $entry.organization -cne 'Azure') {
            throw [System.IO.InvalidDataException]::new("GitHub team cache does not validate $team.")
        }
    }
    return ,$names.ToArray()
}

function New-AvmCatalogBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Inventory,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Registry,
        [Parameter(Mandatory)][System.Collections.IDictionary] $GitHub,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $RepositoryRevisions,
        [switch] $Force,
        [string] $SchemaPath,
        [string] $DiagnosticsPath
    )

    $configuration = $Inventory.Configuration
    $catalogOutput = Get-AvmCatalogOutput -Configuration $configuration -Kind catalog
    if (-not $SchemaPath) {
        $SchemaPath = Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..'))) $catalogOutput.schema
    }
    $schema = Read-AvmCatalogJson -Path $SchemaPath
    $archivedRepositories = Get-AvmCatalogArchivedRepositories -RepositoryRevisions $RepositoryRevisions
    $modules = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $canonicalTypes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in $Inventory.Items) {
        $null = $canonicalTypes.Add($item.Record.canonicalType)
    }
    foreach ($canonical in (Get-AvmCatalogOrdinal -Values @($canonicalTypes))) {
        $modules[$canonical] = [ordered]@{ bicep = @(); terraform = @() }
    }
    $ownerDefects = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $Inventory.Items) {
        $record = $item.Record
        if (-not $Registry.Contains($item.Identity.Key)) {
            throw [System.IO.InvalidDataException]::new("Registry snapshot is incomplete: $($item.Identity.Key)")
        }
        $record.registry = $Registry[$item.Identity.Key]
        if ($item.Identity.SourcePending -and $record.registry.status -cne 'not-published') {
            throw [System.IO.InvalidDataException]::new(
                "Module $($item.Identity.Key) has metadata but no source, yet the registry reports it as $($record.registry.status). Only proposed modules may be registered ahead of their source.")
        }
        if ($record.ecosystem -eq 'terraform' -and -not $archivedRepositories.ContainsKey($record.repository)) {
            throw [System.IO.InvalidDataException]::new("Repository archive snapshot is incomplete: $($record.repository). Collect a new snapshot.")
        }
        $deprecated = if ($record.ecosystem -eq 'bicep') {
            $item.Identity.Deprecated
        }
        else {
            $archivedRepositories[$record.repository] -eq $true
        }
        $record.moduleStatus = if ($deprecated -or [string]$item.Row['ModuleStatus'] -eq 'Deprecated') {
            'Deprecated'
        }
        elseif ($item.Identity.SourcePending) {
            'Proposed'
        }
        elseif ($record.owners.Count -eq 0) {
            'Orphaned'
        }
        elseif ($record.registry.status -eq 'available') {
            'Available'
        }
        else {
            'Proposed'
        }
        if ($deprecated) {
            $item.Row['ModuleStatus'] = 'Deprecated'
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
            $missingOwners = [System.Collections.Generic.List[string]]::new()
            $names = Resolve-AvmCatalogOwnerProfiles -Owners $record.owners -Cache $GitHub -Missing $missingOwners
            if ($missingOwners.Count -gt 0) {
                $ownerDefects.Add([ordered]@{
                        sourceFile = [string]$item.File
                        moduleName = [string]$record.moduleName
                        repoURL = [string]$record.repoURL
                        owners = @($missingOwners)
                    })
            }
            $owners = @($record.owners | Where-Object { -not $_.StartsWith('@') })
            $teams = @($record.owners | Where-Object { $_.StartsWith('@') })
            $values = @{
                ModuleDisplayName = $record.moduleDisplayName
                ModuleName = $record.moduleName
                ParentModule = if ($null -eq $record.parentModule) { 'n/a' } elseif ($record.ecosystem -eq 'terraform') { $item.Identity.RepositoryId } else { $record.familyModule }
                ModuleStatus = $record.moduleStatus
                RepoURL = $record.repoURL
                PublicRegistryReference = $record.publicRegistryReference
                TelemetryIdPrefix = [string]$record.telemetryIdPrefix
                PrimaryModuleOwnerGHHandle = if ($owners.Count -gt 0) { $owners[0] } else { '' }
                PrimaryModuleOwnerDisplayName = if ($names.Count -gt 0) { $names[0] } else { '' }
                SecondaryModuleOwnerGHHandle = if ($owners.Count -gt 1) { $owners[1] } else { '' }
                SecondaryModuleOwnerDisplayName = if ($names.Count -gt 1) { $names[1] } else { '' }
                ModuleOwnersGHTeam = if ($teams.Count -gt 0) { $teams[0] } else { '' }
                Description = $record.moduleDescription
                FirstPublishedIn = [string]$record.registry.firstPublishedIn
                ProviderNamespace = [string]$record.providerNamespace
                ResourceType = [string]$record.resourceType
            }
            if ($null -eq $record.parentModule) {
                $values['AlternativeNames'] = $record.alternativeNames -join ', '
                $values['Comments'] = $record.comments
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
    $report = $Inventory.Report
    $report.parity.bicepOnly = @($modules.Keys | Where-Object { $modules[$_].terraform.Count -eq 0 })
    $report.parity.terraformOnly = @($modules.Keys | Where-Object { $modules[$_].bicep.Count -eq 0 })
    $report['counts'] = [ordered]@{
        catalogEntries = $Inventory.Items.Count
        adoptedEntries = $Inventory.Items.Count
        legacyRows = [ordered]@{}
        csvRows = [ordered]@{}
    }
    $files = [ordered]@{}
    $sourceCsvRows = [ordered]@{}
    $removals = [System.Collections.Generic.List[object]]::new()
    $bundlePathBySourceFile = @{}
    foreach ($output in $configuration.outputs | Where-Object { $_.kind -ceq 'csv' }) {
        $file = $output.sourceFile
        $table = $Inventory.Tables[$file]
        $sourceCsvRows[$file] = $table.SourceRows
        $bundlePathBySourceFile[$file] = $output.bundlePath
        $outputRows = Get-AvmCatalogCsvRowSnapshot -Rows $table.Rows.ToArray()
        foreach ($removal in (Get-AvmCatalogCsvRowRemovals -SourceRows $table.SourceRows -OutputRows $outputRows `
                -Output $output -Configuration $configuration)) {
            $removals.Add($removal)
        }
        $files[$output.bundlePath] = ConvertTo-AvmCatalogCsv -Headers $table.Headers -Rows $table.Rows.ToArray()
        $report.counts.legacyRows[$file] = $table.OriginalRowCount
        $report.counts.csvRows[$file] = $table.Rows.Count
    }
    $renames = @(if ($Inventory.PSObject.Properties['RowRenames']) { $Inventory.RowRenames })
    $reasons = if ($Inventory.PSObject.Properties['RowRemovalReasons']) { $Inventory.RowRemovalReasons } else { $null }
    $report['sourceCsvRows'] = $sourceCsvRows
    $retained = Select-AvmCatalogCsvRowRemoval -Removals $removals.ToArray() -Renames $renames
    $report['csvRowRemovals'] = $retained
    $report['csvRowRemovalsForced'] = [bool]$Force
    $report['csvRowRenames'] = $renames
    $heldBackFiles = Resolve-AvmCatalogCsvRowRetention -Removals $retained -Renames $renames `
        -Reasons $reasons -Force:$Force -DiagnosticsPath $DiagnosticsPath
    $report['missingOwners'] = @($ownerDefects)
    if ($ownerDefects.Count -gt 0) {
        Write-AvmCatalogMissingOwner -Defects $ownerDefects.ToArray() -Force:$Force -DiagnosticsPath $DiagnosticsPath
        if (-not $Force) {
            $union = [System.Collections.Generic.HashSet[string]]::new([string[]]@($heldBackFiles), [StringComparer]::Ordinal)
            foreach ($defect in $ownerDefects) {
                $null = $union.Add([string]$defect.sourceFile)
            }
            $heldBackFiles = @(Get-AvmCatalogOrdinal -Values @($union))
        }
    }
    $heldBack = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $heldBackFiles) {
        $heldBack.Add([string]$bundlePathBySourceFile[$file])
    }
    $files[(Get-AvmCatalogOutput -Configuration $configuration -Kind mar).bundlePath] = ConvertTo-AvmCatalogJson -Value @($Inventory.Mar)
    $files[$catalogOutput.bundlePath] = $json
    if ($heldBack.Count -gt 0) {
        $heldBack.Add([string]$catalogOutput.bundlePath)
        Write-AvmCatalogProgress ("Holding back the module catalog JSON because some source CSV files are held back.")
    }
    $report['heldBackOutputs'] = $heldBack.ToArray()
    $report['heldBackSourceFiles'] = @($heldBackFiles)
    $files[(Get-AvmCatalogOutput -Configuration $configuration -Kind migration-report).bundlePath] = ConvertTo-AvmCatalogJson -Value $report
    return [pscustomobject]@{
        Configuration = $configuration; Files = $files; Catalog = $catalog; Report = $report
        HeldBack = $heldBack.ToArray(); HeldBackSourceFiles = @($heldBackFiles)
    }
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
