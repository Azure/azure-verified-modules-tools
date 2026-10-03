function Get-AvmBicepTestSourceHash {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Case
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $paths = [System.Collections.Generic.List[string]]::new()
    $paths.Add($Case.Path)
    $paths.Add((Join-Path $Case.ModuleRoot 'main.bicep'))
    foreach ($path in @(Get-AvmBicepE2eAssertionFile -CasePath $Case.Path)) { $paths.Add($path) }
    $post = Get-AvmBicepE2ePostHook -CasePath $Case.Path -ModuleRoot $Case.ModuleRoot
    if ($null -ne $post) { $paths.Add($post) }
    $sorted = $paths.ToArray()
    [System.Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    $entries = @(
        foreach ($path in $sorted) {
            [ordered]@{
                path = [System.IO.Path]::GetRelativePath($Case.ModuleRoot, $path).Replace('\', '/')
                hash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData(
                        [System.IO.File]::ReadAllBytes($path)))
            }
        }
    )
    $json = ConvertTo-Json -InputObject $entries -Compress
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData(
            [System.Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()
}
