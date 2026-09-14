function Invoke-AvmTerraformTest {
    <#
    .SYNOPSIS
        Validate Terraform examples and warn about uncovered local modules.

    .DESCRIPTION
        Initializes and validates each immediate examples/ configuration,
        including examples marked .e2eignore. Libraries remain child modules,
        allowing deprecated outputs. Diagnostics are relative to Context.Root.

        Each initialization uses a fresh, process-local TF_DATA_DIR so stale
        installed-module records cannot inflate coverage. Direct and transitive
        module directories are compared with the root and immediate modules/
        configurations. Uncovered modules produce warnings, not failures.

        FilesProcessed counts direct example configuration files. No examples
        returns Status='skipped'; real validation errors return Status='fail'.

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='terraform'.

    .PARAMETER AllowPathFallback
        Pass through to Resolve-AvmTool.

    .PARAMETER NoInit
        Validate examples using their existing initialization. Coverage is not
        assessed because existing module manifests can contain stale records;
        a warning reports that limitation.

    .OUTPUTS
        pscustomobject with Engine, Tool, ToolPath, ToolSource, Status,
        FilesProcessed, Issues.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Context,

        [switch] $AllowPathFallback,

        [switch] $NoInit
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Context.Ecosystem -ne 'terraform') {
        throw [System.ArgumentException]::new(
            "Invoke-AvmTerraformTest requires a terraform context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $tool = Resolve-AvmTool -Name 'terraform' -AllowPathFallback:$AllowPathFallback

    $scope = Get-AvmTerraformValidationScope -Root $Context.Root
    $issues = [System.Collections.Generic.List[object]]::new()
    $coverageIssues = [System.Collections.Generic.List[object]]::new()
    $coveredModules = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $filesProcessed = 0
    $anyFail = $false

    foreach ($example in $scope.Examples) {
        $dataDirectory = $null
        $ownsDataDirectory = $false
        $environment = @{}
        try {
            if (-not $NoInit) {
                $dataDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('avm-validate-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
                $null = New-Item -ItemType Directory -Path $dataDirectory -ErrorAction Stop
                $ownsDataDirectory = $true
                $environment.TF_DATA_DIR = $dataDirectory
                $initResult = Invoke-AvmProcess `
                    -FilePath $tool.Path `
                    -ArgumentList @('init', '-backend=false', '-upgrade', '-input=false', '-no-color') `
                    -WorkingDirectory $example.Path `
                    -EnvVars $environment `
                    -StreamOutput:(Test-AvmVerboseEnabled) `
                    -Label ('terraform init {0}' -f $example.RelativePath) `
                    -IgnoreExitCode

                if ($initResult.ExitCode -ne 0) {
                    $message = Add-AvmProcessFailureDetail `
                        -Message ("terraform init for '{0}' failed with exit code {1}." -f $example.RelativePath, $initResult.ExitCode) `
                        -StdOut $initResult.StdOut `
                        -StdErr $initResult.StdErr
                    throw [AvmProcessException]::new($message)
                }
            }

            $result = Invoke-AvmProcess `
                -FilePath $tool.Path `
                -ArgumentList @('validate', '-no-color', '-json') `
                -WorkingDirectory $example.Path `
                -EnvVars $environment `
                -IgnoreExitCode
            $filesProcessed += $example.Files.Count

            if ($result.ExitCode -notin @(0, 1)) {
                $message = Add-AvmProcessFailureDetail `
                    -Message ("terraform validate for '{0}' exited with code {1}." -f $example.RelativePath, $result.ExitCode) `
                    -StdOut $result.StdOut `
                    -StdErr $result.StdErr
                throw [AvmProcessException]::new($message)
            }

            try {
                $parsed = ConvertFrom-Json -InputObject ([string]$result.StdOut) -AsHashtable -ErrorAction Stop
            }
            catch [System.ArgumentException] {
                throw [AvmProcessException]::new(
                    "Could not parse terraform validate -json output for '$($example.RelativePath)': $($_.Exception.Message)")
            }
            if ($parsed -isnot [System.Collections.IDictionary] -or
                -not $parsed.Contains('valid') -or $parsed.valid -isnot [bool] -or
                -not $parsed.Contains('diagnostics') -or $parsed.diagnostics -isnot [array]) {
                throw [AvmProcessException]::new(
                    "Invalid terraform validate -json output for '$($example.RelativePath)': expected valid and diagnostics.")
            }

            $hasErrors = $false
            foreach ($diag in $parsed.diagnostics) {
                if ($diag -isnot [System.Collections.IDictionary] -or
                    -not $diag.Contains('severity') -or $diag.severity -notin @('error', 'warning') -or
                    -not $diag.Contains('summary') -or $diag.summary -isnot [string]) {
                    throw [AvmProcessException]::new(
                        "Invalid terraform validate diagnostic for '$($example.RelativePath)'.")
                }
                $severity = [string]$diag.severity
                if ($severity -eq 'error') { $hasErrors = $true }
                $detail = if ($diag.Contains('detail')) { [string]$diag.detail } else { '' }
                $message = if ($detail) { "$($diag.summary) - $detail" } else { [string]$diag.summary }
                $file = $example.RelativePath
                $line = 0
                $column = 0
                if ($diag.Contains('range') -and $diag.range) {
                    if ($diag.range.filename) {
                        $absoluteFile = [System.IO.Path]::GetFullPath([string]$diag.range.filename, $example.Path)
                        $file = [System.IO.Path]::GetRelativePath($Context.Root, $absoluteFile).Replace('\', '/')
                    }
                    if ($diag.range.start) {
                        $line = [int]$diag.range.start.line
                        $column = [int]$diag.range.start.column
                    }
                }
                $issues.Add([pscustomobject][ordered]@{
                        File     = $file
                        Line     = $line
                        Column   = $column
                        Severity = $severity
                        Code     = ''
                        Message  = ('[{0}] {1}' -f $example.RelativePath, $message)
                    })
            }

            if ($result.ExitCode -ne 0 -or -not $parsed.valid -or $hasErrors) {
                $anyFail = $true
                if (-not $hasErrors) {
                    $message = Add-AvmProcessFailureDetail `
                        -Message ("terraform validate for '{0}' reported failure without error diagnostics (exit {1})." -f $example.RelativePath, $result.ExitCode) `
                        -StdOut '' `
                        -StdErr $result.StdErr
                    $issues.Add([pscustomobject][ordered]@{
                            File     = $example.RelativePath
                            Line     = 0
                            Column   = 0
                            Severity = 'error'
                            Code     = ''
                            Message  = $message
                        })
                }
                continue
            }
            if ($NoInit) { continue }

            try {
                $manifestPath = Join-Path $dataDirectory 'modules' 'modules.json'
                $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop
                foreach ($directory in (ConvertFrom-AvmTerraformModuleManifest -Payload $manifest -WorkingDirectory $example.Path -TestFiles $example.TestFiles)) {
                    $null = $coveredModules.Add($directory)
                }
            }
            catch [System.Management.Automation.ItemNotFoundException], [System.IO.IOException], [System.UnauthorizedAccessException], [AvmConfigurationException] {
                $coverageIssues.Add([pscustomobject][ordered]@{
                        File     = $example.RelativePath
                        Line     = 0
                        Column   = 0
                        Severity = 'warning'
                        Code     = 'terraform.module-coverage-unavailable'
                        Message  = "Could not determine module coverage for '$($example.RelativePath)': $($_.Exception.Message)"
                    })
            }
        }
        finally {
            if ($ownsDataDirectory -and (Test-Path -LiteralPath $dataDirectory -PathType Container)) {
                Remove-Item -LiteralPath $dataDirectory -Recurse -Force -ErrorAction Stop -ProgressAction SilentlyContinue
            }
        }
    }

    if ($scope.Examples.Count -eq 0) {
        $coverageIssues.Add([pscustomobject][ordered]@{
                File     = ''
                Line     = 0
                Column   = 0
                Severity = 'warning'
                Code     = 'terraform.module-coverage'
                Message  = 'No Terraform examples found under examples/; validation was skipped.'
            })
    }
    if ($NoInit -and $scope.Examples.Count -gt 0) {
        $coverageIssues.Add([pscustomobject][ordered]@{
                File     = ''
                Line     = 0
                Column   = 0
                Severity = 'warning'
                Code     = 'terraform.module-coverage-unavailable'
                Message  = 'Module coverage is not assessed with -NoInit because existing module manifests may be stale. Rerun without -NoInit to check coverage.'
            })
    }
    else {
        foreach ($module in $scope.Modules) {
            if ($coveredModules.Contains($module.Path)) { continue }
            $coverageIssues.Add([pscustomobject][ordered]@{
                    File     = [System.IO.Path]::GetRelativePath($Context.Root, $module.Files[0]).Replace('\', '/')
                    Line     = 0
                    Column   = 0
                    Severity = 'warning'
                    Code     = 'terraform.module-coverage'
                    Message  = "No example coverage was confirmed for module '$($module.RelativePath)'. Add an example that calls this checkout's module directly or transitively."
                })
        }
    }
    foreach ($issue in $coverageIssues) {
        $issues.Add($issue)
        Write-AvmLog -Message $issue.Message -Level Warning -File $issue.File
        Register-AvmPresentedIssue -Issue $issue
    }

    return [pscustomobject][ordered]@{
        Engine         = 'terraform'
        Tool           = ('{0}/{1}' -f $tool.Name, $tool.Version)
        ToolPath       = $tool.Path
        ToolSource     = $tool.Source
        Status         = if ($anyFail) { 'fail' } elseif ($scope.Examples.Count -eq 0) { 'skipped' } else { 'pass' }
        FilesProcessed = $filesProcessed
        Issues         = $issues.ToArray()
    }
}
