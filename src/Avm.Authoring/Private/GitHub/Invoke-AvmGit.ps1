function Invoke-AvmGit {
    <#
    .SYNOPSIS
        Run git without interactive prompts, optionally authenticating to GitHub through gh.
    .PARAMETER ArgumentList
        Git arguments.
    .PARAMETER WorkingDirectory
        Directory to run git in.
    .PARAMETER UseGitHubCredential
        Use the GitHub CLI as the only credential helper for github.com.
    .PARAMETER IgnoreExitCode
        Return a non-zero exit code instead of throwing.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string[]] $ArgumentList,

        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [switch] $UseGitHubCredential,

        [switch] $IgnoreExitCode
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $git = Get-AvmApplicationPath -Name git
    $arguments = [System.Collections.Generic.List[string]]::new()
    if ($UseGitHubCredential) {
        # Git Credential Manager can return a token without the workflow scope,
        # which makes GitHub reject pushes that add .github/workflows files.
        $arguments.AddRange([string[]]@(
                '-c', 'credential.helper=',
                '-c', 'credential.https://github.com.helper=!gh auth git-credential'
            ))
    }
    $arguments.AddRange($ArgumentList)
    return Invoke-AvmProcess -FilePath $git -ArgumentList $arguments.ToArray() `
        -WorkingDirectory $WorkingDirectory -IgnoreExitCode:$IgnoreExitCode `
        -Label ('git ' + ($ArgumentList -join ' ')) `
        -EnvVars @{ GIT_TERMINAL_PROMPT = '0'; GH_HOST = 'github.com'; GH_PROMPT_DISABLED = '1' }
}
