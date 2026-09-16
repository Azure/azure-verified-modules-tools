function ConvertFrom-AvmBicepOwnershipCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Content,
        [Parameter(Mandatory)] [ValidateSet('res', 'ptn', 'utl')] [string] $Kind
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($Content)) {
        throw [System.IO.InvalidDataException]::new("The $Kind ownership index is empty.")
    }

    $reader = [System.IO.StringReader]::new($Content.TrimStart([char]0xFEFF))
    $parser = [Microsoft.VisualBasic.FileIO.TextFieldParser]::new($reader)
    try {
        $parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
        $parser.SetDelimiters(',')
        $parser.HasFieldsEnclosedInQuotes = $true
        $parser.TrimWhiteSpace = $false
        $headers = $parser.ReadFields()
        $columns = @{}
        for ($index = 0; $index -lt $headers.Count; $index++) {
            $header = $headers[$index].Trim()
            if (-not $header -or $columns.ContainsKey($header)) {
                throw [System.IO.InvalidDataException]::new("The $Kind index has empty or duplicate column names.")
            }
            $columns[$header] = $index
        }

        $required = @('ModuleName', 'ModuleStatus', 'PrimaryModuleOwnerGHHandle', 'SecondaryModuleOwnerGHHandle')
        foreach ($name in $required) {
            if (-not $columns.ContainsKey($name)) {
                throw [System.IO.InvalidDataException]::new("The $Kind index is missing column '$name'.")
            }
        }
        $lastRequired = ($required | ForEach-Object { $columns[$_] } | Measure-Object -Maximum).Maximum
        $rows = [System.Collections.Generic.List[object]]::new()
        while (-not $parser.EndOfData) {
            $fields = $parser.ReadFields()
            if ($fields.Count -le $lastRequired -or $fields.Count -gt $headers.Count) {
                throw [System.IO.InvalidDataException]::new("The $Kind index has an incomplete or oversized row near line $($parser.LineNumber).")
            }
            $rows.Add([pscustomobject]@{
                ModuleName = $fields[$columns.ModuleName]
                ModuleStatus = $fields[$columns.ModuleStatus]
                PrimaryModuleOwnerGHHandle = $fields[$columns.PrimaryModuleOwnerGHHandle]
                SecondaryModuleOwnerGHHandle = $fields[$columns.SecondaryModuleOwnerGHHandle]
            })
        }
        if ($rows.Count -eq 0) {
            throw [System.IO.InvalidDataException]::new("The $Kind ownership index has no module rows.")
        }
        return $rows.ToArray()
    }
    catch [Microsoft.VisualBasic.FileIO.MalformedLineException] {
        throw [System.IO.InvalidDataException]::new("The $Kind ownership index is malformed CSV.", $_.Exception)
    }
    finally {
        $parser.Dispose()
        $reader.Dispose()
    }
}

function ConvertTo-AvmCodeownerHandle {
    [CmdletBinding()]
    param([AllowNull()] [AllowEmptyString()] [string] $Value)

    $handle = $Value.Trim()
    if (-not $handle) {
        return
    }
    if ($handle.StartsWith('@', [System.StringComparison]::Ordinal)) {
        $handle = $handle.Substring(1)
    }
    if ($handle -cnotmatch '^(?=.{1,39}$)[a-zA-Z0-9]+(?:-[a-zA-Z0-9]+)*$') {
        throw [System.IO.InvalidDataException]::new("Invalid individual GitHub handle in the ownership index: '$Value'.")
    }
    return '@' + $handle.ToLowerInvariant()
}

function Assert-AvmCodeownersContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Content,
        [Parameter(Mandatory)] [string] $Template,
        [switch] $AllowLegacyDefault
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $placeholder = '__AVM_MODULE_OWNERS__'
    if ($Template.Contains("`r") -or
        ($Template.Split([string[]]@($placeholder), [System.StringSplitOptions]::None)).Count -ne 2 -or
        $Template -cnotmatch "(?m)^$placeholder$" -or -not $Template.EndsWith("`n")) {
        throw [System.IO.InvalidDataException]::new('CODEOWNERS.template must have LF endings and exactly one standalone module placeholder.')
    }

    $templateLines = @($Template.Split("`n") | Where-Object { $_.Trim() -and $_ -cne $placeholder })
    $rules = @($templateLines | Where-Object { -not $_.TrimStart().StartsWith('#') })
    $tooling = '@Azure/azure-verified-modules-tooling-contributors'
    $fallback = '@Azure/azure-verified-modules-module-owners'
    $metadata = 'metadata.json @Azure/azure-verified-modules-engineering-owners @Azure/azure-verified-modules-module-owners'
    $required = @("* $tooling", "/avm/ $fallback", "*avm.core.team.tests.ps1 $tooling", "*.e2eignore $tooling", $metadata)
    if ($rules.Count -ne $required.Count -or ($rules -join "`n") -cne ($required -join "`n")) {
        throw [System.IO.InvalidDataException]::new('The CODEOWNERS template changed the static ownership contract.')
    }
    $placeholderOffset = $Template.IndexOf($placeholder, [System.StringComparison]::Ordinal)
    if ($placeholderOffset -le $Template.IndexOf($required[1], [System.StringComparison]::Ordinal) -or
        $placeholderOffset -ge $Template.IndexOf($required[2], [System.StringComparison]::Ordinal)) {
        throw [System.IO.InvalidDataException]::new('Module rows must follow the shared default and precede the final tooling overrides.')
    }

    $staticLines = [System.Collections.Generic.List[string]]::new()
    $paths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $previousPath = ''
    $seenFinalOverride = $false
    foreach ($line in $Content.Replace("`r`n", "`n").Split("`n")) {
        if (-not $line.Trim()) {
            continue
        }
        if ($line -cmatch '^/avm/(res|ptn|utl)/') {
            $tokens = $line -split '\s+'
            $path = $tokens[0]
            if ($path -cnotmatch '^/avm/(res|ptn|utl)/(?:[a-z0-9]+(?:-[a-z0-9]+)*/){2,}$' -or
                $tokens.Count -lt 2 -or $tokens[-1] -cne $fallback -or
                -not $paths.Add($path) -or $seenFinalOverride -or
                [System.StringComparer]::Ordinal.Compare($previousPath, $path.TrimEnd('/')) -ge 0 -or
                -not $staticLines.Contains($required[1])) {
                throw [System.IO.InvalidDataException]::new("Invalid, duplicate, or out-of-order CODEOWNERS module row: '$path'.")
            }
            $owners = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            for ($index = 1; $index -lt $tokens.Count - 1; $index++) {
                $normalized = ConvertTo-AvmCodeownerHandle -Value $tokens[$index]
                if (-not $tokens[$index].StartsWith('@') -or -not $owners.Add($normalized)) {
                    throw [System.IO.InvalidDataException]::new("Duplicate or invalid owners for '$path'.")
                }
            }
            $previousPath = $path.TrimEnd('/')
            continue
        }
        if ($line -ceq $required[2]) {
            $seenFinalOverride = $true
        }
        $staticLine = if ($AllowLegacyDefault -and $line -ceq '/avm/ @Azure/azure-verified-modules-module-contributors') {
            $required[1]
        } else {
            $line
        }
        $staticLines.Add($staticLine)
    }
    if ($AllowLegacyDefault -and -not $staticLines.Contains($metadata)) {
        $staticLines.Add($metadata)
    }
    if ($AllowLegacyDefault -and $paths.Count -eq 0 -and ($staticLines -join "`n") -ceq ($required -join "`n")) {
        $automationHeader = @(
            '# This file is generated automatically from the AVM module indexes. Do not edit manually.'
            '# Template: https://github.com/Azure/azure-verified-modules-tools/blob/main/repository-management/bicep-codeowners-sync/CODEOWNERS.template'
        )
        $staticLines.InsertRange(0, [string[]]$automationHeader)
    }
    if (($staticLines -join "`n") -cne ($templateLines -join "`n")) {
        throw [System.IO.InvalidDataException]::new('Existing static CODEOWNERS rules or comments differ from the reviewed template; refusing to overwrite them.')
    }
    if ([System.Text.Encoding]::UTF8.GetByteCount($Content) -ge 3MB) {
        throw [System.IO.InvalidDataException]::new('Generated CODEOWNERS must be smaller than the GitHub 3 MB limit.')
    }
}

function ConvertTo-AvmBicepCodeowners {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [hashtable] $Indexes,
        [Parameter(Mandatory)] [string] $Template
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ($Indexes.Count -ne 3 -or -not $Indexes.ContainsKey('res') -or
        -not $Indexes.ContainsKey('ptn') -or -not $Indexes.ContainsKey('utl')) {
        throw [System.IO.InvalidDataException]::new('All three Bicep ownership indexes are required.')
    }

    $modules = @{}
    foreach ($kind in @('res', 'ptn', 'utl')) {
        $topLevelCount = 0
        foreach ($row in @(ConvertFrom-AvmBicepOwnershipCsv -Content $Indexes[$kind] -Kind $kind)) {
            $name = $row.ModuleName.Trim().Trim('/')
            if ($name -cnotmatch "^avm/$kind/[a-z0-9]+(?:-[a-z0-9]+)*(?:/[a-z0-9]+(?:-[a-z0-9]+)*)+$" -or
                $modules.ContainsKey($name)) {
                throw [System.IO.InvalidDataException]::new("Invalid or duplicate module path in the $kind index: '$name'.")
            }
            if ($name.Split('/').Count -ne 4) {
                continue
            }
            $status = $row.ModuleStatus.Trim()
            if ($status -notin @('Available', 'Orphaned', 'Proposed', 'Deprecated')) {
                throw [System.IO.InvalidDataException]::new("Unknown module status for '$name': '$status'.")
            }
            $modules[$name] = @{
                Row = $row
                Status = $status
            }
            $topLevelCount++
        }
        if ($topLevelCount -eq 0) {
            throw [System.IO.InvalidDataException]::new("The $kind ownership index has no top-level modules.")
        }
    }

    [string[]] $names = @($modules.Keys)
    [System.Array]::Sort($names, [System.StringComparer]::Ordinal)
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $names) {
        $module = $modules[$name]
        $owners = [System.Collections.Generic.List[string]]::new()
        if ($module.Status -ine 'Orphaned') {
            foreach ($value in @($module.Row.PrimaryModuleOwnerGHHandle, $module.Row.SecondaryModuleOwnerGHHandle)) {
                $handle = ConvertTo-AvmCodeownerHandle -Value $value
                if ($handle -and -not $owners.Contains($handle)) {
                    $owners.Add($handle)
                }
            }
        }
        $owners.Add('@Azure/azure-verified-modules-module-owners')
        $lines.Add("/$name/ $($owners -join ' ')")
    }

    $content = $Template.Replace('__AVM_MODULE_OWNERS__', ($lines -join "`n"))
    Assert-AvmCodeownersContent -Content $content -Template $Template
    return $content
}
