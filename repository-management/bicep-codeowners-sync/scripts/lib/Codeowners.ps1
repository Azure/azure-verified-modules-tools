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
    if ($handle -cmatch '^(?<org>[a-zA-Z0-9]+(?:-[a-zA-Z0-9]+)*)/(?<team>[a-z0-9]+(?:-[a-z0-9]+)*)$') {
        return "@$($Matches.org)/$($Matches.team)"
    }
    if ($handle -cnotmatch '^(?=.{1,39}$)[a-zA-Z0-9]+(?:-[a-zA-Z0-9]+)*$') {
        throw [System.IO.InvalidDataException]::new("Invalid GitHub owner handle in module metadata: '$Value'.")
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
                if (-not $tokens[$index].StartsWith('@') -or $tokens[$index] -ceq $fallback -or -not $owners.Add($normalized)) {
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
            '# This file is generated automatically from each root Bicep module''s metadata.json. Do not edit manually.'
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
    <#
    .SYNOPSIS
        Render the Bicep CODEOWNERS module rows from discovered root-module metadata.
    .DESCRIPTION
        Each top-level avm/{res,ptn,utl}/{provider}/{module} directory becomes one
        rooted, trailing-slash rule listing every owner from that module's
        metadata.json `owners` array, in file order and deduplicated case-insensitively,
        followed by the shared fallback team. There is no owner-count limit and no
        module-status filtering: an empty `owners` array simply yields the fallback
        team alone.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Modules,
        [Parameter(Mandatory)] [string] $Template
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ($Modules.Count -eq 0) {
        throw [System.IO.InvalidDataException]::new('At least one Bicep root module is required to generate CODEOWNERS.')
    }

    $moduleOwnersByName = @{}
    $kindCounts = @{ res = 0; ptn = 0; utl = 0 }
    foreach ($entry in $Modules) {
        $name = $entry.Name.Trim().Trim('/')
        if ($name -cnotmatch '^avm/(res|ptn|utl)/[a-z0-9]+(?:-[a-z0-9]+)*/[a-z0-9]+(?:-[a-z0-9]+)*$' -or
            $moduleOwnersByName.ContainsKey($name)) {
            throw [System.IO.InvalidDataException]::new("Invalid or duplicate module path: '$name'.")
        }
        $kindCounts[$name.Split('/')[1]]++
        $moduleOwnersByName[$name] = @($entry.Owners)
    }
    foreach ($kind in @('res', 'ptn', 'utl')) {
        if ($kindCounts[$kind] -eq 0) {
            throw [System.IO.InvalidDataException]::new("No top-level Bicep $kind modules were discovered.")
        }
    }

    [string[]] $names = @($moduleOwnersByName.Keys)
    [System.Array]::Sort($names, [System.StringComparer]::Ordinal)
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $names) {
        $owners = [System.Collections.Generic.List[string]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($value in $moduleOwnersByName[$name]) {
            $handle = ConvertTo-AvmCodeownerHandle -Value $value
            if ($handle -and $seen.Add($handle)) {
                $owners.Add($handle)
            }
        }
        $owners.Add('@Azure/azure-verified-modules-module-owners')
        $lines.Add("/$name/ $($owners -join ' ')")
    }

    $content = $Template.Replace('__AVM_MODULE_OWNERS__', ($lines -join "`n"))
    Assert-AvmCodeownersContent -Content $content -Template $Template
    return $content
}
