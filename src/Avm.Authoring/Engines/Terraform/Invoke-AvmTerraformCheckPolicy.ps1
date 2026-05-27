function Invoke-AvmTerraformCheckPolicy {
    <#
    .SYNOPSIS
        Run 'conftest test' against a Terraform module using the pinned
        APRL + AVMSEC policy bundles.

    .DESCRIPTION
        Engine implementation called by Invoke-AvmCheckPolicy when the
        module context is Ecosystem='terraform'.

        Pipeline:

          1. Resolve the 'conftest' binary via Resolve-AvmTool (cache
             first; -AllowPathFallback enables PATH fallback when set).
          2. Load the merged pinned-asset config via Read-AvmAssetConfig
             from $Context.Root (walks upward for .avm/config.json,
             falls back to <Config>/avm.config.json for per-user defaults).
          3. Look up two named asset descriptors by convention:
                avm-policy-aprl   - the Azure Proactive Resiliency Library bundle
                avm-policy-avmsec - the AVM Security bundle
             If either is missing, throw AvmConfigurationException with a
             "declare these in .avm/config.json" message. The dispatcher
             (Invoke-AvmCheckPolicy via Invoke-AvmPrCheck) maps that to
             Status='skipped' so the chain still flows for unconfigured
             repos.
          4. Materialise each asset via Resolve-AvmPinnedAsset and capture
             the on-disk Path.
          5. Run conftest:
                conftest test --policy <APRL> --policy <AVMSEC>
                              --output json --parser hcl2 .
             from CWD=$Context.Root.
          6. Parse the JSON output: an array of per-file/per-namespace
             records each carrying 'failures' (severity=error) and
             'warnings' (severity=warning) lists. Flatten into the shared
             Issue record shape.

        conftest exit codes:
          0 - no failures (warnings allowed)
          1 - at least one failure (parse and report; Status='fail')
          others - conftest itself misbehaved (throw AvmProcessException)

        This slice uses the HCL2 parser so the engine can be exercised
        without first running 'terraform plan' against a configured Azure
        backend. The plan-JSON path (which APRL was originally designed
        for) is a deliberate follow-up slice.

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='terraform'.

    .PARAMETER AllowPathFallback
        Pass through to Resolve-AvmTool.

    .OUTPUTS
        pscustomobject with Engine, Tool, ToolPath, ToolSource, Status,
        Issues.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Context,

        [switch] $AllowPathFallback
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Context.Ecosystem -ne 'terraform') {
        throw [System.ArgumentException]::new(
            "Invoke-AvmTerraformCheckPolicy requires a terraform context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $tool = Resolve-AvmTool -Name 'conftest' -AllowPathFallback:$AllowPathFallback

    $assetConfig = Read-AvmAssetConfig -Path $Context.Root

    $aprlName = 'avm-policy-aprl'
    $avmsecName = 'avm-policy-avmsec'

    $missing = New-Object System.Collections.Generic.List[string]
    if (-not $assetConfig.Assets.Contains($aprlName)) { $missing.Add($aprlName) }
    if (-not $assetConfig.Assets.Contains($avmsecName)) { $missing.Add($avmsecName) }
    if ($missing.Count -gt 0) {
        throw [AvmConfigurationException]::new(
            ("avm check policy requires pinned policy bundles '{0}'. Declare them in .avm/config.json (or your per-user <Config>/avm.config.json) with 'source' + 'sha256' for each." -f ($missing -join "', '")))
    }

    $aprlAsset = Resolve-AvmPinnedAsset -Name $aprlName -Asset $assetConfig.Assets[$aprlName]
    $avmsecAsset = Resolve-AvmPinnedAsset -Name $avmsecName -Asset $assetConfig.Assets[$avmsecName]

    $result = Invoke-AvmProcess `
        -FilePath $tool.Path `
        -ArgumentList @('test', '--policy', $aprlAsset.Path, '--policy', $avmsecAsset.Path, '--output', 'json', '--parser', 'hcl2', '.') `
        -WorkingDirectory $Context.Root `
        -IgnoreExitCode

    # exit 0 = no failures; 1 = at least one failure; anything else = conftest itself misbehaved.
    if ($result.ExitCode -ne 0 -and $result.ExitCode -ne 1) {
        $stderr = if ($result.StdErr) { $result.StdErr.Trim() } else { '' }
        $tail = if ($stderr) { ": $stderr" } else { '.' }
        throw [AvmProcessException]::new(
            ('conftest exited with code {0}{1}' -f $result.ExitCode, $tail))
    }

    $issues = New-Object System.Collections.Generic.List[object]
    $payload = if ($result.StdOut) { $result.StdOut.Trim() } else { '' }
    if ($payload) {
        try {
            $parsed = $payload | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw [AvmProcessException]::new(
                "Could not parse conftest --output json output: $($_.Exception.Message)")
        }
        foreach ($record in @($parsed)) {
            if (-not $record) { continue }
            $file = if ($record.PSObject.Properties['filename']) { [string]$record.filename } else { '' }
            $namespace = if ($record.PSObject.Properties['namespace']) { [string]$record.namespace } else { '' }

            if ($record.PSObject.Properties['failures'] -and $record.failures) {
                foreach ($failure in @($record.failures)) {
                    $msg = if ($failure.PSObject.Properties['msg']) { [string]$failure.msg } else { '' }
                    $issues.Add([pscustomobject][ordered]@{
                            File     = $file
                            Line     = 0
                            Column   = 0
                            Severity = 'error'
                            Code     = $namespace
                            Message  = $msg
                        })
                }
            }
            if ($record.PSObject.Properties['warnings'] -and $record.warnings) {
                foreach ($warning in @($record.warnings)) {
                    $msg = if ($warning.PSObject.Properties['msg']) { [string]$warning.msg } else { '' }
                    $issues.Add([pscustomobject][ordered]@{
                            File     = $file
                            Line     = 0
                            Column   = 0
                            Severity = 'warning'
                            Code     = $namespace
                            Message  = $msg
                        })
                }
            }
        }
    }

    $status = if ($issues | Where-Object { $_.Severity -eq 'error' }) { 'fail' } else { 'pass' }

    return [pscustomobject][ordered]@{
        Engine     = 'terraform'
        Tool       = ('{0}/{1}' -f $tool.Name, $tool.Version)
        ToolPath   = $tool.Path
        ToolSource = $tool.Source
        Status     = $status
        Issues     = $issues.ToArray()
    }
}
