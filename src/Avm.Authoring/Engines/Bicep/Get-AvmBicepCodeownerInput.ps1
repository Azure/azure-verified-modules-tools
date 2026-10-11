function Get-AvmBicepCodeownerInput {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $directory = Join-Path $RepositoryRoot '.github'
    $path = Join-Path $directory 'CODEOWNERS'
    $directories = @(Get-ChildItem -LiteralPath $RepositoryRoot -Force |
            Where-Object { $_.Name -ieq '.github' })
    $files = @()
    if ($directories.Count -eq 1 -and $directories[0].PSIsContainer -and
        $directories[0].Name -ceq '.github' -and
        -not ($directories[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        $files = @(Get-ChildItem -LiteralPath $directory -Force |
                Where-Object { $_.Name -ieq 'CODEOWNERS' })
    }
    $lines = @()
    $readError = ''
    $readAttempted = $false
    if ($files.Count -eq 1 -and -not $files[0].PSIsContainer -and $files[0].Name -ceq 'CODEOWNERS' -and
        -not ($files[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        $readAttempted = $true
        try { $lines = [System.IO.File]::ReadAllLines($path, [System.Text.UTF8Encoding]::new($false, $true)) }
        catch [System.IO.IOException] { $readError = $_.Exception.Message }
        catch [System.UnauthorizedAccessException] { $readError = $_.Exception.Message }
        catch [System.Text.DecoderFallbackException] { $readError = $_.Exception.Message }
    }
    $rules = @(for ($index = 0; $index -lt $lines.Count; $index++) {
            $text = [regex]::Replace($lines[$index].Trim(), '\s+', ' ')
            if ($text.Length -gt 0 -and -not $text.StartsWith('#')) {
                @{ Text = $text; Line = $index + 1; Pattern = $text.Split(' ')[0] }
            }
        })
    return @{
        IssuePath = $path; Directories = $directories; Files = $files
        ReadAttempted = $readAttempted; ReadError = $readError; Rules = $rules
    }
}
