function Test-AvmMetadataTelemetryRequired {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string] $Path,
        [string] $Ecosystem,
        [string] $ModuleType,
        [switch] $ChildModule
    )

    if ($Ecosystem -ne 'bicep') {
        return $ModuleType -ne 'utility'
    }
    $sourcePath = Join-Path -Path $Path -ChildPath 'main.bicep'
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        return $ModuleType -ne 'utility'
    }
    $source = Get-AvmBicepCommentFreeSource -Source (Get-Content -LiteralPath $sourcePath -Raw)
    if ([regex]::IsMatch($source, "(?m)^[\t ]*resource[\t ]+avmTelemetry[\t ]+'Microsoft\.Resources/deployments@")) {
        return $true
    }
    if ($ModuleType -eq 'utility') {
        return $false
    }
    return -not $ChildModule -or (Test-Path -LiteralPath (Join-Path -Path $Path -ChildPath 'version.json') -PathType Leaf)
}
