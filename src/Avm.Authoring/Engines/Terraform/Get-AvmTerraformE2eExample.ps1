function Get-AvmTerraformE2eExample {
    <#
    .SYNOPSIS
        Enumerate the examples/ directories the e2e tier can run.

    .DESCRIPTION
        A directory under examples/ is runnable when it contains at least one
        '*.tf' file. A '.e2eignore' marker opts the directory out; ignored
        directories are still returned, flagged via the Ignored property, so
        callers can distinguish "not a real example" from "deliberately
        skipped" and fail loudly on the latter.

    .PARAMETER Root
        Module root directory containing examples/.

    .OUTPUTS
        pscustomobject with Name, Path and Ignored, sorted by Name.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Root
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $examplesRoot = Join-Path $Root 'examples'
    if (-not (Test-Path -LiteralPath $examplesRoot)) {
        return @()
    }

    $dirs = @(Get-ChildItem -LiteralPath $examplesRoot -Directory -ErrorAction SilentlyContinue | Sort-Object -Property Name)

    return @(
        foreach ($dir in $dirs) {
            $hasTf = @(Get-ChildItem -LiteralPath $dir.FullName -File -Filter '*.tf' -ErrorAction SilentlyContinue).Count -gt 0
            if (-not $hasTf) { continue }
            [pscustomobject][ordered]@{
                Name    = $dir.Name
                Path    = $dir.FullName
                Ignored = [bool](Test-Path -LiteralPath (Join-Path $dir.FullName '.e2eignore'))
            }
        }
    )
}

function Select-AvmTerraformE2eExample {
    <#
    .SYNOPSIS
        Resolve caller-supplied example selectors to runnable examples.

    .DESCRIPTION
        F26: an explicitly named example that does not exist, or that carries a
        '.e2eignore' marker, is a hard error. A typo in a CI matrix must never
        report a clean pass, and the matrix must never silently disagree with
        the ignore markers.

        Selectors accept either the folder leaf ('example-a') or a repo-relative
        path ('examples/example-a', './examples/example-a').

    .PARAMETER Example
        Available examples, as emitted by Get-AvmTerraformE2eExample.

    .PARAMETER Selector
        Requested example names. An empty or omitted selector returns every
        runnable (non-ignored) example.

    .OUTPUTS
        pscustomobject entries from -Example.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Example,

        [AllowEmptyCollection()]
        [string[]] $Selector = @()
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $runnable = @($Example | Where-Object { -not $_.Ignored })
    $requested = @($Selector | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if ($requested.Count -eq 0) {
        return $runnable
    }

    $valid = ($runnable | ForEach-Object { $_.Name }) -join ', '
    if ([string]::IsNullOrWhiteSpace($valid)) { $valid = '<none>' }

    $selected = New-Object System.Collections.Generic.List[object]
    foreach ($item in $requested) {
        $name = ($item -replace '\\', '/').Trim().Trim('/')
        $name = $name -replace '^\./', ''
        $name = $name -replace '^examples/', ''

        $match = $Example | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if (-not $match) {
            throw [AvmConfigurationException]::new(
                ("Unknown e2e example '{0}'. Valid examples: {1}." -f $item, $valid))
        }
        if ($match.Ignored) {
            throw [AvmConfigurationException]::new(
                ("e2e example '{0}' is opted out by examples/{0}/.e2eignore and cannot be targeted explicitly. Valid examples: {1}." -f $match.Name, $valid))
        }
        if (-not ($selected | Where-Object { $_.Name -eq $match.Name })) {
            $selected.Add($match)
        }
    }

    return $selected.ToArray()
}
