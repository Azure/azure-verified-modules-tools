function Convert-AvmBicepToArm {
    <#
    .SYNOPSIS
        Compile a single Bicep template to ARM JSON and return the parsed
        object along with the tool identity that produced it.

    .DESCRIPTION
        Internal helper used by the Bicep docs engine. Resolves the
        managed 'bicep' tool, runs 'bicep build --stdout <file>', and
        parses the resulting ARM JSON into a PSCustomObject for further
        walking. Any non-zero exit code from the bicep CLI is surfaced as
        an AvmProcessException with the stderr tail attached.

        This helper does NOT walk multiple files; it is invoked once per
        template (typically 'main.bicep' next to the module's README).

    .PARAMETER BicepFilePath
        Absolute path to a single .bicep file to compile.

    .PARAMETER AllowPathFallback
        When set, accept a PATH-resolved bicep that self-reports the
        lock-pinned version. Forwarded to Resolve-AvmTool.

    .OUTPUTS
        pscustomobject with:
          - ToolName    : 'bicep'
          - ToolVersion : the resolved version
          - ToolPath    : the resolved binary path
          - ToolSource  : 'cache' | 'path'
          - Arm         : the parsed ARM JSON object (PSCustomObject)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $BicepFilePath,

        [switch] $AllowPathFallback
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not (Test-Path -LiteralPath $BicepFilePath -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new(
            "Bicep template not found: $BicepFilePath", $BicepFilePath)
    }

    $tool = Resolve-AvmTool -Name 'bicep' -AllowPathFallback:$AllowPathFallback

    $result = Invoke-AvmProcess `
        -FilePath $tool.Path `
        -ArgumentList @('build', '--stdout', $BicepFilePath) `
        -IgnoreExitCode

    if ($result.ExitCode -ne 0) {
        $stderr = if ($result.StdErr) { $result.StdErr.Trim() } else { '' }
        $tail = if ($stderr) { ": $stderr" } else { '.' }
        throw [AvmProcessException]::new(
            ('bicep build exited with code {0} for [{1}]{2}' -f $result.ExitCode, $BicepFilePath, $tail))
    }

    $stdout = if ($result.StdOut) { $result.StdOut } else { '' }
    if ([string]::IsNullOrWhiteSpace($stdout)) {
        throw [AvmProcessException]::new(
            ('bicep build produced no output for [{0}].' -f $BicepFilePath))
    }

    try {
        $arm = $stdout | ConvertFrom-Json -Depth 100 -ErrorAction Stop
    }
    catch {
        throw [AvmProcessException]::new(
            ('bicep build output for [{0}] was not valid JSON: {1}' -f $BicepFilePath, $_.Exception.Message))
    }

    return [pscustomobject][ordered]@{
        ToolName    = $tool.Name
        ToolVersion = $tool.Version
        ToolPath    = $tool.Path
        ToolSource  = $tool.Source
        Arm         = $arm
    }
}
