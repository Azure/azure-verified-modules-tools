function Test-AvmMetadataModules {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The pre-commit and PR-check registries use this stable multi-module step name.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject] $Context,

        [switch] $PreparationOnly,

        [AllowEmptyCollection()]
        [object[]] $SelectedScope
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $issues = [System.Collections.Generic.List[object]]::new()
    $validations = [System.Collections.Generic.List[object]]::new()
    Write-AvmLog ("metadata: discovering module scopes under {0}" -f $Context.Root) -Level Verbose | Out-Null
    $scopes = @(if ($PSBoundParameters.ContainsKey('SelectedScope')) { $SelectedScope } else { Get-AvmMetadataScope -Context $Context })
    Write-AvmLog ("metadata: discovered {0} module scope(s)" -f $scopes.Count) -Level Verbose | Out-Null
    if ($scopes.Count -eq 0) {
        $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_SCOPE' `
                    -Message 'No module metadata scopes were discovered; no metadata requirements were evaluated.'))
    }
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
            $json = Read-AvmMetadataJson -Path $metadataPath
            $metadata = ConvertFrom-AvmMetadataJson -Json $json
            $moduleType = Get-AvmMetadataModuleType -Context $Context -Path $scope.Path -Metadata $metadata
            $validations.Add((Get-AvmMetadataValidationInput -Json $json -Path $scope.Path -Ecosystem $Context.Ecosystem `
                        -ModuleType $moduleType -ChildModule:$scope.ChildModule `
                        -CheckSource:($Context.Ecosystem -eq 'bicep') `
                        -TelemetryRequired (Test-AvmMetadataTelemetryRequired -Path $scope.Path -Ecosystem $Context.Ecosystem `
                            -ModuleType $moduleType -ChildModule:$scope.ChildModule)))
        }
        catch [System.ArgumentException] {
            $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_INVALID' -File $relativePath -Message $_.Exception.Message))
        }
    }
    if ($PreparationOnly) {
        return [pscustomobject]@{ Validations = $validations.ToArray(); Issues = $issues.ToArray() }
    }
    if ($validations.Count -gt 0) {
        $result = Invoke-AvmMetadataValidation -Validations $validations.ToArray() -ModuleRoot $Context.Root
        foreach ($issue in $result.Issues) {
            if ([System.IO.Path]::IsPathRooted($issue.File)) {
                $issue.File = [System.IO.Path]::GetRelativePath($Context.Root, $issue.File).Replace('\', '/')
            }
            $issues.Add($issue)
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
