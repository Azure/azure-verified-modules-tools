function Test-AvmMetadataModules {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject] $Context,
        [switch] $WarnIfMissing
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $issues = [System.Collections.Generic.List[object]]::new()
    $scopes = @(Get-AvmMetadataScope -Context $Context)
    foreach ($scope in $scopes) {
        $metadataPath = Join-Path $scope.Path 'metadata.json'
        $relativePath = [System.IO.Path]::GetRelativePath($Context.Root, $metadataPath).Replace('\', '/')
        $sentinel = Test-AvmDisableSentinel -Path $scope.Path
        if ($sentinel) {
            $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_DISABLED' -File $relativePath `
                        -Message "Metadata validation is disabled by '$sentinel'; remove it before checking this module."))
            continue
        }
        $files = @(Get-ChildItem -LiteralPath $scope.Path -Force | Where-Object { $_.Name -ieq 'metadata.json' })
        if ($files.Count -eq 0) {
            $message = if ($WarnIfMissing) {
                'metadata.json is missing. Initialize it with avm metadata initialize; missing files are temporarily allowed by authoring checks.'
            }
            else {
                'metadata.json is required. Initialize it with avm metadata initialize.'
            }
            $issue = New-AvmMetadataIssue -Code 'AVM_METADATA_MISSING' -File $relativePath `
                -Message $message
            if ($WarnIfMissing) {
                $issue.Severity = 'warning'
                Write-AvmLog -Message $issue.Message -Level Warning -File $issue.File -Line $issue.Line | Out-Null
                Register-AvmPresentedIssue -Issue $issue
            }
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
    return [pscustomobject]@{
        Engine = $Context.Ecosystem
        Tool = 'module-metadata/1'
        ToolPath = $null
        ToolSource = 'builtin'
        Status = if (@($issues | Where-Object { $_.Severity -eq 'error' }).Count -gt 0) { 'fail' } else { 'pass' }
        Issues = $issues.ToArray()
    }
}
