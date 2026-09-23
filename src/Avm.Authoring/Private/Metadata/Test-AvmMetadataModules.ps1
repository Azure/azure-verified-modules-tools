function Test-AvmMetadataModules {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The pre-commit and PR-check registries use this stable multi-module step name.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject] $Context
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $issues = [System.Collections.Generic.List[object]]::new()
    Write-AvmLog ("metadata: discovering module scopes under {0}" -f $Context.Root) -Level Verbose | Out-Null
    $scopes = @(Get-AvmMetadataScope -Context $Context)
    Write-AvmLog ("metadata: discovered {0} module scope(s)" -f $scopes.Count) -Level Verbose | Out-Null
    foreach ($scope in $scopes) {
        $metadataPath = Join-Path $scope.Path 'metadata.json'
        $relativePath = [System.IO.Path]::GetRelativePath($Context.Root, $metadataPath).Replace('\', '/')
        $scopeKind = if ($scope.ChildModule) { 'child' } else { 'root' }
        Write-AvmLog ("metadata: validating {0} ({1})" -f $relativePath, $scopeKind) -Level Verbose | Out-Null
        $sentinel = Test-AvmDisableSentinel -Path $scope.Path
        if ($sentinel) {
            $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_DISABLED' -File $relativePath `
                        -Message "Metadata validation is disabled by '$sentinel'; remove it before checking this module."))
            continue
        }
        $files = @(Get-ChildItem -LiteralPath $scope.Path -Force | Where-Object { $_.Name -ieq 'metadata.json' })
        if ($files.Count -eq 0) {
            $issue = New-AvmMetadataIssue -Code 'AVM_METADATA_MISSING' -File $relativePath `
                -Message 'metadata.json is required. Initialize it with avm metadata initialize.'
            $issues.Add($issue)
            continue
        }
        if ($files.Count -ne 1 -or $files[0].PSIsContainer -or $files[0].Name -cne 'metadata.json') {
            $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_CASE' -File $relativePath `
                        -Message 'Exactly one file named metadata.json with that casing is required.'))
            continue
        }
        try {
            $metadata = ConvertFrom-AvmMetadataJson -Json (Read-AvmMetadataJson -Path $metadataPath)
            $moduleType = Get-AvmMetadataModuleType -Context $Context -Path $scope.Path -Metadata $metadata
            $result = Test-AvmModuleMetadata -Path $scope.Path -Ecosystem $Context.Ecosystem `
                -ModuleType $moduleType -ChildModule:$scope.ChildModule `
                -CheckSource:($Context.Ecosystem -eq 'bicep') -SkipModuleVersionCheck
            foreach ($issue in $result.Issues) {
                $issue.File = [System.IO.Path]::GetRelativePath($Context.Root, (Join-Path $scope.Path $issue.File)).Replace('\', '/')
                $issues.Add($issue)
            }
        }
        catch [System.ArgumentException] {
            $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_INVALID' -File $relativePath -Message $_.Exception.Message))
        }
    }
    foreach ($issue in $issues) {
        Write-AvmLog ('metadata: [{0}] {1}: {2}' -f $issue.Code, $issue.File, $issue.Message) -Level Verbose | Out-Null
    }
    $status = if (@($issues | Where-Object { $_.Severity -eq 'error' }).Count -gt 0) { 'fail' } else { 'pass' }
    Write-AvmLog ('metadata: checked {0} module scope(s); status={1}; issues={2}' -f $scopes.Count, $status, $issues.Count) -Level Verbose | Out-Null
    return [pscustomobject]@{
        Engine     = $Context.Ecosystem
        Tool       = 'module-metadata/1'
        ToolPath   = $null
        ToolSource = 'builtin'
        Status     = $status
        Issues     = $issues.ToArray()
    }
}
