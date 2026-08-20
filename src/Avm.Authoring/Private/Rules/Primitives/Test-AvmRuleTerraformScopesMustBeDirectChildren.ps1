function Test-AvmRuleTerraformScopesMustBeDirectChildren {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $Rule,
        [Parameter(Mandatory)] [string] $TargetRoot,
        [switch] $Fix
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $null = $Fix
    $issues = New-Object 'System.Collections.Generic.List[object]'
    foreach ($scopeDirectory in @($Rule.Parameters.ScopeDirectories | ForEach-Object { [string]$_ })) {
        $scopeRoot = Join-Path $TargetRoot $scopeDirectory
        if (-not (Test-Path -LiteralPath $scopeRoot -PathType Container)) {
            continue
        }

        foreach ($directory in Get-ChildItem -LiteralPath $scopeRoot -Directory -Recurse -ErrorAction SilentlyContinue) {
            $relativeDirectory = [System.IO.Path]::GetRelativePath($scopeRoot, $directory.FullName)
            if (@($relativeDirectory -split '[\\/]').Count -lt 2) {
                continue
            }

            $terraformFile = Get-ChildItem `
                -LiteralPath $directory.FullName `
                -File `
                -Filter '*.tf' `
                -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if (-not $terraformFile) {
                continue
            }

            $relativeFile = [System.IO.Path]::GetRelativePath($TargetRoot, $terraformFile.FullName).Replace('\', '/')
            $issues.Add([pscustomobject][ordered]@{
                    File     = $relativeFile
                    Line     = 0
                    Column   = 0
                    Severity = $Rule.Severity
                    Code     = $Rule.Id
                    Message  = (
                        "Terraform scope '$relativeFile' is nested below '$scopeDirectory/'. " +
                        'AVM permits only one direct child layer.')
                })
        }
    }

    return [pscustomobject][ordered]@{
        Status       = if ($issues.Count -gt 0) { 'fail' } else { 'pass' }
        Issues       = $issues.ToArray()
        FilesChanged = 0
    }
}
